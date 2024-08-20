import 'dart:convert';

import '../relay/relay_status.dart';
import '../utils/string_util.dart';

class NIP02 {
  static String relaysToContent(List<RelayStatus> relayStatuses) {
    Map<String, dynamic> relaysContentMap = {};
    for (var relayStatus in relayStatuses) {
      var readAccess = relayStatus.readAccess;
      var writeAccess = relayStatus.writeAccess;

      relaysContentMap[relayStatus.addr] = {
        "read": readAccess,
        "write": writeAccess,
      };
    }
    return jsonEncode(relaysContentMap);
  }

  static List<RelayStatus> parseContenToRelays(String content) {
    List<RelayStatus> relayStatuses = [];
    var jsonObj = jsonDecode(content);
    Map<dynamic, dynamic> jsonMap =
        jsonObj.map((key, value) => MapEntry(key, true));

    for (var entry in jsonMap.entries) {
      var key = entry.key.toString();
      var value = jsonObj[key];

      var readAcccess = value["read"] == true;
      var writeAcccess = value["write"] == true;

      var relayStatus = RelayStatus(key);
      relayStatus.readAccess = readAcccess;
      relayStatus.writeAccess = writeAcccess;

      relayStatuses.add(relayStatus);
    }

    return relayStatuses;
  }
}
