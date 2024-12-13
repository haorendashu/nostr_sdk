class GroupIdentifier {

  // This field in here is wss://domain not like NIP29 domain
  String host;

  String groupId;

  GroupIdentifier(this.host, this.groupId);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is GroupIdentifier && other.host == host && other.groupId == groupId;
  }

  @override
  int get hashCode => host.hashCode ^ groupId.hashCode;

  static GroupIdentifier? parse(String idStr) {
    var strs = idStr.split("'");
    if (strs.isNotEmpty && strs.length > 1) {
      return GroupIdentifier(strs[0], strs[1]);
    }

    return null;
  }

  @override
  String toString() {
    return "$host'$groupId";
  }

  List<dynamic> toJson() {
    List<dynamic> list = [];
    list.add("group");
    list.add(groupId);
    list.add(host);
    return list;
  }
}
