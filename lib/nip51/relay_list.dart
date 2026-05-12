import '../event.dart';
import '../nostr.dart';

class RelayList {
  int eventKind;

  List<String> relays = [];

  int createdAt;

  RelayList(this.eventKind, this.createdAt);

  static RelayList parse(Event event) {
    RelayList relayList = RelayList(event.kind, event.createdAt);

    for (var tag in event.tags) {
      if (tag is List && tag.length > 1) {
        var k = tag[0];
        var v = tag[1];
        if (k == "relay") {
          relayList.relays.add(v);
        }
      }
    }

    return relayList;
  }

  Future<Event> toEvent(Nostr nostr) async {
    List tags = [];
    for (var item in relays) {
      tags.add(["relay", item]);
    }

    var event = Event(nostr.publicKey, eventKind, tags, "");
    await nostr.signEvent(event);
    return event;
  }

  void clear() {
    relays.clear();
  }
}
