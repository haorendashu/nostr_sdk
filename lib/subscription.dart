import 'utils/string_util.dart';

/// Representation of a Nostr event subscription.
class Subscription {
  final String _id;
  List<Map<String, dynamic>> filters;
  Function onEvent;

  /// Subscription ID
  String get id => _id;

  Subscription(
    this.filters,
    this.onEvent, {
    String? id,
    this.onComplete,
    this.onEOSE,
  }) : _id = id ?? StringUtil.rndNameStr(16);

  /// Returns the subscription as a Nostr subscription request in JSON format
  List<dynamic> toJson() {
    List<dynamic> json = ["REQ", _id];

    for (Map<String, dynamic> filter in filters) {
      json.add(filter);
    }

    return json;
  }

  bool isSubscription = false;

  Function? onComplete;

  Function(String)? onEOSE;

  final List<String> queryingRelays = [];

  void addQueryingRelay(String relayAddr) {
    if (!queryingRelays.contains(relayAddr)) {
      queryingRelays.add(relayAddr);
    }
  }

  void relayCompleteQuery(String relayAddr) {
    queryingRelays.remove(relayAddr);
  }

  bool isCompleted() {
    return queryingRelays.isEmpty;
  }
}
