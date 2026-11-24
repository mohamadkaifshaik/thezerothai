import 'package:flutter/foundation.dart';

/// Block intents whose decline has committed in this account session.
class PendingBeaconBlocks extends ChangeNotifier {
  final _entries = <(String, String), ({String handle, String key})>{};
  bool _active = true;
  bool get active => _active;

  Map<String, String> handles(String beacon) => {
    for (final entry in _entries.entries)
      if (entry.key.$1 == beacon) entry.key.$2: entry.value.handle,
  };

  String? keyFor(String beacon, String user) => _entries[(beacon, user)]?.key;

  void record(String beacon, String user, String handle, String key) {
    if (!active) return;
    _entries.putIfAbsent((beacon, user), () => (handle: handle, key: key));
    notifyListeners();
  }

  void complete(String beacon, String user, String key) {
    if (!active || keyFor(beacon, user) != key) return;
    _entries.remove((beacon, user));
    notifyListeners();
  }

  @override
  void dispose() {
    _active = false;
    _entries.clear();
    super.dispose();
  }
}
