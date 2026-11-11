import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../data/lists_repository.dart';

/// How many members the preview shows (one `ListListMembers` page).
const kListMembersPreviewLimit = 5;

enum ListMembersPreviewStatus {
  /// Not asked yet: the preview is only asked for where it shows.
  idle,

  /// The one `ListListMembers` is in flight.
  loading,

  /// [ListMembersPreviewState.users] is the first page (may be empty).
  ready,

  /// The call failed (offline, a rate limit): offer Retry.
  failed,

  /// FEATURE_DISABLED or NOT_FOUND: show nothing (the page says why).
  unavailable,
}

@immutable
class ListMembersPreviewState {
  const ListMembersPreviewState({
    this.status = ListMembersPreviewStatus.idle,
    this.users = const [],
  });

  final ListMembersPreviewStatus status;
  final List<graph.UserListItem> users;

  @override
  bool operator ==(Object other) =>
      other is ListMembersPreviewState &&
      other.status == status &&
      listEquals(other.users, users);

  @override
  int get hashCode => Object.hash(status, Object.hashAll(users));
}

/// The first few members of one List for band B's context pane on
/// `/lists/:id` (tablet plan section 4.1, ListDetail: "timeline | Members
/// preview + Manage"; T8b).
///
/// Nothing is asked until [loadOnce]: the list page calls it only while the
/// pane shows the preview, so phones, band A and desktop make no extra call.
/// Then one `ListListMembers` of [kListMembersPreviewLimit], following empty
/// pages as the members page does. [reload] asks again (the member count
/// changed); it does nothing before the first [loadOnce].
class ListMembersPreviewCubit extends Cubit<ListMembersPreviewState> {
  ListMembersPreviewCubit({
    required this.listId,
    required ListsRepository lists,
  }) : _lists = lists,
       super(const ListMembersPreviewState());

  final String listId;
  final ListsRepository _lists;

  /// Asks for the preview the first time; later calls do nothing.
  Future<void> loadOnce() async {
    if (state.status != ListMembersPreviewStatus.idle) return;
    await _load();
  }

  /// Asks again when the preview was asked for before (and is not in
  /// flight); the rows already shown stay until the answer.
  Future<void> reload() async {
    if (state.status == ListMembersPreviewStatus.idle ||
        state.status == ListMembersPreviewStatus.loading) {
      return;
    }
    await _load();
  }

  Future<void> _load() async {
    emit(
      ListMembersPreviewState(
        status: ListMembersPreviewStatus.loading,
        users: state.users,
      ),
    );
    try {
      final page = await _lists.listMembers(
        listId: listId,
        pageSize: kListMembersPreviewLimit,
        maxEmptyPages: 2,
      );
      if (isClosed) return;
      emit(
        ListMembersPreviewState(
          status: ListMembersPreviewStatus.ready,
          users: page.users.take(kListMembersPreviewLimit).toList(),
        ),
      );
    } on FeatureDisabledException {
      if (!isClosed) {
        emit(
          const ListMembersPreviewState(
            status: ListMembersPreviewStatus.unavailable,
          ),
        );
      }
    } on NotFoundException {
      if (!isClosed) {
        emit(
          const ListMembersPreviewState(
            status: ListMembersPreviewStatus.unavailable,
          ),
        );
      }
    } on AppException {
      if (!isClosed) {
        emit(
          ListMembersPreviewState(
            status: ListMembersPreviewStatus.failed,
            users: state.users,
          ),
        );
      }
    }
  }
}
