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

  Map<String, Relay> _allRelays = {};

  // key - value : relayType - relayAddrs
  Map<int, List<String>> _relayTypesMap = {};

  // subscription
  final Map<String, Subscription> _subscriptions = {};

  // init query
  final Map<String, Subscription> _initQuery = {};

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
    var relayAddr = relay.url;
    var relayAddrs = _relayTypesMap[relayType] ?? [];
    relayAddrs.add(relayAddr);
    _relayTypesMap[relayType] = relayAddrs;
    _allRelays[relayAddr] = relay;

    relay.onMessage = _onEvent;
    if (relay is RelayLocal) {
      relayLocal = relay;
    }

    if (await relay.connect()) {
      if (autoSubscribe) {
        for (Subscription subscription in _subscriptions.values) {
          if (subscription.isSubscription) {
            relay.send(subscription.toJson());
          }
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

  List<Relay> normalRelays() {
    List<Relay> list = [];
    var relayAddrList = _relayTypesMap[RelayType.NORMAL] ?? [];
    for (var relayAddr in relayAddrList) {
      var relay = _allRelays[relayAddr];
      if (relay != null) {
        list.add(relay);
      }
    }
    return list;
  }

  // List<Relay> activeRelays() {
  //   List<Relay> list = [];
  //   var it = _relays.values;
  //   for (var relay in it) {
  //     if (relay.relayStatus.connected == ClientConneccted.CONNECTED) {
  //       list.add(relay);
  //     }
  //   }
  //   return list;
  // }

  void removeAll() {
    var allRelays = _allRelays.values;
    for (var relay in allRelays) {
      relay.disconnect();
      relay.dispose();
    }

    _allRelays.clear();
    _subscriptions.clear();
    _initQuery.clear();
  }

  void remove(String url) {
    log('Removing $url');
    var relay = _allRelays.remove(url);
    if (relay != null) {
      relay.disconnect();
      relay.dispose();

      for (var relayAddrs in _relayTypesMap.values) {
        relayAddrs.remove(url);
      }
    }
  }

  Relay? getRelay(String url) {
    return _allRelays[url];
  }

  bool relayDoQuery(
      Relay relay, Subscription subscription, bool sendAfterAuth) {
    if (!relay.relayStatus.readAccess) {
      return false;
    }

    subscription.addQueryingRelay(relay.url);
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

  void _broadcaseToCache(Map<String, dynamic> event) {
    if (relayLocal != null) {
      relayLocal!.broadcaseToLocal(event);
    }

    var relayAddrs = _relayTypesMap[RelayType.CACHE];
    if (relayAddrs != null) {
      for (var relayAddr in relayAddrs) {
        var relay = _allRelays[relayAddr];
        if (relay != null &&
            relay.relayStatus.connected == ClientConneccted.CONNECTED) {
          relay.send(["EVENT", event]);
        }
      }
    }
  }

  Future<void> _onEvent(Relay relay, List<dynamic> json) async {
    final messageType = json[0];
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
      var subscription = _subscriptions[subId];
      if (subscription != null && !subscription.isSubscription) {
        // subscription needn't handle EOSE.
        // This is a query, close when eose received
        relay.send(["CLOSE", subId]);

        if (subscription.onEOSE != null) {
          subscription.onEOSE!(relay.url);
        }

        subscription.relayCompleteQuery(relay.url);
        if (subscription.isCompleted()) {
          // all query completed, remove subscription
          _subscriptions.remove(subId);
          // all query completed, call onComplete
          if (subscription.onComplete != null) {
            subscription.onComplete!();
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

    final Subscription subscription =
        Subscription(filters, onEvent, id: id, onComplete: onComplete);
    _initQuery[subscription.id] = subscription;
    _subscriptions[subscription.id] = subscription;
  }

  /// subscribe shoud be a long time filter search.
  /// like: subscribe the newest event、notice.
  /// subscribe info will hold in reply pool and close in reply pool.
  /// subscribe can be subscribe when new relay put into pool.
  String subscribe(
    List<Map<String, dynamic>> filters,
    Function(Event) onEvent, {
    String? id,
    // List<String>? tempRelays,
    List<String>? targetRelays,
    List<int> relayTypes = RelayType.NORMAL_AND_CACHE,
    bool sendAfterAuth =
        false, // if relay not connected, it will send after auth
    bool bothRelay = false,
  }) {
    if (filters.isEmpty) {
      throw ArgumentError("No filters given", "filters");
    }

    handleAddrList(targetRelays);

    final Subscription subscription = Subscription(filters, onEvent, id: id);
    subscription.isSubscription = true;
    _subscriptions[subscription.id] = subscription;
    // send(subscription.toJson());

    var currentRelays = findRelays(targetRelays, relayTypes, both: bothRelay);
    for (var relay in currentRelays) {
      relayDoSubscribe(relay, subscription, sendAfterAuth);
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
      subscription.addQueryingRelay(relay.url);

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

  // bool tempRelayHasSubscription(String relayAddr) {
  //   var relay = _tempRelays[relayAddr];
  //   if (relay != null) {
  //     return relay.hasSubscription();
  //   }

  //   return false;
  // }

  void unsubscribe(String id) {
    final subscription = _subscriptions.remove(id);
    if (subscription != null && subscription.queryingRelays.isNotEmpty) {
      for (var relayAddr in subscription.queryingRelays) {
        var relay = _allRelays[relayAddr];
        if (relay != null) {
          relay.removeSubscription(id);
          relay.send(["CLOSE", id]);
        }
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

    if (filtersMap.isEmpty) {
      return id;
    }

    var filters = filtersMap.entries.first.value;
    Subscription subscription =
        Subscription(filters, onEvent, id: id, onComplete: onComplete);
    _subscriptions[subscription.id] = subscription;

    var entries = filtersMap.entries;
    for (var entry in entries) {
      var url = entry.key;
      var filters = entry.value;

      var relay = _allRelays[url];
      if (relay != null) {
        subscription.filters = filters;
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

  List<Relay> findRelays(List<String>? targetRelays, List<int>? relayTypes,
      {bool both = false}) {
    List<String> findedAddrList = [];

    if (((targetRelays == null || targetRelays.isEmpty) || both == true) &&
        (relayTypes != null && relayTypes.isNotEmpty)) {
      for (var relayType in relayTypes) {
        if (relayType != RelayType.TEMP) {
          var relayAddrList = _relayTypesMap[relayType];
          if (relayAddrList != null && relayAddrList.isNotEmpty) {
            for (var relayAddr in relayAddrList) {
              if (!findedAddrList.contains(relayAddr)) {
                findedAddrList.add(relayAddr);
              }
            }
          }
        }
      }
    }
    if (targetRelays != null && targetRelays.isNotEmpty) {
      for (var relayAddr in targetRelays) {
        if (!findedAddrList.contains(relayAddr)) {
          findedAddrList.add(relayAddr);
        }
      }
    }

    List<Relay> relays = [];
    for (var relayAddr in findedAddrList) {
      relays.add(checkOrGenTempRelay(relayAddr));
    }

    return relays;
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
    Function? onComplete, // all relay EOSE call this method
    Function(String)? onEOSE, // every relay EOSE call this method
    List<String>? targetRelays,
    List<int> relayTypes = RelayType.NORMAL_AND_CACHE,
    bool sendAfterAuth =
        false, // if relay not connected, it will send after auth
    bool bothRelay = false,
  }) {
    if (filters.isEmpty) {
      throw ArgumentError("No filters given", "filters");
    }

    handleAddrList(targetRelays);

    Subscription subscription = Subscription(filters, onEvent,
        id: id, onComplete: onComplete, onEOSE: onEOSE);
    _subscriptions[subscription.id] = subscription;

    var currentRelays = findRelays(targetRelays, relayTypes, both: bothRelay);
    for (var relay in currentRelays) {
      relayDoQuery(relay, subscription, sendAfterAuth);
    }

    return subscription.id;
  }

  /// send message to relay
  /// there are tempRelays, it also send to tempRelays too.
  bool send(
    List<dynamic> message, {
    List<String>? targetRelays,
    List<int> relayTypes = RelayType.NORMAL_AND_CACHE,
    bool bothRelay = false,
  }) {
    handleAddrList(targetRelays);

    int submitedNum = 0;

    var currentRelays =
        findRelays(targetRelays, RelayType.NORMAL_AND_CACHE, both: true);
    for (var relay in currentRelays) {
      if (relay.relayStatus.connected == ClientConneccted.CONNECTED) {
        relay.send(message);
        submitedNum++;
      } else {
        relay.pendingMessages.add(message);
        submitedNum++;
      }
    }

    return submitedNum > 0;
  }

  void reconnect() {
    for (var relay in _allRelays.values) {
      relay.connect();
    }
  }

  // check if there is a relay exist or gen a temp relay.
  Relay checkOrGenTempRelay(String addr) {
    var relay = _allRelays[addr];
    if (relay == null) {
      print("tempRelay gened $addr");
      relay = tempRelayGener(addr);
      relay.onMessage = _onEvent;
      relay.connect();
      _allRelays[addr] = relay;

      _relayTypesMap[RelayType.TEMP] = _relayTypesMap[RelayType.TEMP] ?? [];
      _relayTypesMap[RelayType.TEMP]!.add(addr);
    }

    return relay;
  }

  List<String> getExtralReadableRelays(
      List<String> extralRelays, int maxExtralNum) {
    List<String> list = [];

    int extralNum = 0;
    for (var extralRelay in extralRelays) {
      try {
        extralRelay = RelayAddrUtil.handle(extralRelay);
      } catch (e) {
        print("handle relay addr error $e $extralRelay");
        continue;
      }

      var relay = _allRelays[extralRelay];
      list.add(extralRelay);
      if (relay != null && relay.relayStatus.readAccess) {
        // current pool contain this relay, direct use it.
      } else {
        // current pool not contain this relay, add it to list start to connect and add to pool.
        extralNum++;
      }

      if (extralNum >= maxExtralNum) {
        break;
      }
    }

    return list;
  }

  bool readable() {
    for (var relay in _allRelays.values) {
      if (relay.relayStatus.connected == ClientConneccted.CONNECTED &&
          relay.relayStatus.readAccess) {
        return true;
      }
    }

    return false;
  }

  bool writable() {
    for (var relay in _allRelays.values) {
      if (relay.relayStatus.connected == ClientConneccted.CONNECTED &&
          relay.relayStatus.writeAccess) {
        return true;
      }
    }

    return false;
  }
}
