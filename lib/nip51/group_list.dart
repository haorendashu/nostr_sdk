import 'package:nostr_sdk/event.dart';
import 'package:nostr_sdk/nostr.dart';

import '../event_kind.dart';
import '../nip29/group_identifier.dart';

class GroupList {
  List<GroupIdentifier> groupIdentifiers = [];

  static GroupList parse(Event event, Nostr nostr) {
    GroupList groupList = GroupList();

    for (var tag in event.tags) {
      if (tag is List && tag.length > 2) {
        var k = tag[0];
        var groupId = tag[1];
        var host = tag[2];
        if (k == "group") {
          var gi = GroupIdentifier(host, groupId);
          groupList.groupIdentifiers.add(gi);
        }
      }
    }

    return groupList;
  }

  Future<Event> toEvent(Nostr nostr) async {
    List tags = [];
    for (var item in groupIdentifiers) {
      tags.add(item.toJson());
    }

    var event = Event(nostr.publicKey, EventKind.GROUP_LIST, tags, "");
    await nostr.signEvent(event);
    return event;
  }

  void clear() {
    groupIdentifiers.clear();
  }
}
