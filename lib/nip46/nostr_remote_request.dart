import 'dart:convert';

import '../signer/nostr_signer.dart';
import '../utils/string_util.dart';

class NostrRemoteRequest {
  String id;

  String method;

  List<String> params;

  NostrRemoteRequest(this.method, this.params) : id = StringUtil.rndNameStr(12);

  Future<String?> encrypt(NostrSigner signer, String pubkey) async {
    var jsonMap = Map();
    jsonMap["id"] = id;
    jsonMap["method"] = method;
    jsonMap["params"] = params;

    var jsonStr = jsonEncode(jsonMap);
    return await signer.encrypt(pubkey, jsonStr);
  }
}
