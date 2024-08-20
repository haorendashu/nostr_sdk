import 'package:nostr_sdk/nostr.dart';

import '../event.dart';
import '../event_kind.dart';
import 'group_identifier.dart';

class NIP29 {
  static void deleteEvent(
      Nostr nostr, GroupIdentifier groupIdentifier, String eventId) {
    var relays = [groupIdentifier.host];
    var event = Event(
        nostr.publicKey,
        EventKind.GROUP_DELETE_EVENT,
        [
          ["h", groupIdentifier.groupId],
          ["e", eventId]
        ],
        "");
    nostr.sendEvent(event, tempRelays: relays, targetRelays: relays);
  }

  static void editStatus(
      Nostr nostr, GroupIdentifier groupIdentifier, bool? public, bool? open) {
    if (public == null && open == null) {
      return;
    }

    var tags = [];
    tags.add(["h", groupIdentifier.groupId]);
    if (public != null) {
      if (public) {
        tags.add(["public"]);
      } else {
        tags.add(["private"]);
      }
    }
    if (open != null) {
      if (open) {
        tags.add(["open"]);
      } else {
        tags.add(["closed"]);
      }
    }

    var relays = [groupIdentifier.host];
    var event = Event(nostr!.publicKey, EventKind.GROUP_EDIT_STATUS, tags, "");
    nostr!.sendEvent(event, tempRelays: relays, targetRelays: relays);
  }

  static Future<void> addMember(
      Nostr nostr, GroupIdentifier groupIdentifier, String pubkey) async {
    var relays = [groupIdentifier.host];
    var event = Event(
        nostr.publicKey,
        EventKind.GROUP_ADD_USER,
        [
          ["h", groupIdentifier.groupId],
          ["p", pubkey]
        ],
        "");
    await nostr.sendEvent(event, tempRelays: relays, targetRelays: relays);
  }

  static Future<void> removeMember(
      Nostr nostr, GroupIdentifier groupIdentifier, String pubkey) async {
    var relays = [groupIdentifier.host];
    var event = Event(
        nostr.publicKey,
        EventKind.GROUP_REMOVE_USER,
        [
          ["h", groupIdentifier.groupId],
          ["p", pubkey]
        ],
        "");

    await nostr.sendEvent(event, tempRelays: relays, targetRelays: relays);
  }
}
