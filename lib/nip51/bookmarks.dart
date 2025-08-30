import 'dart:convert';

import '../event.dart';
import '../event_kind.dart';
import '../event_relation.dart';
import '../nostr.dart';
import '../utils/string_util.dart';

class Bookmarks {
  List<BookmarkItem> privateItems = [];
  List<BookmarkItem> publicItems = [];

  static Future<Bookmarks?> parse(Event e, Nostr nostr) async {
    var bookmarks = Bookmarks();
    var content = e.content;
    if (StringUtil.isNotBlank(content)) {
      String? plainContent;
      try {
        plainContent =
            await nostr.nostrSigner.nip44Decrypt(nostr.publicKey, content);
      } catch (err) {
        print("Bookmarks event content nip44Decrypt error ${err.toString()}");
      }

      if (StringUtil.isBlank(plainContent)) {
        try {
          plainContent =
              await nostr.nostrSigner.decrypt(nostr.publicKey, content);
        } catch (err) {
          print("Bookmarks event content decrypt error ${err.toString()}");
        }
      }

      dynamic jsonObj;
      if (StringUtil.isNotBlank(plainContent)) {
        jsonObj = jsonDecode(plainContent!);
      }

      if (jsonObj is List) {
        List<BookmarkItem> privateItems = [];
        for (var jsonObjItem in jsonObj) {
          if (jsonObjItem is List && jsonObjItem.length > 1) {
            var key = jsonObjItem[0];
            var value = jsonObjItem[1];
            if (key is String && value is String) {
              privateItems.add(BookmarkItem(key: key, value: value));
            }
          }
        }

        bookmarks.privateItems = privateItems;
      }
    }

    List<BookmarkItem> publicItems = [];
    for (var jsonObjItem in e.tags) {
      if (jsonObjItem is List && jsonObjItem.length > 1) {
        var key = jsonObjItem[0];
        var value = jsonObjItem[1];
        if (key is String && value is String) {
          publicItems.add(BookmarkItem(key: key, value: value));
        }
      }
    }
    bookmarks.publicItems = publicItems;

    return bookmarks;
  }

  Future<Event?> toEvent(Nostr nostr) async {
    String? content = "";
    if (privateItems.isNotEmpty) {
      List<List> list = [];
      for (var item in privateItems) {
        list.add(item.toJson());
      }

      var jsonText = jsonEncode(list);
      content = await nostr.nostrSigner.nip44Encrypt(nostr.publicKey, jsonText);
      if (StringUtil.isBlank(content)) {
        return null;
      }
    }

    List tags = [];
    for (var item in publicItems) {
      tags.add(item.toJson());
    }

    var event =
        Event(nostr.publicKey, EventKind.BOOKMARKS_LIST, tags, content!);
    await nostr.signEvent(event);
    return event;
  }
}

class BookmarkItem {
  String key;

  String value;

  BookmarkItem({
    required this.key,
    required this.value,
  });

  List<dynamic> toJson() {
    List<dynamic> list = [];
    list.add(key);
    list.add(value);
    return list;
  }

  static BookmarkItem getFromEventReactions(EventRelation eventRelation) {
    var key = "e";
    var value = eventRelation.id;
    var aId = eventRelation.aId;
    if (aId != null) {
      key = "a";
      value = aId.toAString();
    }
    return BookmarkItem(key: key, value: value);
  }
}
