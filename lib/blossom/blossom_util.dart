import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:mime/mime.dart';

import '../event.dart';
import '../event_kind.dart';
import '../nostr.dart';
import '../utils/base64.dart';
import '../utils/hash_util.dart';
import '../utils/string_util.dart';

class BlossomBlobDescriptor {
  final String url;
  final String sha256;
  final int size;
  final String type;
  final int uploaded;
  final Map<String, dynamic> raw;

  BlossomBlobDescriptor({
    required this.url,
    required this.sha256,
    required this.size,
    required this.type,
    required this.uploaded,
    required this.raw,
  });

  factory BlossomBlobDescriptor.fromJson(Map<String, dynamic> json) {
    return BlossomBlobDescriptor(
      url: (json['url'] ?? '').toString(),
      sha256: (json['sha256'] ?? '').toString().toLowerCase(),
      size: _toInt(json['size']),
      type: (json['type'] ?? 'application/octet-stream').toString(),
      uploaded: _toInt(json['uploaded']),
      raw: Map<String, dynamic>.from(json),
    );
  }

  static int _toInt(dynamic v) {
    if (v is int) {
      return v;
    }
    if (v is num) {
      return v.toInt();
    }
    if (v is String) {
      return int.tryParse(v) ?? 0;
    }
    return 0;
  }
}

class BlossomUtil {
  static final Dio dio = Dio();
  // Keep debug logs disabled by default after troubleshooting.
  static const bool _enableDebugLog = false;

  static void _logInfo(String message) {
    if (!_enableDebugLog) return;
    log('[BlossomUtil] $message');
  }

  static void _logError(String message, [Object? error]) {
    if (!_enableDebugLog) return;
    if (error != null) {
      log('[BlossomUtil] $message: $error');
      return;
    }
    log('[BlossomUtil] $message');
  }

  static String normalizeServerUrl(String serverUrl) {
    var value = serverUrl.trim();
    if (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  static Future<String> buildAuthorizationHeader(
    Nostr nostr,
    String serverUrl,
    String action,
    String content, {
    String? hash,
    int expirationSeconds = 600,
  }) async {
    final uri = Uri.tryParse(normalizeServerUrl(serverUrl));
    if (uri == null || StringUtil.isBlank(uri.host)) {
      _logError('Invalid blossom server url', serverUrl);
      throw StateError('Invalid blossom server url: $serverUrl');
    }

    final serverScope = uri.origin.toLowerCase();

    final tags = <List<String>>[
      ['t', action],
      [
        'expiration',
        ((DateTime.now().millisecondsSinceEpoch ~/ 1000) + expirationSeconds)
            .toString(),
      ],
      ['server', serverScope],
    ];

    final normalizedHash = hash?.trim().toLowerCase();
    if (StringUtil.isNotBlank(normalizedHash)) {
      tags.add(['x', normalizedHash!]);
    }

    final authEvent = Event(
      nostr.publicKey,
      EventKind.BLOSSOM_HTTP_AUTH,
      tags,
      content,
    );
    await nostr.signEvent(authEvent);
    _logInfo(
      'buildAuthorizationHeader action=$action serverScope=$serverScope hash=${normalizedHash ?? ''} kind=${authEvent.kind} createdAt=${authEvent.createdAt} tags=${jsonEncode(tags)}',
    );

    final encoded = base64Encode(utf8.encode(jsonEncode(authEvent.toJson())));
    _logInfo(
        'buildAuthorizationHeader encoding=base64 authLength=${encoded.length}');
    return 'Nostr $encoded';
  }

  static Future<BlossomBlobDescriptor?> upload(
    Nostr nostr,
    String serverUrl,
    String filePath, {
    String? fileName,
    int expirationSeconds = 600,
  }) async {
    Uint8List? bytes;
    if (BASE64.check(filePath)) {
      bytes = BASE64.toData(filePath);
      _logInfo('upload source=base64 bytes=${bytes.length}');
    } else {
      final file = File(filePath);
      bytes = file.readAsBytesSync();
      if (StringUtil.isBlank(fileName)) {
        fileName = file.uri.pathSegments.isNotEmpty
            ? file.uri.pathSegments.last
            : file.path.split('/').last;
      }
      _logInfo(
          'upload source=file path=$filePath bytes=${bytes.length} fileName=${fileName ?? ''}');
    }

    if (bytes.isEmpty) {
      _logError('upload aborted because bytes is empty');
      return null;
    }

    return uploadBytes(
      nostr,
      serverUrl,
      bytes,
      fileName: fileName,
      expirationSeconds: expirationSeconds,
    );
  }

  static Future<BlossomBlobDescriptor?> uploadBytes(
    Nostr nostr,
    String serverUrl,
    Uint8List bytes, {
    String? fileName,
    int expirationSeconds = 600,
  }) async {
    if (bytes.isEmpty) {
      _logError('uploadBytes aborted because bytes is empty');
      return null;
    }

    final normalizedServer = normalizeServerUrl(serverUrl);
    final uri = Uri.tryParse(normalizedServer);
    if (uri == null) {
      _logError('uploadBytes invalid server url', serverUrl);
      return null;
    }

    final sha256 = HashUtil.sha256Bytes(bytes).toLowerCase();
    final uploadUrl = uri.replace(path: '/upload').toString();

    final contentType = (StringUtil.isNotBlank(fileName)
            ? lookupMimeType(fileName!, headerBytes: bytes)
            : lookupMimeType('', headerBytes: bytes)) ??
        'application/octet-stream';

    final authorization = await buildAuthorizationHeader(
      nostr,
      normalizedServer,
      'upload',
      'Upload Blob',
      hash: sha256,
      expirationSeconds: expirationSeconds,
    );

    final headers = <String, String>{
      'Content-Type': contentType,
      'Content-Length': bytes.length.toString(),
      'X-SHA-256': sha256,
      'Authorization': authorization,
    };

    _logInfo(
      'uploadBytes request url=$uploadUrl bytes=${bytes.length} contentType=$contentType sha256=$sha256 fileName=${fileName ?? ''}',
    );

    try {
      final response = await dio.put(
        uploadUrl,
        data: Stream.fromIterable(bytes.map((e) => [e])),
        options: Options(
          headers: headers,
          validateStatus: (status) => true,
        ),
      );

      _logInfo(
          'uploadBytes response status=${response.statusCode} bodyType=${response.data.runtimeType}');

      if (response.statusCode == 200 || response.statusCode == 201) {
        final descriptor = _parseBlobDescriptor(response.data);
        if (descriptor != null) {
          _logInfo(
              'uploadBytes parsed descriptor url=${descriptor.url} size=${descriptor.size}');
          return descriptor;
        }
        _logError('uploadBytes response parsed but descriptor is null');
      }
    } catch (e) {
      _logError('uploadBytes request failed', e);
      return null;
    }

    return null;
  }

  static Future<bool> preflightUpload(
    Nostr nostr,
    String serverUrl,
    String sha256, {
    int? contentLength,
    int expirationSeconds = 600,
  }) async {
    final normalizedServer = normalizeServerUrl(serverUrl);
    final uri = Uri.tryParse(normalizedServer);
    if (uri == null) {
      _logError('preflightUpload invalid server url', serverUrl);
      return false;
    }

    final uploadUrl = uri.replace(path: '/upload').toString();
    final authorization = await buildAuthorizationHeader(
      nostr,
      normalizedServer,
      'upload',
      'Preflight Upload',
      hash: sha256,
      expirationSeconds: expirationSeconds,
    );

    final headers = <String, String>{
      'X-SHA-256': sha256.toLowerCase(),
      'Authorization': authorization,
    };
    if (contentLength != null && contentLength >= 0) {
      headers['Content-Length'] = contentLength.toString();
    }

    _logInfo(
      'preflightUpload request url=$uploadUrl sha256=${sha256.toLowerCase()} contentLength=${contentLength ?? -1}',
    );

    try {
      final response = await dio.head(
        uploadUrl,
        options: Options(
          headers: headers,
          validateStatus: (status) => true,
        ),
      );
      _logInfo('preflightUpload response status=${response.statusCode}');
      return response.statusCode != null && response.statusCode! < 400;
    } catch (e) {
      _logError('preflightUpload request failed', e);
      return false;
    }
  }

  static Future<bool> headBlob(
    Nostr nostr,
    String serverUrl,
    String sha256, {
    String? extension,
    bool withAuthorization = false,
    int expirationSeconds = 600,
  }) async {
    final normalizedServer = normalizeServerUrl(serverUrl);
    final path = StringUtil.isNotBlank(extension)
        ? '/$sha256.${extension!.replaceAll('.', '')}'
        : '/$sha256';

    final uri = Uri.tryParse(normalizedServer)?.replace(path: path);
    if (uri == null) {
      _logError('headBlob invalid request uri', '$serverUrl $path');
      return false;
    }

    Map<String, String>? headers;
    if (withAuthorization) {
      headers = {
        'Authorization': await buildAuthorizationHeader(
          nostr,
          normalizedServer,
          'get',
          'Check Blob',
          hash: sha256,
          expirationSeconds: expirationSeconds,
        ),
      };
    }

    try {
      final response = await dio.head(
        uri.toString(),
        options: Options(
          headers: headers,
          validateStatus: (status) => true,
        ),
      );
      _logInfo(
          'headBlob response url=${uri.toString()} status=${response.statusCode} withAuthorization=$withAuthorization');
      return response.statusCode == 200;
    } catch (e) {
      _logError('headBlob request failed', e);
      return false;
    }
  }

  static Future<Uint8List?> downloadBlob(
    Nostr nostr,
    String serverUrl,
    String sha256, {
    String? extension,
    bool withAuthorization = false,
    bool verifySha256 = false,
    int expirationSeconds = 600,
  }) async {
    final normalizedServer = normalizeServerUrl(serverUrl);
    final path = StringUtil.isNotBlank(extension)
        ? '/$sha256.${extension!.replaceAll('.', '')}'
        : '/$sha256';

    final uri = Uri.tryParse(normalizedServer)?.replace(path: path);
    if (uri == null) {
      _logError('downloadBlob invalid request uri', '$serverUrl $path');
      return null;
    }

    return downloadFromUrl(
      nostr,
      normalizedServer,
      uri.toString(),
      hash: sha256,
      withAuthorization: withAuthorization,
      verifySha256: verifySha256,
      expirationSeconds: expirationSeconds,
    );
  }

  static Future<Uint8List?> downloadFromUrl(
    Nostr nostr,
    String serverUrl,
    String blobUrl, {
    String? hash,
    bool withAuthorization = false,
    bool verifySha256 = false,
    int expirationSeconds = 600,
  }) async {
    Map<String, String>? headers;
    if (withAuthorization) {
      headers = {
        'Authorization': await buildAuthorizationHeader(
          nostr,
          serverUrl,
          'get',
          'Get Blob',
          hash: hash,
          expirationSeconds: expirationSeconds,
        ),
      };
    }

    _logInfo(
      'downloadFromUrl request url=$blobUrl withAuthorization=$withAuthorization verifySha256=$verifySha256 hash=${hash ?? ''}',
    );

    try {
      final response = await dio.get(
        blobUrl,
        options: Options(
          headers: headers,
          responseType: ResponseType.bytes,
          validateStatus: (status) => true,
        ),
      );

      _logInfo(
          'downloadFromUrl response status=${response.statusCode} bodyType=${response.data.runtimeType}');

      if (response.statusCode != 200 || response.data is! List<int>) {
        _logError('downloadFromUrl unexpected response',
            'status=${response.statusCode} bodyType=${response.data.runtimeType}');
        return null;
      }

      final bytes = Uint8List.fromList(response.data as List<int>);
      if (verifySha256 && StringUtil.isNotBlank(hash)) {
        final digest = HashUtil.sha256Bytes(bytes).toLowerCase();
        if (digest != hash!.toLowerCase()) {
          _logError('downloadFromUrl sha256 mismatch',
              'expected=${hash.toLowerCase()} actual=$digest');
          return null;
        }
      }
      return bytes;
    } catch (e) {
      _logError('downloadFromUrl request failed', e);
      return null;
    }
  }

  static Future<List<BlossomBlobDescriptor>> listBlobs(
    Nostr nostr,
    String serverUrl,
    String pubkey, {
    String? cursor,
    int? limit,
    int? since,
    int? until,
    int expirationSeconds = 600,
  }) async {
    final normalizedServer = normalizeServerUrl(serverUrl);
    final queryParams = <String, String>{
      if (StringUtil.isNotBlank(cursor)) 'cursor': cursor!,
      if (limit != null) 'limit': '$limit',
      if (since != null) 'since': '$since',
      if (until != null) 'until': '$until',
    };
    final uri = Uri.tryParse(normalizedServer)?.replace(
      path: '/list/$pubkey',
      queryParameters: queryParams.isEmpty ? null : queryParams,
    );
    if (uri == null) {
      _logError('listBlobs invalid request uri', '$serverUrl $pubkey');
      return [];
    }

    final authorization = await buildAuthorizationHeader(
      nostr,
      normalizedServer,
      'list',
      'List Blobs',
      expirationSeconds: expirationSeconds,
    );

    try {
      _logInfo(
        'listBlobs request url=${uri.toString()} pubkey=$pubkey authPrefix=${authorization.substring(0, authorization.length > 24 ? 24 : authorization.length)}... authLength=${authorization.length}',
      );

      final response = await dio.get(
        uri.toString(),
        options: Options(
          headers: {'Authorization': authorization},
          responseType: ResponseType.plain,
          validateStatus: (status) => true,
        ),
      );

      _logInfo(
          'listBlobs response url=${uri.toString()} status=${response.statusCode} headers=${response.headers.map}');

      if (response.statusCode != 200) {
        _logError(
          'listBlobs failed status=${response.statusCode} '
          'bodyType=${response.data.runtimeType} '
          'body=${response.data}',
        );
        return [];
      }

      final data = _normalizeBody(response.data);
      if (data is! List) {
        return [];
      }

      final result = <BlossomBlobDescriptor>[];
      for (final item in data) {
        if (item is Map<String, dynamic>) {
          result.add(BlossomBlobDescriptor.fromJson(item));
        } else if (item is Map) {
          result.add(
              BlossomBlobDescriptor.fromJson(Map<String, dynamic>.from(item)));
        }
      }
      return result;
    } catch (e) {
      _logError('listBlobs request failed', e);
      return [];
    }
  }

  static Future<bool> deleteBlob(
    Nostr nostr,
    String serverUrl,
    String sha256, {
    int expirationSeconds = 600,
  }) async {
    final normalizedServer = normalizeServerUrl(serverUrl);
    final uri = Uri.tryParse(normalizedServer)?.replace(path: '/$sha256');
    if (uri == null) {
      _logError('deleteBlob invalid request uri', '$serverUrl $sha256');
      return false;
    }

    final authorization = await buildAuthorizationHeader(
      nostr,
      normalizedServer,
      'delete',
      'Delete Blob',
      hash: sha256,
      expirationSeconds: expirationSeconds,
    );

    try {
      final response = await dio.delete(
        uri.toString(),
        options: Options(
          headers: {'Authorization': authorization},
          validateStatus: (status) => true,
        ),
      );
      _logInfo(
          'deleteBlob response url=${uri.toString()} status=${response.statusCode}');
      return response.statusCode == 200 || response.statusCode == 204;
    } catch (e) {
      _logError('deleteBlob request failed', e);
      return false;
    }
  }

  static BlossomBlobDescriptor? _parseBlobDescriptor(dynamic body) {
    final data = _normalizeBody(body);

    if (data is Map<String, dynamic>) {
      if (data.containsKey('url')) {
        return BlossomBlobDescriptor.fromJson(data);
      }

      final nip94 = data['nip94_event'];
      if (nip94 is Map && nip94['tags'] is List) {
        final tags = nip94['tags'] as List;
        final descriptor = <String, dynamic>{
          'sha256': '',
          'url': '',
          'size': 0,
          'type': 'application/octet-stream',
          'uploaded': 0,
        };
        for (final tag in tags) {
          if (tag is List && tag.length > 1) {
            final key = tag[0].toString();
            final value = tag[1];
            if (key == 'url') {
              descriptor['url'] = value.toString();
            } else if (key == 'x') {
              descriptor['sha256'] = value.toString();
            } else if (key == 'size') {
              descriptor['size'] = BlossomBlobDescriptor._toInt(value);
            } else if (key == 'm') {
              descriptor['type'] = value.toString();
            }
          }
        }
        if (StringUtil.isNotBlank(descriptor['url']?.toString())) {
          return BlossomBlobDescriptor.fromJson(descriptor);
        }
      }
    }

    _logError('parseBlobDescriptor failed', body.runtimeType);

    return null;
  }

  static dynamic _normalizeBody(dynamic body) {
    if (body is String) {
      try {
        return jsonDecode(body);
      } catch (_) {
        return body;
      }
    }
    return body;
  }
}
