import 'dart:convert';

import 'package:android_content_provider/android_content_provider.dart';
import 'package:nostr_sdk/utils/string_util.dart';
import 'package:synchronized/synchronized.dart';

import '../android_plugin/android_plugin.dart';
import '../android_plugin/android_plugin_intent.dart';
import '../event.dart';
import '../nip19/nip19.dart';
import '../signer/nostr_signer.dart';

///
/// Android Local Nostr Signer
///
/// Notice:
/// havn't implement get_relays method.
/// many methods call content_resolve_query first and than start_activity_for_result.
/// many methods return signature field maybe later will change to result field, so client should get signature field first and try result field if signature field not exist.
/// methods calling should be one-by-one, if they call together it will call some call in signer can't get the calling package name.
///
class AndroidNostrSigner implements NostrSigner {
  static const String URI_PRE = "nostrsigner";

  static const String ACTION_VIEW = "android.intent.action.VIEW";

  static bool isAndroidNostrSignerKey(String key) {
    if (key.startsWith(URI_PRE)) {
      return true;
    }
    return false;
  }

  static String getPubkeyFromKey(String key) {
    var strs = key.split(":");
    if (strs.length >= 2) {
      return strs[1].split("?")[0];
    }

    return key;
  }

  static String? getPackageFromKey(String key) {
    var strs = key.split("package=");
    if (strs.length >= 2) {
      return strs[1];
    }

    return key;
  }

  AndroidNostrSigner({String? pubkey, String? package}) {
    _pubkey = pubkey;
    _package = package;
    if (pubkey != null) {
      _npub = Nip19.encodePubKey(pubkey);
    }
  }

  final _lock = Lock(reentrant: true);

  Duration TIMEOUT = const Duration(seconds: 300);

  String? _pubkey;

  String? _npub;

  String? _package;

  String? getPackage() {
    return _package;
  }

  AndroidPluginIntent _genIntent() {
    var intent = AndroidPluginIntent();
    intent.setAction(ACTION_VIEW);
    if (StringUtil.isNotBlank(_package)) {
      intent.setPackage(_package!);
    }

    return intent;
  }

  @override
  Future<String?> decrypt(pubkey, ciphertext) async {
    return _lock.synchronized(() async {
      var queryResult = await _contentResolverQuery("NIP04_DECRYPT",
          [ciphertext, pubkey, _npub!], ["signature", "result"]);
      // print(queryResult);
      if (queryResult != null &&
          queryResult.isNotEmpty &&
          queryResult[0] != null &&
          queryResult[0] is String) {
        return queryResult[0] as String;
      }

      var intent = _genIntent();
      intent.setData("$URI_PRE:$ciphertext");

      intent.putExtra("type", "nip04_decrypt");
      intent.putExtra("current_user", _npub);
      intent.putExtra("pubKey", pubkey);

      var result = await AndroidPlugin.startForResult(intent);
      if (result != null) {
        var signature = result.data.getExtra("signature");
        if (signature != null && signature is String) {
          return signature;
        }

        signature = result.data.getExtra("result");
        if (signature != null && signature is String) {
          return signature;
        }
      }

      return null;
    }, timeout: TIMEOUT);
  }

  @override
  Future<String?> encrypt(pubkey, plaintext) async {
    return _lock.synchronized(() async {
      var queryResult = await _contentResolverQuery("NIP04_ENCRYPT",
          [plaintext, pubkey, _npub!], ["signature", "result"]);
      // print(queryResult);
      if (queryResult != null &&
          queryResult.isNotEmpty &&
          queryResult[0] != null &&
          queryResult[0] is String) {
        return queryResult[0] as String;
      }

      var intent = _genIntent();
      intent.setData("$URI_PRE:$plaintext");

      intent.putExtra("type", "nip04_encrypt");
      intent.putExtra("current_user", _npub);
      intent.putExtra("pubKey", pubkey);

      var result = await AndroidPlugin.startForResult(intent);
      if (result != null) {
        var signature = result.data.getExtra("signature");
        if (signature != null && signature is String) {
          return signature;
        }

        signature = result.data.getExtra("result");
        if (signature != null && signature is String) {
          return signature;
        }
      }

      return null;
    }, timeout: TIMEOUT);
  }

  @override
  Future<String?> getPublicKey() async {
    if (_pubkey != null) {
      return _pubkey;
    }

    List<Map<String, dynamic>> permissions = [];
    permissions.add({'type': 'sign_event', 'kind': 22242});
    permissions.add({'type': 'nip04_encrypt'});
    permissions.add({'type': 'nip44_encrypt'});
    permissions.add({'type': 'nip04_decrypt'});
    permissions.add({'type': 'nip44_decrypt'});
    permissions.add({'type': 'get_public_key'});

    var intent = _genIntent();
    intent.setData("$URI_PRE:");

    intent.putExtra("type", "get_public_key");
    intent.putExtra("permissions", jsonEncode(permissions));

    return _lock.synchronized(() async {
      var result = await AndroidPlugin.startForResult(intent);
      if (result != null) {
        var package = result.data.getExtra("package");
        _package = package;

        var signature = result.data.getExtra("signature");
        if (signature != null && signature is String) {
          if (Nip19.isPubkey(signature)) {
            // npub
            _npub = signature;
            _pubkey = Nip19.decode(signature);
          } else {
            // hex pubkey
            _pubkey = signature;
            _npub = Nip19.encodePubKey(signature);
          }
          return _pubkey;
        }
      }

      return null;
    }, timeout: TIMEOUT);
  }

  @override
  Future<Map?> getRelays() async {
    return {};
  }

  @override
  Future<String?> nip44Decrypt(pubkey, ciphertext) async {
    return _lock.synchronized(() async {
      var queryResult = await _contentResolverQuery("NIP44_DECRYPT",
          [ciphertext, pubkey, _npub!], ["signature", "result"]);
      if (queryResult != null &&
          queryResult.isNotEmpty &&
          queryResult[0] != null &&
          queryResult[0] is String) {
        return queryResult[0] as String;
      }

      var intent = _genIntent();
      intent.setData("$URI_PRE:$ciphertext");

      intent.putExtra("type", "nip44_decrypt");
      intent.putExtra("current_user", _npub);
      intent.putExtra("pubKey", pubkey);

      var result = await AndroidPlugin.startForResult(intent).timeout(TIMEOUT);
      if (result != null) {
        var signature = result.data.getExtra("signature");
        if (signature != null && signature is String) {
          return signature;
        }

        signature = result.data.getExtra("result");
        if (signature != null && signature is String) {
          return signature;
        }
      }

      return null;
    }, timeout: TIMEOUT);
  }

  @override
  Future<String?> nip44Encrypt(pubkey, plaintext) async {
    return _lock.synchronized(() async {
      var queryResult = await _contentResolverQuery("NIP44_ENCRYPT",
          [plaintext, pubkey, _npub!], ["signature", "result"]);
      // print(queryResult);
      if (queryResult != null &&
          queryResult.isNotEmpty &&
          queryResult[0] != null &&
          queryResult[0] is String) {
        return queryResult[0] as String;
      }

      var intent = _genIntent();
      intent.setData("$URI_PRE:$plaintext");

      intent.putExtra("type", "nip44_encrypt");
      intent.putExtra("current_user", _npub);
      intent.putExtra("pubKey", pubkey);

      var result = await AndroidPlugin.startForResult(intent);
      if (result != null) {
        var signature = result.data.getExtra("signature");
        if (signature != null && signature is String) {
          return signature;
        }

        signature = result.data.getExtra("result");
        if (signature != null && signature is String) {
          return signature;
        }
      }

      return null;
    }, timeout: TIMEOUT);
  }

  @override
  Future<Event?> signEvent(Event event) async {
    var eventMap = event.toJson();
    var eventJson = jsonEncode(eventMap);

    return _lock.synchronized(() async {
      var queryResult = await _contentResolverQuery("SIGN_EVENT",
          [eventJson, "", _npub!], ["signature", "result", "event"]);
      if (queryResult != null &&
          queryResult.isNotEmpty &&
          queryResult[0] != null &&
          queryResult[0] is String) {
        event.sig = queryResult[0] as String;
        return event;
      }

      var intent = _genIntent();
      intent.setData("$URI_PRE:$eventJson");

      intent.putExtra("type", "sign_event");
      intent.putExtra("current_user", _npub);
      intent.putExtra("id", event.id);

      var result = await AndroidPlugin.startForResult(intent);
      if (result != null) {
        var signature = result.data.getExtra("signature");
        if (signature != null && signature is String) {
          event.sig = signature;
          return event;
        }

        signature = result.data.getExtra("result");
        if (signature != null && signature is String) {
          event.sig = signature;
          return event;
        }
      }

      return null;
    }, timeout: TIMEOUT);
  }

  Future<List<Object?>?> _getValuesFromCursor(
      NativeCursor? cursor, List<String> columnNames) async {
    if (cursor == null || !(await cursor.moveToFirst())) {
      return null;
    }

    var getIndexBatch = cursor.batchedGet();
    for (var name in columnNames) {
      getIndexBatch.getColumnIndex(name);
    }
    var columnIndexList = await getIndexBatch.commit();

    var getValueBatch = cursor.batchedGet();
    for (var columnIndexObj in columnIndexList) {
      if (columnIndexObj is int) {
        getValueBatch.getString(columnIndexObj);
      }
    }

    return await getValueBatch.commit();
  }

  Future<List<Object?>?> _contentResolverQuery(
      String method, List<String> args, List<String> valueNames) async {
    if (StringUtil.isBlank(_package)) {
      return null;
    }

    try {
      var cursor = await AndroidContentResolver.instance
          .query(uri: "content://$_package.$method", projection: args);
      var values = await _getValuesFromCursor(cursor, valueNames);
      return values;
    } catch (e) {
      print("contentResolverQuery exception");
      print(e);
    }
  }

  @override
  void close() {}
}
