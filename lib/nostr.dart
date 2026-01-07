import 'dart:async';

import 'client_utils/keys.dart';
import 'event.dart';
import 'event_kind.dart';
import 'event_mem_box.dart';
import 'nip02/contact_list.dart';
import 'relay/event_filter.dart';
import 'relay/relay.dart';
import 'relay/relay_pool.dart';
import 'relay/relay_type.dart';
import 'signer/nostr_signer.dart';
import 'signer/pubkey_only_nostr_signer.dart';
import 'utils/string_util.dart';

class Nostr {
  late RelayPool _pool;

  NostrSigner nostrSigner;

  String _publicKey;

  Function(String, String)? onNotice;

  Relay Function(String) tempRelayGener;

  Nostr(this.nostrSigner, this._publicKey, List<EventFilter> eventFilters,
      this.tempRelayGener,
      {this.onNotice}) {
    _pool = RelayPool(this, eventFilters, tempRelayGener, onNotice: onNotice);
  }

  String get publicKey => _publicKey;

  Future<Event?> sendLike(String id,
      {String? pubkey, String? content, List<String>? targetRelays}) async {
    content ??= "+";

    Event event = Event(
        _publicKey,
        EventKind.REACTION,
        [
          ["e", id]
        ],
        content);
    return await sendEvent(event, targetRelays: targetRelays);
  }

  Future<Event?> deleteEvent(String eventId,
      {List<String>? targetRelays}) async {
    Event event = Event(
        _publicKey,
        EventKind.EVENT_DELETION,
        [
          ["e", eventId]
        ],
        "delete");
    return await sendEvent(event, targetRelays: targetRelays);
  }

  Future<Event?> deleteEvents(List<String> eventIds,
      {List<String>? targetRelays}) async {
    List<List<dynamic>> tags = [];
    for (var eventId in eventIds) {
      tags.add(["e", eventId]);
    }

    Event event = Event(_publicKey, EventKind.EVENT_DELETION, tags, "delete");
    return await sendEvent(event, targetRelays: targetRelays);
  }

  Future<Event?> sendRepost(String id,
      {String? relayAddr,
      String content = "",
      List<String>? targetRelays}) async {
    List<dynamic> tag = ["e", id];
    if (StringUtil.isNotBlank(relayAddr)) {
      tag.add(relayAddr);
    }
    Event event = Event(_publicKey, EventKind.REPOST, [tag], content);
    return await sendEvent(event, targetRelays: targetRelays);
  }

  Future<Event?> sendContactList(ContactList contacts, String content,
      {List<String>? targetRelays}) async {
    final tags = contacts.toJson();
    final event = Event(_publicKey, EventKind.CONTACT_LIST, tags, content);
    return await sendEvent(event, targetRelays: targetRelays);
  }

  Future<Event?> sendEvent(
    Event event, {
    List<String>? targetRelays,
    List<int> relayTypes = RelayType.NORMAL_AND_CACHE,
  }) async {
    if (StringUtil.isBlank(event.sig)) {
      await signEvent(event);
    }
    if (StringUtil.isBlank(event.sig)) {
      return null;
    }

    var result = _pool.send(
      ["EVENT", event.toJson()],
      targetRelays: targetRelays,
      relayTypes: relayTypes,
      bothRelay: true,
    );
    if (result) {
      return event;
    }
    return null;
  }

  void checkEventSign(Event event) {
    if (StringUtil.isBlank(event.sig)) {
      throw StateError("Event is not signed");
    }
  }

  Future<void> signEvent(Event event) async {
    var ne = await nostrSigner.signEvent(event);
    if (ne != null) {
      event.id = ne.id;
      event.sig = ne.sig;
    }
  }

  Event? broadcase(
    Event event, {
    List<String>? targetRelays,
    List<int> relayTypes = RelayType.NORMAL_AND_CACHE,
  }) {
    var result = _pool.send(
      ["EVENT", event.toJson()],
      targetRelays: targetRelays,
      relayTypes: relayTypes,
    );
    if (result) {
      return event;
    }
    return null;
  }

  bool _isClose = false;

  // close and you shouldn't use it again.
  void close() {
    _isClose = true;
    _pool.removeAll();
    nostrSigner.close();
  }

  bool isClose() {
    return _isClose;
  }

  void addInitQuery(List<Map<String, dynamic>> filters, Function(Event) onEvent,
      {String? id, Function? onComplete}) {
    _pool.addInitQuery(filters, onEvent, id: id, onComplete: onComplete);
  }

  // bool tempRelayHasSubscription(String relayAddr) {
  //   return _pool.tempRelayHasSubscription(relayAddr);
  // }

  String subscribe(
    List<Map<String, dynamic>> filters,
    Function(Event) onEvent, {
    String? id,
    List<String>? targetRelays,
    List<int> relayTypes = RelayType.NORMAL_AND_CACHE,
    bool sendAfterAuth =
        false, // if relay not connected, it will send after auth
  }) {
    return _pool.subscribe(
      filters,
      onEvent,
      id: id,
      targetRelays: targetRelays,
      relayTypes: relayTypes,
      sendAfterAuth: sendAfterAuth,
    );
  }

  void unsubscribe(String id) {
    _pool.unsubscribe(id);
  }

  Future<List<Event>> queryEvents(
    List<Map<String, dynamic>> filters, {
    String? id,
    List<String>? targetRelays,
    List<int> relayTypes = RelayType.NORMAL_AND_CACHE,
    bool sendAfterAuth = false,
  }) async {
    var eventBox = EventMemBox(sortAfterAdd: false);
    var completer = Completer();

    query(
      filters,
      id: id,
      targetRelays: targetRelays,
      relayTypes: relayTypes,
      sendAfterAuth: sendAfterAuth,
      (event) {
        eventBox.add(event);
      },
      onComplete: () {
        completer.complete();
      },
    );

    await completer.future;
    return eventBox.all();
  }

  String query(
    List<Map<String, dynamic>> filters,
    Function(Event) onEvent, {
    String? id,
    Function? onComplete, // all relay EOSE call this method
    Function(String)? onEOSE, // every relay EOSE call this method
    List<String>? targetRelays,
    List<int> relayTypes = RelayType.NORMAL_AND_CACHE,
    bool sendAfterAuth = false,
    bool bothRelay = false,
  }) {
    return _pool.query(
      filters,
      onEvent,
      id: id,
      onComplete: onComplete,
      onEOSE: onEOSE,
      targetRelays: targetRelays,
      relayTypes: relayTypes,
      sendAfterAuth: sendAfterAuth,
      bothRelay: bothRelay,
    );
  }

  String queryByFilters(Map<String, List<Map<String, dynamic>>> filtersMap,
      Function(Event) onEvent,
      {String? id, Function? onComplete}) {
    return _pool.queryByFilters(filtersMap, onEvent,
        id: id, onComplete: onComplete);
  }

  Future<bool> addRelay(
    Relay relay, {
    bool autoSubscribe = false,
    bool init = false,
    int relayType = RelayType.NORMAL,
  }) async {
    return await _pool.add(relay,
        autoSubscribe: autoSubscribe, init: init, relayType: relayType);
  }

  void removeRelay(String url) {
    _pool.remove(url);
  }

  List<Relay> normalRelays() {
    return _pool.normalRelays();
  }

  // List<Relay> activeRelays() {
  //   return _pool.activeRelays();
  // }

  Relay? getRelay(String url) {
    return _pool.getRelay(url);
  }

  void reconnect() {
    print("nostr reconnect");
    _pool.reconnect();
  }

  List<String> getExtralReadableRelays(
      List<String> extralRelays, int maxRelayNum) {
    return _pool.getExtralReadableRelays(extralRelays, maxRelayNum);
  }

  bool readable() {
    return _pool.readable();
  }

  bool writable() {
    return _pool.writable();
  }

  bool isReadOnly() {
    return nostrSigner is PubkeyOnlyNostrSigner;
  }
}
