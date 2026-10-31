import 'package:flutter/foundation.dart';

import '../../domain/home_tab_entry.dart';

/// The key of the fixed first Home tab (never stored, never a [HomeTabEntry]).
const kFollowingTabKey = 'following';

/// The text of a pinned tab whose list has no known name yet.
const kUnnamedListTabLabel = 'List';

/// What the Home tab bar and "Manage pinned" show (W5-14).
@immutable
class HomeTabsState {
  const HomeTabsState({
    this.tabs = const [],
    this.labels = const {},
    this.selectedKey = kFollowingTabKey,
    this.saving = false,
    this.writeUnavailable = false,
    this.isFull = false,
  });

  /// The pinned tabs after Following, in order (`lists` off = none).
  final List<HomeTabEntry> tabs;

  /// [HomeTabEntry.key] to the label to show (never empty).
  final Map<String, String> labels;

  /// [kFollowingTabKey] or a [HomeTabEntry.key]; always one that exists.
  final String selectedKey;

  /// A SetHomeTabs is in flight.
  final bool saving;

  /// SetHomeTabs is not deployed yet: pin/reorder are not offered.
  final bool writeUnavailable;

  /// Five tabs are pinned already.
  final bool isFull;

  /// 0 = Following, then 1.. for [tabs].
  int get selectedIndex {
    final i = tabs.indexWhere((t) => t.key == selectedKey);
    return i < 0 ? 0 : i + 1;
  }

  String labelOf(HomeTabEntry tab) => labels[tab.key] ?? kUnnamedListTabLabel;

  HomeTabsState copyWith({
    List<HomeTabEntry>? tabs,
    Map<String, String>? labels,
    String? selectedKey,
    bool? saving,
    bool? writeUnavailable,
    bool? isFull,
  }) => HomeTabsState(
    tabs: tabs ?? this.tabs,
    labels: labels ?? this.labels,
    selectedKey: selectedKey ?? this.selectedKey,
    saving: saving ?? this.saving,
    writeUnavailable: writeUnavailable ?? this.writeUnavailable,
    isFull: isFull ?? this.isFull,
  );

  @override
  bool operator ==(Object other) =>
      other is HomeTabsState &&
      listEquals(other.tabs, tabs) &&
      mapEquals(other.labels, labels) &&
      other.selectedKey == selectedKey &&
      other.saving == saving &&
      other.writeUnavailable == writeUnavailable &&
      other.isFull == isFull;

  @override
  int get hashCode => Object.hash(
    Object.hashAll(tabs),
    Object.hashAll(labels.entries.map((e) => Object.hash(e.key, e.value))),
    selectedKey,
    saving,
    writeUnavailable,
    isFull,
  );
}
