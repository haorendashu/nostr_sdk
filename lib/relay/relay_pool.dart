import 'dart:convert';
import 'dart:developer';

import '../event.dart';
import '../event_kind.dart';
import '../nostr.dart';
import '../relay_local/relay_local.dart';
import '../subscription.dart';
import '../utils/string_util.dart';
import 'client_connected.dart';
import 'event_filter.dart';
import 'relay.dart';
import 'relay_base.dart';
import 'relay_isolate.dart';

class RelayPool {
  Nostr localNostr;

  final Map<String, Relay> _tempRelays = {};

  final Map<String, Relay> _relays = {};

  // subscription
  final Map<String, Subscription> _subscriptions = {};

  // init query
  final Map<String, Subscription> _initQuery = {};

  final Map<String, Function> _queryCompleteCallbacks = {};

  RelayLocal? relayLocal;

  List<EventFilter> eventFilters;

  Function(String, String)? onNotice;

  Relay Function(String) tempRelayGener;

  RelayPool(
    this.localNostr,
    this.eventFilters,
    this.tempRelayGener, {
    this.onNotice,
  });

  Future<bool> add(
    Relay relay, {
    bool autoSubscribe = false,
    bool init = false,
  }) async {
    if (_relays.containsKey(relay.url)) {
      return true;
    }
    relay.onMessage = _onEvent;
    // add to pool first and will reconnect by pool
    _relays[relay.url] = relay;

    if (relay is RelayLocal) {
      relayLocal = relay;
    }

    if (await relay.connect()) {
      if (autoSubscribe) {
        for (Subscription subscription in _subscriptions.values) {
          relay.send(subscription.toJson());
        }
      }
      if (init) {
        for (Subscription subscription in _initQuery.values) {
          relayDoQuery(relay, subscription, false);
        }
      }

      return true;
    } else {
      print("relay connect fail! ${relay.url}");
    }

    relay.relayStatus.onError();
    return false;
  }

  List<Relay> activeRelays() {
    List<Relay> list = [];
    var it = _relays.values;
    for (var relay in it) {
      if (relay.relayStatus.connected == ClientConneccted.CONNECTED) {
        list.add(relay);
      }
    }
    return list;
  }

  void removeAll() {
    var keys = _relays.keys;
    for (var url in keys) {
      _relays[url]?.disconnect();
      _relays[url]?.dispose();
    }
    _relays.clear();
  }

  void remove(String url) {
    log('Removing $url');
    _relays[url]?.disconnect();
    _relays[url]?.dispose();
    _relays.remove(url);
  }

  Relay? getRelay(String url) {
    return _relays[url];
  }

  bool relayDoQuery(Relay relay, Subscription subscription, bool sendAfterAuth,
      {bool runBeforeConnected = false}) {
    if ((!runBeforeConnected &&
            relay.relayStatus.connected != ClientConneccted.CONNECTED) ||
        !relay.relayStatus.readAccess) {
      return false;
    }

    relay.saveQuery(subscription);
    relay.relayStatus.onQuery();

    try {
      var message = subscription.toJson();
      if (sendAfterAuth && !relay.relayStatus.authed) {
        relay.pendingAuthedMessages.add(message);
        return true;
      } else {
        if (relay.relayStatus.connected == ClientConneccted.CONNECTED) {
          return relay.send(message);
        } else {
          relay.pendingMessages.add(message);
          return true;
        }
      }
    } catch (err) {
      log(err.toString());
      relay.relayStatus.onError();
    }

    return false;
  }

  Future<void> _onEvent(Relay relay, List<dynamic> json) async {
    final messageType = json[0];
    if (messageType == 'EVENT') {
      try {
        if (relayLocal != null && relay is! RelayLocal) {
          var event = Map<String, dynamic>.from(json[2]);
          var kind = event["kind"];
          if (kind != EventKind.NOSTR_REMOTE_SIGNING) {
            event["sources"] = [relay.url];
            relayLocal!.broadcaseToLocal(event);
          }
        }

        final event = Event.fromJson(json[2]);

        // add some statistics
        relay.relayStatus.noteReceive();

        // check block pubkey
        for (var eventFilter in eventFilters) {
          if (eventFilter.check(event)) {
            return;
          }
        }
        // if (filterProvider.checkBlock(event.pubkey)) {
        //   return;
        // }
        // // check dirtyword
        // if (filterProvider.checkDirtyword(event.content)) {
        //   return;
        // }

        if (relay is RelayLocal) {
          // local message read source from json
          var sources = json[2]["sources"];
          if (sources != null && sources is List) {
            for (var source in sources) {
              event.sources.add(source);
            }
          }
          // mark this event is from local relay.
          event.localEvent = true;
        } else {
          event.sources.add(relay.url);
        }
        final subId = json[1] as String;
        var subscription = _subscriptions[subId];

        if (subscription != null) {
          subscription.onEvent(event);
        } else {
          subscription = relay.getRequestSubscription(subId);
          subscription?.onEvent(event);
        }
      } catch (err) {
        log(err.toString());
      }
    } else if (messageType == 'EOSE') {
      if (json.length < 2) {
        log("EOSE result not right.");
        return;
      }

      final subId = json[1] as String;
      var isQuery = relay.checkAndCompleteQuery(subId);
      if (isQuery) {
        // is Query find if need to callback
        var callback = _queryCompleteCallbacks[subId];
        if (callback != null) {
          // need to callback, check if all relay complete query
          List<Relay> list = [..._relays.values];
          list.addAll(_tempRelays.values);
          bool completeQuery = true;
          for (var r in list) {
            if (r.checkQuery(subId)) {
              // this relay hadn't compltete query
              completeQuery = false;
              break;
            }
          }
          if (completeQuery) {
            callback();
            _queryCompleteCallbacks.remove(subId);
          }
        }
      }
    } else if (messageType == "NOTICE") {
      if (json.length < 2) {
        log("NOTICE result not right.");
        return;
      }

      // notice save, TODO maybe should change code
      if (onNotice != null) {
        onNotice!(relay.url, json[1] as String);
      }
    } else if (messageType == "AUTH") {
      // auth needed
      if (json.length < 2) {
        log("AUTH result not right.");
        return;
      }

      final challenge = json[1] as String;
      var tags = [
        ["relay", relay.relayStatus.addr],
        ["challenge", challenge]
      ];
      Event? event =
          Event(localNostr.publicKey, EventKind.AUTHENTICATION, tags, "");
      event = await localNostr.nostrSigner.signEvent(event);
      if (event != null) {
        relay.send(["AUTH", event.toJson()], forceSend: true);

        relay.relayStatus.authed = true;

        if (relay.pendingAuthedMessages.isNotEmpty) {
          Future.delayed(const Duration(seconds: 1), () {
            for (var message in relay.pendingAuthedMessages) {
              relay.send(message);
            }
            relay.pendingAuthedMessages.clear();
          });
        }
      }
    }
  }

  void addInitQuery(List<Map<String, dynamic>> filters, Function(Event) onEvent,
      {String? id, Function? onComplete}) {
    if (filters.isEmpty) {
      throw ArgumentError("No filters given", "filters");
    }

    final Subscription subscription = Subscription(filters, onEvent, id);
    _initQuery[subscription.id] = subscription;
    if (onComplete != null) {
      _queryCompleteCallbacks[subscription.id] = onComplete;
    }
  }

  /// subscribe shoud be a long time filter search.
  /// like: subscribe the newest event、notice.
  /// subscribe info will hold in reply pool and close in reply pool.
  /// subscribe can be subscribe when new relay put into pool.
  String subscribe(List<Map<String, dynamic>> filters, Function(Event) onEvent,
      {String? id}) {
    if (filters.isEmpty) {
      throw ArgumentError("No filters given", "filters");
    }

    final Subscription subscription = Subscription(filters, onEvent, id);
    _subscriptions[subscription.id] = subscription;
    send(subscription.toJson());
    return subscription.id;
  }

  void unsubscribe(String id) {
    final subscription = _subscriptions.remove(id);
    if (subscription != null) {
      send(["CLOSE", subscription.id]);
    } else {
      // check query and send close
      var it = _relays.values;
      for (var relay in it) {
        relay.checkAndCompleteQuery(id);
      }
    }
  }

  // different relay use different filter
  String queryByFilters(Map<String, List<Map<String, dynamic>>> filtersMap,
      Function(Event) onEvent,
      {String? id, Function? onComplete}) {
    if (filtersMap.isEmpty) {
      throw ArgumentError("No filters given", "filters");
    }
    id ??= StringUtil.rndNameStr(16);
    if (onComplete != null) {
      _queryCompleteCallbacks[id] = onComplete;
    }
    var entries = filtersMap.entries;
    for (var entry in entries) {
      var url = entry.key;
      var filters = entry.value;

      var relay = _relays[url];
      if (relay != null) {
        Subscription subscription = Subscription(filters, onEvent, id);
        relayDoQuery(relay, subscription, false);
      }
    }
    return id;
  }

  /// query should be a one time filter search.
  /// like: query metadata, query old event.
  /// query info will hold in relay and close in relay when EOSE message be received.
  /// if onlyTempRelays is true and tempRelays is not empty, it will only query throw tempRelays.
  /// if onlyTempRelays is false and tempRelays is not empty, it will query bath myRelays and tempRelays.
  String query(
    List<Map<String, dynamic>> filters,
    Function(Event) onEvent, {
    String? id,
    Function? onComplete,
    List<String>? tempRelays,
    bool onlyTempRelays = true,
    bool queryLocal = true,
    bool sendAfterAuth =
        false, // if relay not connected, it will send after auth
    bool? runBeforeConnected,
  }) {
    if (filters.isEmpty) {
      throw ArgumentError("No filters given", "filters");
    }
    Subscription subscription = Subscription(filters, onEvent, id);
    if (onComplete != null) {
      _queryCompleteCallbacks[subscription.id] = onComplete;
    }

    // send throw tempRelay
    if (tempRelays != null) {
      for (var tempRelayAddr in tempRelays) {
        if (_relays[tempRelayAddr] != null) {
          continue;
        }

        var tempRelay = checkAndGenTempRelay(tempRelayAddr);
        relayDoQuery(tempRelay, subscription, sendAfterAuth,
            runBeforeConnected: true);
      }
    }

    if (!((tempRelays != null && tempRelays.isNotEmpty) && onlyTempRelays)) {
      // send throw my relay
      for (Relay relay in _relays.values) {
        if (relay is RelayLocal && !queryLocal) {
          continue;
        }
        relayDoQuery(relay, subscription, sendAfterAuth);
      }
    }
    return subscription.id;
  }

  /// send message to relay
  /// there are tempRelays, it also send to tempRelays too.
  bool send(List<dynamic> message,
      {List<String>? tempRelays, List<String>? targetRelays}) {
    bool hadSubmitSend = false;

    for (Relay relay in _relays.values) {
      if (message[0] == "EVENT") {
        if (!relay.relayStatus.writeAccess) {
          continue;
        }
      }

      if (targetRelays != null && targetRelays.isNotEmpty) {
        if (!targetRelays.contains(relay.url)) {
          // not contain this relay
          continue;
        }
      }

      try {
        var result = relay.send(message);
        if (result) {
          hadSubmitSend = true;
        }
      } catch (err) {
        log(err.toString());
        relay.relayStatus.onError();
      }
    }

    if (tempRelays != null) {
      for (var tempRelayAddr in tempRelays) {
        var tempRelay = checkAndGenTempRelay(tempRelayAddr);
        if (tempRelay.relayStatus.connected == ClientConneccted.CONNECTED) {
          tempRelay.send(message);
          hadSubmitSend = true;
        } else {
          tempRelay.pendingMessages.add(message);
          hadSubmitSend = true;
        }
      }
    }

    return hadSubmitSend;
  }

  void reconnect() {
    for (var relay in _relays.values) {
      relay.connect();
    }
  }

  Relay checkAndGenTempRelay(String addr) {
    var tempRelay = _tempRelays[addr];
    if (tempRelay == null) {
      tempRelay = tempRelayGener(addr);
      tempRelay.onMessage = _onEvent;
      tempRelay.connect();
      _tempRelays[addr] = tempRelay;
    }

    return tempRelay;
  }

  List<String> getExtralReadableRelays(
      List<String> extralRelays, int maxRelayNum) {
    List<String> list = [];

    int sameNum = 0;
    for (var extralRelay in extralRelays) {
      var relay = _relays[extralRelay];
      if (relay == null || !relay.relayStatus.readAccess) {
        // not contains or can't readable
        list.add(extralRelay);
      } else {
        sameNum++;
      }
    }

    var needExtralNum = maxRelayNum - sameNum;
    if (needExtralNum <= 0) {
      return [];
    }

    if (list.length < needExtralNum) {
      return list;
    }

    return list.sublist(0, needExtralNum);
  }

  void removeTempRelay(String addr) {
    var relay = _tempRelays.remove(addr);
    if (relay != null) {
      relay.disconnect();
    }
  }

  Relay? getTempRelay(String url) {
    return _tempRelays[url];
  }

  bool readable() {
    for (var relay in _relays.values) {
      if (relay.relayStatus.connected == ClientConneccted.CONNECTED &&
          relay.relayStatus.readAccess) {
        return true;
      }
    }

    return false;
  }

  bool writable() {
    for (var relay in _relays.values) {
      if (relay.relayStatus.connected == ClientConneccted.CONNECTED &&
          relay.relayStatus.writeAccess) {
        return true;
      }
    }

    return false;
  }
}
