import '../event_kind.dart';
import 'relay_local_db.dart';

mixin RelayLocalMixin {
  RelayLocalDB getRelayLocalDB();

  void callback(String? connId, List<dynamic> list);

  void doEvent(String? connId, List message) {
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
              getRelayLocalDB().deleteEvent(pubkey, v);
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
        getRelayLocalDB().deleteEventByKind(pubkey, eventKind);
      }

      // maybe it shouldn't insert here, due to it doesn't had a source.
      getRelayLocalDB().addEvent(event);
    }

    // send callback
    callback(connId, ["OK", id, true]);
  }

  Future<void> doReq(String? connId, List message) async {
    if (message.length > 2) {
      var subscriptionId = message[1];

      for (var i = 2; i < message.length; i++) {
        var filter = message[i];

        var events = await getRelayLocalDB().doQueryEvent(filter);
        for (var event in events) {
          // send callback
          callback(connId, ["EVENT", subscriptionId, event]);
        }
      }

      // query complete, send callback
      callback(connId, ["EOSE", subscriptionId]);
    }
  }

  Future<void> doCount(String? connId, List message) async {
    if (message.length > 2) {
      var subscriptionId = message[1];
      var filter = message[2];
      var count = await getRelayLocalDB().doQueryCount(filter);

      // send callback
      callback(connId, [
        "COUNT",
        subscriptionId,
        {"count": count}
      ]);
    }
  }
}
