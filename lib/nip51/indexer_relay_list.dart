import 'dart:convert';

import 'package:nostr_sdk/event.dart';
import 'package:nostr_sdk/event_kind.dart';
import 'package:nostr_sdk/nostr.dart';
import 'package:nostr_sdk/utils/string_util.dart';

class IndexerRelayList {
  List<String> relays = [];

  static Future<IndexerRelayList?> parse(Event e, Nostr nostr) async {
    var indexerRelayList = IndexerRelayList();

    String? contentSource;
    try {
      contentSource =
          await nostr.nostrSigner.nip44Decrypt(nostr.publicKey, e.content);
    } catch (err) {
      print("IndexerRelayList parse nip44Decrypt error: $err");
    }

    if (StringUtil.isBlank(contentSource)) {
      try {
        contentSource =
            await nostr.nostrSigner.decrypt(nostr.publicKey, e.content);
      } catch (err) {
        print("IndexerRelayList parse decrypt error: $err");
      }
    }

    if (StringUtil.isNotBlank(contentSource)) {
      var contentRelayList = jsonDecode(contentSource!);
      if (contentRelayList is! List) {
        return null;
      }

      for (var relayList in contentRelayList) {
        if (relayList is List && relayList.length > 1) {
          var key = relayList[0];
          var relayAddr = relayList[1];

          if (key == "relay") {
            indexerRelayList.relays.add(relayAddr);
          }
        }
      }
    }

    return indexerRelayList;
  }

  Future<Event?> toEvent(Nostr nostr) async {
    List<dynamic> contentRelayList = [];
    for (var relay in relays) {
      contentRelayList.add(["relay", relay]);
    }

    var content = await nostr.nostrSigner
        .nip44Encrypt(nostr.publicKey, jsonEncode(contentRelayList));
    if (StringUtil.isNotBlank(content)) {
      return null;
    }

    var e = Event(
      nostr.publicKey,
      EventKind.INDEXER_RELAY_LIST,
      [
        ["alt", "Indexer relays from this author"],
      ],
      content!,
    );

    await nostr.signEvent(e);
    return e;
  }
}
