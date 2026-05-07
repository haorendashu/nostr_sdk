import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../event.dart';
import '../event_kind.dart';
import '../nostr.dart';
import '../utils/base64.dart';
import '../utils/hash_util.dart';
import '../utils/string_util.dart';

class NIP96Response<T> {
  final int statusCode;
  final Headers headers;
  final T? data;
  final dynamic rawData;

  NIP96Response({
    required this.statusCode,
    required this.headers,
    required this.data,
    required this.rawData,
  });

  bool get isSuccess => statusCode >= 200 && statusCode < 300;
}

class NIP96FileManager {
  static final Dio dio = Dio();
  // Keep debug logs disabled by default after troubleshooting.
  static const bool _enableDebugLog = false;

  static void _logInfo(String message) {
    if (!_enableDebugLog) return;
    log('[NIP96FileManager] $message');
  }

  static void _logError(String message, [Object? error]) {
    if (!_enableDebugLog) return;
    if (error != null) {
      log('[NIP96FileManager] $message: $error');
      return;
    }
    log('[NIP96FileManager] $message');
  }

  static String normalizeUrl(String value) {
    return value.trim();
  }

  static String normalizeMethod(String method) {
    return method.trim().toUpperCase();
  }

  static Future<Event> buildAuthEvent(
    Nostr nostr, {
    required String absoluteUrl,
    required String method,
    String? payloadHash,
    String content = '',
  }) async {
    final normalizedUrl = normalizeUrl(absoluteUrl);
    final normalizedMethod = normalizeMethod(method);

    final uri = Uri.tryParse(normalizedUrl);
    if (uri == null || !uri.isAbsolute) {
      _logError('buildAuthEvent invalid absolute url', absoluteUrl);
      throw StateError('NIP-98 requires an absolute URL: $absoluteUrl');
    }

    final tags = <List<String>>[
      ['u', uri.toString()],
      ['method', normalizedMethod],
    ];

    if (StringUtil.isNotBlank(payloadHash)) {
      tags.add(['payload', payloadHash!.trim().toLowerCase()]);
    }

    final authEvent = Event(
      nostr.publicKey,
      EventKind.HTTP_AUTH,
      tags,
      content,
    );
    await nostr.signEvent(authEvent);
    _logInfo(
      'buildAuthEvent method=$normalizedMethod url=${uri.toString()} hasPayload=${StringUtil.isNotBlank(payloadHash)}',
    );
    return authEvent;
  }

  static Future<String> buildAuthorizationHeader(
    Nostr nostr, {
    required String absoluteUrl,
    required String method,
    String? payloadHash,
    String content = '',
  }) async {
    final event = await buildAuthEvent(
      nostr,
      absoluteUrl: absoluteUrl,
      method: method,
      payloadHash: payloadHash,
      content: content,
    );

    final encoded = base64UrlEncode(utf8.encode(jsonEncode(event.toJson())))
        .replaceAll('=', '');
    _logInfo(
        'buildAuthorizationHeader method=${normalizeMethod(method)} url=${normalizeUrl(absoluteUrl)}');
    return 'Nostr $encoded';
  }

  static Future<NIP96Response<T>> request<T>(
    Nostr nostr, {
    required String absoluteUrl,
    required String method,
    dynamic data,
    String? payloadHash,
    bool includePayloadTag = true,
    bool includeAuthorization = true,
    Map<String, dynamic>? headers,
    ResponseType? responseType,
  }) async {
    final normalizedUrl = normalizeUrl(absoluteUrl);
    final normalizedMethod = normalizeMethod(method);

    try {
      final uri = Uri.parse(normalizedUrl);
      if (!uri.isAbsolute) {
        _logError('request url is not absolute', normalizedUrl);
      }
    } catch (e) {
      _logError('request invalid url', e);
    }

    var resolvedPayloadHash = payloadHash;
    if (includePayloadTag && StringUtil.isBlank(resolvedPayloadHash)) {
      if (data is Uint8List && data.isNotEmpty) {
        resolvedPayloadHash = HashUtil.sha256Bytes(data).toLowerCase();
      } else if (data is List<int> && data.isNotEmpty) {
        resolvedPayloadHash =
            HashUtil.sha256Bytes(Uint8List.fromList(data)).toLowerCase();
      }
    }

    final requestHeaders = <String, dynamic>{};
    if (headers != null) {
      requestHeaders.addAll(headers);
    }

    if (includeAuthorization) {
      requestHeaders['Authorization'] = await buildAuthorizationHeader(
        nostr,
        absoluteUrl: normalizedUrl,
        method: normalizedMethod,
        payloadHash: includePayloadTag ? resolvedPayloadHash : null,
      );
    }

    _logInfo(
      'request start method=$normalizedMethod url=$normalizedUrl includeAuthorization=$includeAuthorization includePayloadTag=$includePayloadTag payloadHash=${resolvedPayloadHash ?? ''} dataType=${data.runtimeType} responseType=${responseType ?? ResponseType.json}',
    );

    late final Response<dynamic> response;
    try {
      response = await dio.request<dynamic>(
        normalizedUrl,
        data: data,
        options: Options(
          method: normalizedMethod,
          headers: requestHeaders,
          responseType: responseType,
          validateStatus: (_) => true,
        ),
      );
    } catch (e) {
      _logError(
          'request failed method=$normalizedMethod url=$normalizedUrl', e);
      rethrow;
    }

    _logInfo(
      'request done method=$normalizedMethod url=$normalizedUrl status=${response.statusCode} bodyType=${response.data.runtimeType}',
    );

    return NIP96Response<T>(
      statusCode: response.statusCode ?? 0,
      headers: response.headers,
      data: response.data as T?,
      rawData: response.data,
    );
  }

  static Future<NIP96Response<dynamic>> list(
    Nostr nostr,
    String absoluteUrl, {
    Map<String, dynamic>? headers,
  }) {
    return request<dynamic>(
      nostr,
      absoluteUrl: absoluteUrl,
      method: 'GET',
      headers: headers,
    );
  }

  static Future<NIP96Response<Uint8List?>> download(
    Nostr nostr,
    String absoluteUrl, {
    String? expectedSha256,
    Map<String, dynamic>? headers,
  }) async {
    _logInfo(
        'download start url=$absoluteUrl expectedSha256=${expectedSha256 ?? ''}');
    final response = await request<dynamic>(
      nostr,
      absoluteUrl: absoluteUrl,
      method: 'GET',
      headers: headers,
      responseType: ResponseType.bytes,
    );

    Uint8List? bytes;
    final body = response.rawData;
    if (body is Uint8List) {
      bytes = body;
    } else if (body is List<int>) {
      bytes = Uint8List.fromList(body);
    }

    if (bytes != null && StringUtil.isNotBlank(expectedSha256)) {
      final hash = HashUtil.sha256Bytes(bytes).toLowerCase();
      if (hash != expectedSha256!.toLowerCase()) {
        _logError('download hash mismatch',
            'expected=${expectedSha256.toLowerCase()} actual=$hash');
        throw StateError('Downloaded payload hash mismatch');
      }
    }

    _logInfo(
        'download done url=$absoluteUrl status=${response.statusCode} bytes=${bytes?.length ?? 0}');

    return NIP96Response<Uint8List?>(
      statusCode: response.statusCode,
      headers: response.headers,
      data: bytes,
      rawData: response.rawData,
    );
  }

  static Future<bool> head(
    Nostr nostr,
    String absoluteUrl, {
    Map<String, dynamic>? headers,
  }) async {
    _logInfo('head start url=$absoluteUrl');
    final response = await request<dynamic>(
      nostr,
      absoluteUrl: absoluteUrl,
      method: 'HEAD',
      headers: headers,
    );
    _logInfo('head done url=$absoluteUrl status=${response.statusCode}');
    return response.statusCode < 400;
  }

  static Future<bool> delete(
    Nostr nostr,
    String absoluteUrl, {
    Map<String, dynamic>? headers,
  }) async {
    _logInfo('delete start url=$absoluteUrl');
    final response = await request<dynamic>(
      nostr,
      absoluteUrl: absoluteUrl,
      method: 'DELETE',
      headers: headers,
    );
    _logInfo(
        'delete done url=$absoluteUrl status=${response.statusCode} success=${response.isSuccess}');
    return response.isSuccess;
  }

  static Future<NIP96Response<dynamic>> uploadBinary(
    Nostr nostr,
    String absoluteUrl,
    Uint8List bytes, {
    String contentType = 'application/octet-stream',
    Map<String, dynamic>? headers,
  }) {
    _logInfo(
        'uploadBinary start url=$absoluteUrl bytes=${bytes.length} contentType=$contentType');
    final mergedHeaders = <String, dynamic>{
      'Content-Type': contentType,
      'Content-Length': bytes.length.toString(),
      ...?headers,
    };

    return request<dynamic>(
      nostr,
      absoluteUrl: absoluteUrl,
      method: 'PUT',
      data: bytes,
      headers: mergedHeaders,
      payloadHash: HashUtil.sha256Bytes(bytes).toLowerCase(),
      includePayloadTag: true,
    );
  }

  static Future<NIP96Response<dynamic>> uploadFile(
    Nostr nostr,
    String absoluteUrl,
    String filePath, {
    String fieldName = 'file',
    String? fileName,
    Map<String, dynamic>? headers,
    bool includePayloadTag = true,
  }) async {
    Uint8List? bytes;
    if (BASE64.check(filePath)) {
      bytes = BASE64.toData(filePath);
      _logInfo('uploadFile source=base64 bytes=${bytes.length}');
    } else {
      final file = File(filePath);
      if (!await file.exists()) {
        _logError('uploadFile file not found', filePath);
        throw StateError('File not found: $filePath');
      }
      bytes = await file.readAsBytes();
      if (StringUtil.isBlank(fileName)) {
        fileName = file.uri.pathSegments.isNotEmpty
            ? file.uri.pathSegments.last
            : file.path.split('/').last;
      }
      _logInfo(
          'uploadFile source=file path=$filePath bytes=${bytes.length} fileName=${fileName ?? ''}');
    }

    if (bytes.isEmpty) {
      _logError('uploadFile aborted because file is empty');
      throw StateError('File is empty');
    }

    final multipart = MultipartFile.fromBytes(
      bytes,
      filename: fileName,
    );
    final formData = FormData.fromMap({fieldName: multipart});

    // For multipart uploads we hash the file bytes, which is the value used by
    // most NIP-96-compatible servers for the optional NIP-98 payload tag.
    final fileHash = HashUtil.sha256Bytes(bytes).toLowerCase();
    _logInfo(
      'uploadFile prepared url=$absoluteUrl fieldName=$fieldName includePayloadTag=$includePayloadTag fileHash=$fileHash',
    );

    return request<dynamic>(
      nostr,
      absoluteUrl: absoluteUrl,
      method: 'POST',
      data: formData,
      headers: headers,
      payloadHash: includePayloadTag ? fileHash : null,
      includePayloadTag: includePayloadTag,
    );
  }
}
