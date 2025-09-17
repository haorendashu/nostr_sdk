import 'package:nostr_sdk/nostr.dart';
import 'package:nostr_sdk/utils/relay_addr_util.dart';

import '../event.dart';
import '../event_kind.dart';

class RelayListMetadata {
  late String pubkey;

  late int createdAt;

  // late List<RelayListMetadataItem> relays;

  late List<String> readAbleRelays;

  late List<String> writeAbleRelays;

  Map<String, int> relayRWMap = {};

  RelayListMetadata.fromRelayList(List<String> relays) {
    readAbleRelays = [];
    writeAbleRelays = [];
    pubkey = "";
    createdAt = 0;

    for (var addr in relays) {
      addr = RelayAddrUtil.handle(addr);
      readAbleRelays.add(addr);
      writeAbleRelays.add(addr);
      relayRWMap[addr] = RelayRW.READ_WRITE;
    }
  }

  RelayListMetadata.fromEvent(Event event) {
    pubkey = event.pubkey;
    createdAt = event.createdAt;
    // relays = [];
    readAbleRelays = [];
    writeAbleRelays = [];
    if (event.kind == EventKind.RELAY_LIST_METADATA) {
      for (var tag in event.tags) {
        if (tag is List && tag.length > 1) {
          var k = tag[0];
          if (k != "r") {
            continue;
          }

          var addr = tag[1];
          addr = RelayAddrUtil.handle(addr);
          bool writeAble = true;
          bool readAble = true;

          if (tag.length > 2) {
            var rw = tag[2];
            if (rw == "write") {
              readAble = false;
            } else if (rw == "read") {
              writeAble = false;
            }
          }

          // var item = RelayListMetadataItem(addr,
          //     writeAble: writeAble, readAble: readAble);
          // relays.add(item);
          if (readAble) {
            readAbleRelays.add(addr);
          }
          if (writeAble) {
            writeAbleRelays.add(addr);
          }

          if (readAble && writeAble) {
            relayRWMap[addr] = RelayRW.READ_WRITE;
          } else if (readAble) {
            relayRWMap[addr] = RelayRW.READ;
          } else if (writeAble) {
            relayRWMap[addr] = RelayRW.WRITE;
          }
        }
      }
    }
  }

  Future<Event> toEvent(Nostr nostr) async {
    List<dynamic> tags = [];
    Map<String, List<dynamic>> relaysTag = {};
    for (var addr in readAbleRelays) {
      addr = RelayAddrUtil.handle(addr);

      var relayTag = relaysTag[addr];
      if (relayTag == null) {
        relayTag = ["r", addr, "read"];
        relaysTag[addr] = relayTag;
      }
    }
    for (var addr in writeAbleRelays) {
      addr = RelayAddrUtil.handle(addr);

      var relayTag = relaysTag[addr];
      if (relayTag == null) {
        relayTag = ["r", addr, "write"];
        relaysTag[addr] = relayTag;
      } else {
        // there was a relayTag, add write to it
        relayTag = ["r", addr];
        relaysTag[addr] = relayTag;
      }
    }

    var e = Event(
      pubkey,
      EventKind.RELAY_LIST_METADATA,
      tags,
      "",
    );

    await nostr.signEvent(e);
    return e;
  }
}

// class RelayListMetadataItem {
//   String addr;

//   bool writeAble = true;

//   bool readAble = true;

//   RelayListMetadataItem(
//     this.addr, {
//     this.writeAble = true,
//     this.readAble = true,
//   });
// }

class RelayRW {
  static const READ = -1;
  static const READ_WRITE = 0;
  static const WRITE = 1;
}
