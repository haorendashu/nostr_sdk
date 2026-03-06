import 'package:nostr_sdk/event_mem_box.dart';

import 'event.dart';
import 'relay/relay.dart';

class EventBoxList extends EventMemBox {
  List<EventMemBox> _eventBoxList = [];

  EventBoxList() : super();

  void addEventBoxToFirst(EventMemBox box) {
    _eventBoxList.insert(0, box);
  }

  void addEventBox(EventMemBox box) {
    _eventBoxList.add(box);
  }

  void removeEventBox(EventMemBox box) {
    _eventBoxList.remove(box);
  }

  @override
  List<Event> findEvent(String str, {int? limit = 5}) {
    List<Event> list = [];
    for (var box in _eventBoxList) {
      var events =
          box.findEvent(str, limit: limit != null ? limit - list.length : null);
      list.addAll(events);

      if (limit != null && list.length >= limit) {
        return list.sublist(0, limit);
      }
    }
    return list;
  }

  @override
  Event? get newestEvent {
    Event? newest;
    for (var box in _eventBoxList) {
      var event = box.newestEvent;
      if (event != null) {
        if (newest == null || event.createdAt > newest.createdAt) {
          newest = event;
        }
      }
    }
    return newest;
  }

  @override
  Event? get oldestEvent {
    Event? oldest;
    for (var box in _eventBoxList) {
      var event = box.oldestEvent;
      if (event != null) {
        if (oldest == null || event.createdAt < oldest.createdAt) {
          oldest = event;
        }
      }
    }
    return oldest;
  }

  @override
  OldestCreatedAtByRelayResult oldestCreatedAtByRelay(List<Relay> relays,
      [int? initTime]) {
    OldestCreatedAtByRelayResult result = OldestCreatedAtByRelayResult();
    Map<String, int> allCreatedAtMap = {};

    for (var box in _eventBoxList) {
      var boxResult = box.oldestCreatedAtByRelay(relays, initTime);
      for (var entry in boxResult.createdAtMap.entries) {
        if (!allCreatedAtMap.containsKey(entry.key) ||
            entry.value < allCreatedAtMap[entry.key]!) {
          allCreatedAtMap[entry.key] = entry.value;
        }
      }
    }

    result.createdAtMap = allCreatedAtMap;

    // count av createdAt
    var it = result.createdAtMap.values;
    var relayNum = it.length;
    double counter = 0;
    for (var value in it) {
      counter += value;
    }
    if (relayNum > 1) {
      result.avCreatedAt = counter ~/ relayNum;
    } else {
      result.avCreatedAt = counter.toInt();
    }

    return result;
  }

  @override
  void sort() {
    for (var box in _eventBoxList) {
      box.sort();
    }
  }

  @override
  bool delete(String id) {
    bool deleted = false;
    for (var box in _eventBoxList) {
      if (box.delete(id)) {
        deleted = true;
      }
    }
    return deleted;
  }

  @override
  bool add(Event event) {
    // 先检查是否已存在
    var oldEvent = getById(event.id);
    if (oldEvent != null) {
      // 事件已存在，处理 sources
      if (!event.cacheEvent && event.sources.isNotEmpty) {
        if (oldEvent.cacheEvent) {
          oldEvent.sources.clear();
          oldEvent.cacheEvent = false;
        }
        if (!oldEvent.sources.contains(event.sources[0])) {
          oldEvent.sources.add(event.sources[0]);
        }
      }
      return false;
    }

    // 添加到第一个 box，如果没有 box 则创建一个
    if (_eventBoxList.isEmpty) {
      _eventBoxList.add(EventMemBox(sortAfterAdd: sortAfterAdd));
    }
    return _eventBoxList.first.add(event);
  }

  @override
  bool addList(List<Event> list) {
    if (_eventBoxList.isEmpty) {
      _eventBoxList.add(EventMemBox(sortAfterAdd: sortAfterAdd));
    }

    bool added = false;
    for (var event in list) {
      var oldEvent = getById(event.id);
      if (oldEvent != null) {
        // 事件已存在，处理 sources
        if (event.sources.isNotEmpty &&
            !oldEvent.sources.contains(event.sources[0])) {
          oldEvent.sources.add(event.sources[0]);
        }
      } else {
        // 事件不存在，添加到第一个 box
        if (_eventBoxList.first.add(event)) {
          added = true;
        }
      }
    }

    return added;
  }

  @override
  void addBox(EventMemBox b) {
    _eventBoxList.add(b);
  }

  @override
  bool isEmpty() {
    for (var box in _eventBoxList) {
      if (!box.isEmpty()) {
        return false;
      }
    }
    return true;
  }

  @override
  int length() {
    int total = 0;
    for (var box in _eventBoxList) {
      total += box.length();
    }
    return total;
  }

  @override
  List<Event> all() {
    List<Event> allEvents = [];
    for (var box in _eventBoxList) {
      allEvents.addAll(box.all());
    }
    return allEvents;
  }

  @override
  List<Event> listByPubkey(String pubkey) {
    List<Event> list = [];
    for (var box in _eventBoxList) {
      list.addAll(box.listByPubkey(pubkey));
    }
    return list;
  }

  @override
  List<Event> suList(int start, int limit) {
    var allEvents = all();
    var length = allEvents.length;
    if (start > length) {
      return [];
    }
    if (start + limit > length) {
      return allEvents.sublist(start, length);
    }
    return allEvents.sublist(start, start + limit);
  }

  @override
  Event? get(int index) {
    int currentIndex = 0;
    for (var box in _eventBoxList) {
      var boxLength = box.length();
      if (currentIndex + boxLength > index) {
        return box.get(index - currentIndex);
      }
      currentIndex += boxLength;
    }
    return null;
  }

  @override
  Event? getById(String id) {
    for (var box in _eventBoxList) {
      var event = box.getById(id);
      if (event != null) {
        return event;
      }
    }
    return null;
  }

  /// Merge all EventMemBox into one and clear others
  void merge() {
    if (_eventBoxList.isEmpty) {
      return;
    }

    if (_eventBoxList.length == 1) {
      // Already merged, nothing to do
      return;
    }

    // Create a new merged box
    EventMemBox mergedBox = EventMemBox(sortAfterAdd: sortAfterAdd);

    // Add all events from all boxes to the merged box
    for (var box in _eventBoxList) {
      mergedBox.addBox(box);
    }

    // Clear all boxes and replace with merged box
    _eventBoxList.clear();
    _eventBoxList.add(mergedBox);
  }

  @override
  void clear() {
    for (var box in _eventBoxList) {
      box.clear();
    }
    _eventBoxList.clear();
  }
}
