import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/network/app_exception.dart';
import '../../data/home_tabs_repository.dart';
import '../../data/lists_repository.dart';
import '../../domain/home_tab_entry.dart';
import 'home_tabs_state.dart';

/// The pinned Home tabs for the tab bar and "Manage pinned" (W5-14) over
/// [HomeTabsRepository] (the only SetHomeTabs caller).
///
/// - Mirrors the repository's `changes` (0 RPCs); the selected tab is kept by
///   key, so a reorder never changes what is shown, and an unpinned or hidden
///   selected tab falls back to Following.
/// - A list tab with no known name (another user's list on a new device) costs
///   one `GetList`, once per list per cubit; the name then arrives through the
///   repository's own header feed. A failed call leaves the neutral label.
/// - [pin] / [unpin] / [reorder] return the failure (or null) like
///   `ListDetailCubit.togglePin`; the repository has already rolled back.
class HomeTabsCubit extends Cubit<HomeTabsState> {
  HomeTabsCubit({
    required HomeTabsRepository tabs,
    required ListsRepository lists,
  }) : _tabs = tabs,
       _lists = lists,
       super(const HomeTabsState()) {
    _sub = _tabs.changes.listen((_) => _sync());
    _sync();
  }

  final HomeTabsRepository _tabs;
  final ListsRepository _lists;
  late final StreamSubscription<List<HomeTabEntry>> _sub;
  final Set<String> _asked = {};

  void _sync() {
    if (isClosed) return;
    final tabs = _tabs.tabs;
    final labels = {
      for (final t in tabs)
        t.key: _tabs.needsLabel(t) ? kUnnamedListTabLabel : _tabs.labelFor(t),
    };
    var selected = state.selectedKey;
    if (selected != kFollowingTabKey && !tabs.any((t) => t.key == selected)) {
      selected = kFollowingTabKey;
    }
    emit(
      state.copyWith(
        tabs: tabs,
        labels: labels,
        selectedKey: selected,
        saving: _tabs.saving,
        writeUnavailable: _tabs.writeUnavailable,
        isFull: _tabs.isFull,
      ),
    );
    for (final t in tabs) {
      if (_tabs.needsLabel(t) && _asked.add(t.key)) unawaited(_askLabel(t));
    }
  }

  Future<void> _askLabel(HomeTabEntry tab) async {
    try {
      await _lists.getList(tab.id);
    } on AppException {
      // The neutral label stays; the tab itself shows the real state.
    }
  }

  /// Shows [key] ([kFollowingTabKey] or a pinned tab's key).
  void select(String key) {
    if (key == state.selectedKey) return;
    if (key != kFollowingTabKey && !state.tabs.any((t) => t.key == key)) return;
    emit(state.copyWith(selectedKey: key));
  }

  Future<AppException?> pin(HomeTabKind kind, String id, String title) =>
      _run(() => _tabs.pin(kind, id, title: title));

  Future<AppException?> unpin(HomeTabEntry tab) =>
      _run(() => _tabs.unpin(tab.kind, tab.id));

  Future<AppException?> reorder(int oldIndex, int newIndex) =>
      _run(() => _tabs.reorder(oldIndex, newIndex));

  Future<AppException?> _run(Future<void> Function() action) async {
    final done = action();
    // The repository applied the change at once: show it, and "saving".
    _sync();
    try {
      await done;
      return null;
    } on AppException catch (error) {
      return error;
    } finally {
      _sync();
    }
  }

  @override
  Future<void> close() {
    unawaited(_sub.cancel());
    return super.close();
  }
}
