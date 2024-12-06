import 'dart:convert';
import 'package:http/http.dart' as http;
import 'relay_info.dart';

class RelayInfoUtil {
  static Future<RelayInfo?> get(String url) async {
    late Uri uri;
    if (url.startsWith("wss://")) {
      uri = Uri.parse(url).replace(scheme: 'https');
    } else if (url.startsWith("ws://")) {
      uri = Uri.parse(url).replace(scheme: 'http');
    } else if (!url.contains("://")) {
      url = 'https://$url';
      uri = Uri.parse(url);
    }

    try {
      final response =
          await http.get(uri, headers: {'Accept': 'application/nostr+json'});
      final decodedResponse = jsonDecode(response.body) as Map;
      return RelayInfo.fromJson(decodedResponse);
    } catch (e) {
      print("RelayInfo get error:");
      print(e);
    }

    return null;
  }
}
