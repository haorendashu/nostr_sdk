import 'package:nostr_sdk/event.dart';
import 'package:nostr_sdk/filter.dart';

import '../event_kind.dart';
import 'relay_db.dart';
import 'relay_local_db.dart';

/// RelayLocalMixin is a mixin that provides methods to real handle events and queries.
/// This mixin usually doesn't direct used. It is used by the other relay class, such RelayLocal and CacheRelay.
mixin RelayLocalMixin {
  RelayDB getRelayDB();

  void callback(String? connId, List<dynamic> list);

  Future<void> doEvent(String? connId, List message) async {
    var event = message[1];
    var id = event["id"];
    var eventKind = event["kind"];
    var pubkey = event["pubkey"];

    if (eventKind == EventKind.EVENT_DELETION) {
      var tags = event["tags"];
      if (tags is List && tags.isNotEmpty) {
        for (var tag in tags) {
          if (tag is List && tag.isNotEmpty && tag.length > 1) {
            var k = tag[0];
            var v = tag[1];
            if (k == "e") {
              getRelayDB().deleteEvent(pubkey, v);
            } else if (k == "a") {
              // TODO should add support delete by aid
            }
          }
        }
      }
    } else {
      if (eventKind == EventKind.METADATA ||
          eventKind == EventKind.CONTACT_LIST) {
        // these eventkind can only save 1 event, so delete other event first.
        getRelayDB().deleteEventByKind(pubkey, eventKind);
      }

      // maybe it shouldn't insert here, due to it doesn't had a source.
      var addResult = await getRelayDB().addEvent(event);
      if (addResult > 0) {
        sendToFilters(connId, event);
      }
    }

    // send callback
    callback(connId, ["OK", id, true]);
  }

  Map<String, List<Filter>> filtersMap = {};

  Future<void> doReq(String? connId, List message) async {
    if (message.length > 2) {
      var subscriptionId = message[1];

      List<Filter> filters = [];
      for (var i = 2; i < message.length; i++) {
        var filterJson = message[i];
        var filter = Filter.fromJson(filterJson);
        filters.add(filter);

        var events = await getRelayDB().doQueryEvent(filterJson);
        for (var event in events) {
          // send callback
          callback(connId, ["EVENT", subscriptionId, event]);
        }
      }
      filtersMap[subscriptionId] = filters;

      // query complete, send callback
      callback(connId, ["EOSE", subscriptionId]);
    }
  }

  void sendToFilters(String? connId, Map<String, dynamic> eventMap) {
    var event = Event.fromJson(eventMap);
    for (var entry in filtersMap.entries) {
      var subscriptionId = entry.key;
      var filters = entry.value;

      var checkResult = false;
      for (var filter in filters) {
        if (filter.checkEvent(event)) {
          checkResult = true;
          break;
        }
      }

      if (checkResult) {
        // send callback
        callback(connId, ["EVENT", subscriptionId, eventMap]);
      }
    }
  }

  void close(String? connId, List message) {
    if (message.length > 2) {
      var subscriptId = message[1];
      filtersMap.remove(subscriptId);
    }
  }

  Future<void> doCount(String? connId, List message) async {
    if (message.length > 2) {
      var subscriptionId = message[1];
      var filter = message[2];
      var count = await getRelayDB().doQueryCount(filter);

      // send callback
      callback(connId, [
        "COUNT",
        subscriptionId,
        {"count": count}
      ]);
    }
  }
}
