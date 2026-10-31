import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/lists/v1/lists.pb.dart' as pb;
import '../../data/home_tabs_repository.dart';
import '../../data/lists_repository.dart';
import '../../domain/home_tab_entry.dart';
import 'list_detail_state.dart';

/// Header and Pin state of one List's detail screen (W5-12).
///
/// - The header is the latest `ListInfo` the client holds
///   ([ListsRepository.header], fed by the list timeline's answers, which
///   carry it). [ensureHeader] makes one `GetList` only when none is known
///   (offline cold start, or a timeline call that did not run).
/// - Pin / Unpin goes through [HomeTabsRepository] (optimistic, one
///   `SetHomeTabs`, rollback on error); the state follows its `changes`.
class ListDetailCubit extends Cubit<ListDetailState> {
  ListDetailCubit({
    required this.listId,
    required ListsRepository lists,
    required HomeTabsRepository tabs,
  }) : _lists = lists,
       _tabs = tabs,
       super(const ListDetailState()) {
    final header = lists.header(listId);
    emit(
      _pins(
        ListDetailState(
          status: header == null
              ? ListDetailStatus.loading
              : ListDetailStatus.ready,
          header: header,
        ),
      ),
    );
    _headerSub = lists.headerChanges
        .where((h) => h.listId == listId)
        .listen(_onHeader);
    _tabsSub = tabs.changes.listen((_) {
      if (!isClosed) emit(_pins(state));
    });
  }

  final String listId;
  final ListsRepository _lists;
  final HomeTabsRepository _tabs;
  late final StreamSubscription<pb.ListInfo> _headerSub;
  late final StreamSubscription<List<HomeTabEntry>> _tabsSub;

  ListDetailState _pins(ListDetailState s) => s.copyWith(
    pinned: _tabs.isPinned(HomeTabKind.list, listId),
    pinFull: _tabs.isFull,
    pinWriteUnavailable: _tabs.writeUnavailable,
  );

  void _onHeader(pb.ListInfo header) {
    if (isClosed || state.status == ListDetailStatus.unavailable) return;
    emit(
      state.copyWith(
        status: ListDetailStatus.ready,
        header: header,
        headerFailed: false,
      ),
    );
  }

  /// One `GetList` when no header is known yet.
  Future<void> ensureHeader() async {
    if (isClosed ||
        state.header != null ||
        state.status == ListDetailStatus.unavailable) {
      return;
    }
    try {
      // The repository notes the header and `headerChanges` delivers it.
      final header = await _lists.getList(listId);
      if (!isClosed && state.header == null) _onHeader(header);
    } on NotFoundException {
      markUnavailable();
    } on AppException {
      if (!isClosed) emit(state.copyWith(headerFailed: true));
    }
  }

  /// The timeline or `GetList` said NOT_FOUND.
  void markUnavailable() {
    if (isClosed || state.status == ListDetailStatus.unavailable) return;
    emit(state.copyWith(status: ListDetailStatus.unavailable));
  }

  /// Pins the List to Home, or unpins it. Returns the failure (already rolled
  /// back by the repository) for the screen's snackbar, or null.
  Future<AppException?> togglePin() async {
    if (state.pinBusy) return null;
    emit(state.copyWith(pinBusy: true));
    try {
      if (_tabs.isPinned(HomeTabKind.list, listId)) {
        await _tabs.unpin(HomeTabKind.list, listId);
      } else {
        await _tabs.pin(
          HomeTabKind.list,
          listId,
          title: state.header?.name ?? '',
        );
      }
      return null;
    } on AppException catch (e) {
      return e;
    } finally {
      if (!isClosed) emit(_pins(state).copyWith(pinBusy: false));
    }
  }

  @override
  Future<void> close() async {
    await _headerSub.cancel();
    await _tabsSub.cancel();
    return super.close();
  }
}
