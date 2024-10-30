import '../event_kind.dart';
import '../relay/client_connected.dart';
import '../relay/relay.dart';
import '../relay/relay_info.dart';
import 'relay_local_db.dart';
import 'relay_local_mixin.dart';

class RelayLocal extends Relay with RelayLocalMixin {
  static const URL = "Local Relay";

  RelayLocalDB relayLocalDB;

  RelayLocal(super.url, super.relayStatus, this.relayLocalDB) {
    super.relayStatus.connected = ClientConneccted.CONNECTED;

    info = RelayInfo(
        "Local Relay",
        "This is a local relay. It will cache some event.",
        "29320975df855fe34a7b45ada2421e2c741c37c0136901fe477133a91eb18b07",
        "29320975df855fe34a7b45ada2421e2c741c37c0136901fe477133a91eb18b07",
        ["1", "11", "12", "16", "33", "42", "45", "50", "95"],
        "Nostrmo",
        "0.1.0");
  }

  void broadcaseToLocal(Map<String, dynamic> event) {
    relayLocalDB.addEvent(event);
  }

  @override
  Future<void> disconnect() async {}

  @override
  Future<bool> doConnect() async {
    return true;
  }

  @override
  bool send(List message, {bool? forceSend}) {
    // all messages were resend by the local, so we didn't check sig here.

    if (message.isNotEmpty) {
      var action = message[0];
      if (action == "EVENT") {
        doEvent(null, message);
      } else if (action == "REQ") {
        doReq(null, message);
      } else if (action == "CLOSE") {
        // this relay only use to handle cache event, so it wouldn't push new event to client.
      } else if (action == "AUTH") {
        // don't handle the message
      } else if (action == "COUNT") {
        doCount(null, message);
      }
    }
    return true;
  }

  @override
  RelayLocalDB getRelayLocalDB() {
    return relayLocalDB;
  }

  @override
  void callback(String? connId, List list) {
    onMessage!(this, list);
  }
}
