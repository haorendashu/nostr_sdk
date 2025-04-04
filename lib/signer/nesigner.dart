import 'dart:typed_data';

import 'package:hex/hex.dart';
import 'package:nostr_sdk/event.dart';
import 'package:nostr_sdk/signer/nostr_signer.dart';
import 'package:flutter_nesigner_sdk/flutter_nesigner_sdk.dart';

class Nesigner implements NostrSigner {
  static String URI_PRE = "nesigner";

  static bool isNesignerKey(String key) {
    if (key.startsWith(URI_PRE)) {
      return true;
    }
    return false;
  }

  static String getAesKeyFromKey(String key) {
    var strs = key.split(":");
    if (strs.length >= 2) {
      return strs[1].split("?")[0];
    }

    return key;
  }

  static String? getPubkeyFromKey(String key) {
    var strs = key.split("pubkey=");
    if (strs.length >= 2) {
      return strs[1];
    }

    return key;
  }

  EspSigner? _espSigner;

  EspService? _espService;

  String? _aesKey;

  String? _pubkey;

  Nesigner(String aesKey, {String? pubkey}) {
    _aesKey = aesKey;
    _pubkey = pubkey;
  }

  EspService? getEspService() {
    return _espService;
  }

  Future<bool> start() async {
    var usbTransport = UsbIsolateTransport();
    _espService = EspService(usbTransport);
    await _espService!.start();
    _espService!.startListening();
    var aesKeyBin = HEX.decode(_aesKey!);
    _espSigner = EspSigner(Uint8List.fromList(aesKeyBin), _espService!);
    return _espService!.transport.isOpen;
  }

  @override
  Future<String?> decrypt(pubkey, ciphertext) async {
    if (_espSigner != null) {
      return await _espSigner!.decrypt(pubkey, ciphertext);
    }

    return null;
  }

  @override
  Future<String?> encrypt(pubkey, plaintext) async {
    if (_espSigner != null) {
      return await _espSigner!.encrypt(pubkey, plaintext);
    }

    return null;
  }

  @override
  Future<String?> getPublicKey() async {
    if (_pubkey != null) {
      return _pubkey;
    }

    if (_espSigner != null) {
      _pubkey = await _espSigner!.getPublicKey();
    }

    return _pubkey;
  }

  @override
  Future<Map?> getRelays() async {
    return {};
  }

  @override
  Future<String?> nip44Decrypt(pubkey, ciphertext) async {
    if (_espSigner != null) {
      return await _espSigner!.nip44Decrypt(pubkey, ciphertext);
    }

    return null;
  }

  @override
  Future<String?> nip44Encrypt(pubkey, plaintext) async {
    if (_espSigner != null) {
      return await _espSigner!.nip44Encrypt(pubkey, plaintext);
    }

    return null;
  }

  @override
  Future<Event?> signEvent(Event event) async {
    if (_espSigner != null) {
      var eventMap = await _espSigner!.signEvent(event.toJson());
      if (eventMap != null) {
        var event = Event.fromJson(eventMap);
        return event;
      }
    }

    return null;
  }

  @override
  void close() {}
}
