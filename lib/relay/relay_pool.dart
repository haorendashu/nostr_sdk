import 'dart:developer';

import 'package:nostr_sdk/utils/relay_addr_util.dart';

import '../event.dart';
import '../event_kind.dart';
import '../nostr.dart';
import '../relay_local/relay_local.dart';
import '../subscription.dart';
import '../utils/string_util.dart';
import 'client_connected.dart';
import 'event_filter.dart';
import 'relay.dart';
import 'relay_type.dart';

class RelayPool {
  // avoid to send these events to cache relay
  static List<int> CACHE_AVOID_EVENTS = [
    EventKind.NOSTR_REMOTE_SIGNING,
    EventKind.GROUP_METADATA,
    EventKind.GROUP_ADMINS,
    EventKind.GROUP_MEMBERS,
    EventKind.GROUP_CHAT_MESSAGE,
    EventKind.GROUP_NOTE,
    EventKind.COMMENT,
  ];

  Nostr localNostr;

  final Map<String, Relay> _tempRelays = {};

  final Map<String, Relay> _relays = {};

  final Map<String, Relay> _cacheRelays = {};

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
    int relayType = RelayType.NORMAL,
  }) async {
    if (relayType == RelayType.NORMAL) {
      if (_relays.containsKey(relay.url)) {
        return true;
      } else {
        _relays[relay.url] = relay;
      }
    } else if (relayType == RelayType.CACHE) {
      if (_cacheRelays.containsKey(relay.url)) {
        return true;
      } else {
        _cacheRelays[relay.url] = relay;
      }
    }

    relay.onMessage = _onEvent;
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

  void remove(String url, {int relayType = RelayType.NORMAL}) {
    log('Removing $url');
    if (relayType == RelayType.NORMAL) {
      _relays[url]?.disconnect();
      _relays[url]?.dispose();
      _relays.remove(url);
    } else if (relayType == RelayType.CACHE) {
      _cacheRelays[url]?.disconnect();
      _cacheRelays[url]?.dispose();
      _cacheRelays.remove(url);
    }
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
      if ((sendAfterAuth || relay.relayStatus.alwaysAuth) && !relay.relayStatus.authed) {
        // For vine.hol.is, send the query to trigger AUTH challenge
        if (relay.url.contains('vine.hol.is')) {
          print('🔐 vine.hol.is query - sending to trigger AUTH challenge');
          var result = relay.send(message, forceSend: true);
          if (result) {
            return true;
          }
        } else {
          relay.pendingAuthedMessages.add(message);
          return true;
        }
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

  void _broadcaseToCache(Map<String, dynamic> event) {
    if (relayLocal != null) {
      relayLocal!.broadcaseToLocal(event);
    }

    for (var relay in _cacheRelays.values) {
      if (relay.relayStatus.connected == ClientConneccted.CONNECTED) {
        relay.send(["EVENT", event]);
      }
    }
  }

  Future<void> _onEvent(Relay relay, List<dynamic> json) async {
    final messageType = json[0];
    print('📡 Raw message from ${relay.url}: $json');
    
    if (messageType == 'EVENT') {
      try {
        if (relay is! RelayLocal &&
            (relay.relayStatus.relayType != RelayType.CACHE)) {
          var event = Map<String, dynamic>.from(json[2]);
          var kind = event["kind"];
          if (!CACHE_AVOID_EVENTS.contains(kind)) {
            event["sources"] = [relay.url];
            _broadcaseToCache(event);
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

        if (relay is RelayLocal ||
            relay.relayStatus.relayType == RelayType.CACHE) {
          // local message read source from json
          var sources = json[2]["sources"];
          if (sources != null && sources is List) {
            for (var source in sources) {
              event.sources.add(source);
            }
          }
          // mark this event is from local relay.
          event.cacheEvent = true;
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
      // EOSE received for subscription (debug logging removed)
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
    } else if (messageType == "OK") {
      print('📡 OK response from ${relay.url}: $json');
    } else if (messageType == "NOTICE") {
      print('📡 NOTICE from ${relay.url}: $json');
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
      print('🔐 AUTH challenge received from ${relay.url}');
      if (json.length < 2) {
        log("AUTH result not right.");
        return;
      }

      final challenge = json[1] as String;
      print('🔐 Challenge: ${challenge.substring(0, 16)}...');
      var tags = [
        ["relay", relay.relayStatus.addr],
        ["challenge", challenge]
      ];
      Event? event =
          Event(localNostr.publicKey, EventKind.AUTHENTICATION, tags, "");
      event = await localNostr.nostrSigner.signEvent(event);
      if (event != null) {
        print('🔐 Sending AUTH response for challenge: ${challenge.substring(0, 16)}...');
        relay.send(["AUTH", event.toJson()], forceSend: true);

        // Note: Do NOT set authed = true here - wait for relay confirmation
        // The relay needs to confirm our AUTH response before we can send pending messages
        print('🔐 AUTH response sent, waiting for relay confirmation...');

        if (relay.pendingAuthedMessages.isNotEmpty) {
          print('🔐 Pending ${relay.pendingAuthedMessages.length} messages for after auth confirmation');
          Future.delayed(const Duration(seconds: 1), () {
            // TODO: This is a temporary workaround - we should wait for proper AUTH confirmation
            // For now, assume AUTH succeeded after delay
            relay.relayStatus.authed = true;
            print('🔐 Assuming AUTH succeeded, sending ${relay.pendingAuthedMessages.length} pending messages');
            
            for (var message in relay.pendingAuthedMessages) {
              relay.send(message);
            }
            relay.pendingAuthedMessages.clear();

            // send subcription, but some subscrpition will send twice
            if (relay.hasSubscription()) {
              var subs = relay.getSubscriptions();
              for (var subscription in subs) {
                relay.send(subscription.toJson());
              }
            }
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
  String subscribe(
    List<Map<String, dynamic>> filters,
    Function(Event) onEvent, {
    String? id,
    List<String>? tempRelays,
    List<String>? targetRelays,
    List<int> relayTypes = RelayType.ALL,
    bool sendAfterAuth =
        false, // if relay not connected, it will send after auth
  }) {
    if (filters.isEmpty) {
      throw ArgumentError("No filters given", "filters");
    }

    handleAddrList(tempRelays);
    handleAddrList(targetRelays);

    final Subscription subscription = Subscription(filters, onEvent, id);
    _subscriptions[subscription.id] = subscription;
    // send(subscription.toJson());

    // tempRelay, only query those relay which has bean provide
    if (tempRelays != null &&
        tempRelays.isNotEmpty &&
        relayTypes.contains(RelayType.TEMP)) {
      for (var tempRelayAddr in tempRelays) {
        // check if normal relays has this temp relay, try to get relay from normal relays
        Relay? relay = _relays[tempRelayAddr];
        relay ??= checkAndGenTempRelay(tempRelayAddr);

        relayDoSubscribe(relay, subscription, sendAfterAuth,
            runBeforeConnected: true);
      }
    }

    // normal relay, usually will query all the normal relays, but if targetRelays has provide, it only query from the provided querys.
    if (relayTypes.contains(RelayType.NORMAL)) {
      for (var entry in _relays.entries) {
        var relayAddr = entry.key;
        var relay = entry.value;

        if (targetRelays != null) {
          if (!targetRelays.contains(relayAddr)) {
            continue;
          }
        }

        relayDoSubscribe(relay, subscription, sendAfterAuth);
      }
    }

    // cache relay
    if (relayTypes.contains(RelayType.CACHE)) {
      for (var relay in _cacheRelays.values) {
        relayDoSubscribe(relay, subscription, sendAfterAuth);
      }
    }

    // local relay
    if (relayTypes.contains(RelayType.LOCAL) && relayLocal != null) {
      relayDoSubscribe(relayLocal!, subscription, sendAfterAuth);
    }

    return subscription.id;
  }

  bool relayDoSubscribe(
      Relay relay, Subscription subscription, bool sendAfterAuth,
      {bool runBeforeConnected = false}) {
    if ((!runBeforeConnected &&
            relay.relayStatus.connected != ClientConneccted.CONNECTED) ||
        !relay.relayStatus.readAccess) {
      return false;
    }

    relay.relayStatus.onQuery();

    try {
      relay.saveSubscription(subscription);

      var message = subscription.toJson();
      if ((sendAfterAuth || relay.relayStatus.alwaysAuth) && !relay.relayStatus.authed) {
        // For vine.hol.is, send the subscription to trigger AUTH challenge
        if (relay.url.contains('vine.hol.is')) {
          print('🔐 vine.hol.is subscription - sending to trigger AUTH challenge');
          var result = relay.send(message, forceSend: true);
          if (result) {
            return true;
          }
        } else {
          relay.pendingAuthedMessages.add(message);
          return true;
        }
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

  bool tempRelayHasSubscription(String relayAddr) {
    var relay = _tempRelays[relayAddr];
    if (relay != null) {
      return relay.hasSubscription();
    }

    return false;
  }

  void unsubscribe(String id) {
    final subscription = _subscriptions.remove(id);
    if (subscription != null) {
      // check query and send close
      var it = _relays.values;
      for (var relay in it) {
        relay.checkAndCompleteSubscription(id);
      }

      it = _tempRelays.values;
      for (var relay in it) {
        relay.checkAndCompleteSubscription(id);
      }

      it = _cacheRelays.values;
      for (var relay in it) {
        relay.checkAndCompleteSubscription(id);
      }
    } else {
      // check query and send close
      var it = _relays.values;
      for (var relay in it) {
        relay.checkAndCompleteQuery(id);
      }

      it = _tempRelays.values;
      for (var relay in it) {
        relay.checkAndCompleteQuery(id);
      }

      it = _cacheRelays.values;
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

  void handleAddrList(List<String>? addrList) {
    if (addrList != null) {
      var length = addrList.length;
      for (var i = 0; i < length; i++) {
        var relayAddr = addrList[i];
        addrList[i] = RelayAddrUtil.handle(relayAddr);
      }
    }
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
    List<String>? targetRelays,
    List<int> relayTypes = RelayType.ALL,
    bool sendAfterAuth =
        false, // if relay not connected, it will send after auth
  }) {
    if (filters.isEmpty) {
      throw ArgumentError("No filters given", "filters");
    }

    handleAddrList(tempRelays);
    handleAddrList(targetRelays);

    Subscription subscription = Subscription(filters, onEvent, id);
    if (onComplete != null) {
      _queryCompleteCallbacks[subscription.id] = onComplete;
    }

    // tempRelay, only query those relay which has bean provide
    if (tempRelays != null &&
        tempRelays.isNotEmpty &&
        relayTypes.contains(RelayType.TEMP)) {
      for (var tempRelayAddr in tempRelays) {
        // check if normal relays has this temp relay, try to get relay from normal relays
        Relay? relay = _relays[tempRelayAddr];
        relay ??= checkAndGenTempRelay(tempRelayAddr);

        relayDoQuery(relay, subscription, sendAfterAuth,
            runBeforeConnected: true);
      }
    }

    // normal relay, usually will query all the normal relays, but if targetRelays has provide, it only query from the provided querys.
    if (relayTypes.contains(RelayType.NORMAL)) {
      for (var entry in _relays.entries) {
        var relayAddr = entry.key;
        var relay = entry.value;

        if (targetRelays != null) {
          if (!targetRelays.contains(relayAddr)) {
            continue;
          }
        }

        relayDoQuery(relay, subscription, sendAfterAuth);
      }
    }

    // cache relay
    if (relayTypes.contains(RelayType.CACHE)) {
      for (var relay in _cacheRelays.values) {
        relayDoQuery(relay, subscription, sendAfterAuth);
      }
    }

    // local relay
    if (relayTypes.contains(RelayType.LOCAL) && relayLocal != null) {
      relayDoQuery(relayLocal!, subscription, sendAfterAuth);
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
        // Check if relay requires authentication
        if (relay.relayStatus.alwaysAuth && !relay.relayStatus.authed) {
          print('🔐 Relay ${relay.url} requires auth (alwaysAuth=${relay.relayStatus.alwaysAuth}, authed=${relay.relayStatus.authed})');
          
          // For vine.hol.is, we need to send one message to trigger AUTH challenge
          // Many relays only send AUTH challenges when they receive a message that needs auth
          if (relay.url.contains('vine.hol.is')) {
            print('🔐 vine.hol.is detected - sending message to trigger AUTH challenge');
            var result = relay.send(message, forceSend: true);
            if (result) {
              hadSubmitSend = true;
            }
            // Don't queue this message since we're sending it
          } else {
            print('🔐 Queueing message for authentication: ${message[0]}');
            relay.pendingAuthedMessages.add(message);
            hadSubmitSend = true;
          }
          print('🔐 Pending authed messages count: ${relay.pendingAuthedMessages.length}');
        } else {
          print('🔐 Relay ${relay.url} sending immediately (alwaysAuth=${relay.relayStatus.alwaysAuth}, authed=${relay.relayStatus.authed})');
          var result = relay.send(message);
          if (result) {
            hadSubmitSend = true;
          }
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
      extralRelay = RelayAddrUtil.handle(extralRelay);

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

  /// Configure a relay to always require authentication
  void setRelayAlwaysAuth(String relayUrl, bool alwaysAuth) {
    var relay = _relays[relayUrl];
    if (relay != null) {
      relay.relayStatus.alwaysAuth = alwaysAuth;
    }
  }

  /// Configure multiple relays with authentication requirements
  void configureRelayAuth(Map<String, bool> relayAuthConfig) {
    relayAuthConfig.forEach((url, alwaysAuth) {
      setRelayAlwaysAuth(url, alwaysAuth);
    });
  }

  /// Get current authentication configuration for all relays
  Map<String, bool> getRelayAuthConfig() {
    Map<String, bool> config = {};
    _relays.forEach((url, relay) {
      config[url] = relay.relayStatus.alwaysAuth;
    });
    return config;
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
