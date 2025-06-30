import 'dart:convert';
import 'dart:developer';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

// Conditional imports for platform-specific code
import 'relay_base_io.dart' if (dart.library.html) 'relay_base_web.dart';

import 'client_connected.dart';
import 'relay.dart';

class RelayBase extends Relay {
  RelayBase(super.url, super.relayStatus);

  WebSocketChannel? _wsChannel;

  @override
  Future<bool> doConnect() async {
    if (_wsChannel != null && _wsChannel!.closeCode == null) {
      print("connect break: $url");
      return true;
    }

    try {
      relayStatus.connected = ClientConneccted.CONNECTING;
      getRelayInfo(url);

      final wsUrl = Uri.parse(url);
      log("Connect begin: $url");
      
      // Create WebSocket using platform-specific implementation
      if (wsUrl.scheme == 'wss' && !kIsWeb) {
        // Use custom SSL handling only on non-web platforms
        _wsChannel = createSecureWebSocketChannel(wsUrl);
        log("Created secure WebSocket with custom SSL handling for $url");
      } else {
        // Use standard WebSocket for ws:// or web platform
        _wsChannel = createWebSocketChannel(wsUrl);
        log("Created WebSocket for $url");
      }
      // await _wsChannel!.ready;
      log("Connect complete: $url");
      _wsChannel!.stream.listen((message) {
        if (onMessage != null) {
          final List<dynamic> json = jsonDecode(message);
          onMessage!(this, json);
        }
      }, onError: (error) async {
        print(error);
        onError("Websocket error $url", reconnect: true);
      }, onDone: () {
        onError("Websocket stream closed by remote: $url", reconnect: true);
      });
      relayStatus.connected = ClientConneccted.CONNECTED;
      if (relayStatusCallback != null) {
        relayStatusCallback!();
      }
      return true;
    } catch (e) {
      onError(e.toString(), reconnect: true);
    }
    return false;
  }

  @override
  bool send(List<dynamic> message, {bool? forceSend}) {
    if (forceSend == true ||
        (_wsChannel != null &&
            relayStatus.connected == ClientConneccted.CONNECTED)) {
      try {
        print("🔍 DEBUG: Raw message: $message");
        print("🔍 Message type: ${message.runtimeType}");
        print("🔍 Message[0] type: ${message[0].runtimeType}");
        if (message.length > 1) {
          print("🔍 Message[1] type: ${message[1].runtimeType}");
        }
        
        // Verify WebSocket channel type
        print("🔍 WebSocket channel type: ${_wsChannel.runtimeType}");
        print("🔍 WebSocket sink type: ${_wsChannel!.sink.runtimeType}");
        
        // Verify it's JSON-serializable before sanitization
        try {
          final testEncode = jsonEncode(message);
          print("✅ Original message is JSON-serializable");
        } catch (e) {
          print("❌ ERROR: Original message is NOT JSON-serializable: $e");
        }
        
        // CRITICAL: Check signature before sanitization
        if (message.length > 1 && message[0] == 'EVENT') {
          final eventData = message[1];
          if (eventData is Map && eventData.containsKey('sig')) {
            print('🔍 SIGNATURE BEFORE SANITIZATION: ${eventData['sig']}');
          }
        }
        
        // Defensive serialization: Ensure all data is JSON-serializable
        final sanitizedMessage = sanitizeForJson(message);
        print("🔍 DEBUG: Sanitized message: $sanitizedMessage");
        
        // CRITICAL: Check signature after sanitization
        if (sanitizedMessage.length > 1 && sanitizedMessage[0] == 'EVENT') {
          final eventData = sanitizedMessage[1];
          if (eventData is Map && eventData.containsKey('sig')) {
            print('🔍 SIGNATURE AFTER SANITIZATION: ${eventData['sig']}');
          }
        }
        
        final encoded = jsonEncode(sanitizedMessage);
        print("🔍 DEBUG: Encoded JSON: $encoded");
        print("🔍 DEBUG: Encoded JSON length: ${encoded.length} characters");
        _wsChannel!.sink.add(encoded);
        return true;
      } catch (e) {
        onError(e.toString(), reconnect: true);
      }
    }
    return false;
  }

  /// Recursively sanitize data structures to ensure JSON serializability
  @protected
  dynamic sanitizeForJson(dynamic data) {
    if (data == null) {
      return null;
    } else if (data is String || data is num || data is bool) {
      return data;
    } else if (data is List) {
      return data.map((item) => sanitizeForJson(item)).toList();
    } else if (data is Map) {
      final result = <String, dynamic>{};
      data.forEach((key, value) {
        // Ensure keys are strings
        final stringKey = key.toString();
        result[stringKey] = sanitizeForJson(value);
      });
      return result;
    } else {
      // For any other type, try to convert to JSON-compatible format
      try {
        // If it has a toJson method, use it
        if (data is dynamic && data.toJson != null) {
          return sanitizeForJson(data.toJson());
        }
      } catch (e) {
        // Ignore toJson errors and fall through
      }
      
      // As last resort, convert to string
      return data.toString();
    }
  }

  @override
  Future<void> disconnect() async {
    try {
      relayStatus.connected = ClientConneccted.UN_CONNECT;
      if (_wsChannel != null) {
        await _wsChannel!.sink.close();
      }
    } finally {
      _wsChannel = null;
    }
  }
}
