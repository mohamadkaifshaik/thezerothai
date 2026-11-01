import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../lists/data/home_tabs_repository.dart';
import '../../../lists/domain/home_tab_entry.dart';
import '../../data/communities_repository.dart';
import '../../domain/community_role.dart';
import 'community_detail_state.dart';

/// Header, About data and Join / Leave / Pin state of one community page
/// (W5-32).
///
/// - **Open.** One `GetCommunity` per [load] (header, rules, owner,
///   moderators). Nothing else here makes an RPC until the user acts.
/// - **Join / Leave.** Optimistic; the answer's `Community` replaces the
///   header (the client reads `viewer_role` from it and derives nothing). A
///   failure rolls back and is returned for the screen's snackbar; a `banned`
///   refusal also flips the control to the banned text. One idempotency key
///   per action, reused when that action is retried (rule 4).
/// - **Pin.** [HomeTabsRepository] (optimistic, one `SetHomeTabs`, rollback on
///   error); the state follows its `changes`.
class CommunityDetailCubit extends Cubit<CommunityDetailState> {
  CommunityDetailCubit({
    required this.communityId,
    required CommunitiesRepository communities,
    required HomeTabsRepository tabs,
  }) : _communities = communities,
       _tabs = tabs,
       super(const CommunityDetailState()) {
    emit(_pins(state));
    _tabsSub = tabs.changes.listen((_) {
      if (!isClosed) emit(_pins(state));
    });
  }

  static const _uuid = Uuid();

  final String communityId;
  final CommunitiesRepository _communities;
  final HomeTabsRepository _tabs;
  late final StreamSubscription<List<HomeTabEntry>> _tabsSub;
  String? _joinKey;
  String? _leaveKey;
  int _generation = 0;

  CommunityDetailState _pins(CommunityDetailState s) => s.copyWith(
    pinned: _tabs.isPinned(HomeTabKind.community, communityId),
    pinFull: _tabs.isFull,
    pinWriteUnavailable: _tabs.writeUnavailable,
  );

  Future<void> load() async {
    final generation = ++_generation;
    if (state.community == null) {
      emit(
        state.copyWith(status: CommunityDetailStatus.loading, clearError: true),
      );
    }
    try {
      final r = await _communities.getCommunity(communityId);
      if (isClosed || generation != _generation) return;
      emit(
        state.copyWith(
          status: CommunityDetailStatus.ready,
          community: r.community,
          rules: r.rules.toList(),
          owner: r.owner,
          moderators: r.moderators.toList(),
          clearError: true,
        ),
      );
    } on NotFoundException {
      if (isClosed || generation != _generation) return;
      emit(state.copyWith(status: CommunityDetailStatus.unavailable));
    } on AppException catch (error) {
      if (isClosed || generation != _generation) return;
      // A refresh that fails keeps the header it has.
      if (state.community != null) return;
      emit(state.copyWith(status: CommunityDetailStatus.error, error: error));
    }
  }

  /// The timeline said NOT_FOUND: show "unavailable" (one text for every cause).
  void markUnavailable() {
    if (isClosed || state.status == CommunityDetailStatus.unavailable) return;
    emit(state.copyWith(status: CommunityDetailStatus.unavailable));
  }

  /// Joins the community. Returns the failure (rolled back) or null.
  Future<AppException?> join() async {
    final before = state.community;
    if (before == null || state.joinBusy || before.role.isMember) return null;
    final key = _joinKey ??= _uuid.v4();
    emit(
      state.copyWith(
        joinBusy: true,
        joinedOptimistically: true,
        bannedByRefusal: false,
      ),
    );
    try {
      final joined = await _communities.joinCommunity(
        idempotencyKey: key,
        communityId: communityId,
      );
      _joinKey = null;
      if (isClosed) return null;
      emit(
        state.copyWith(
          community: joined,
          joinBusy: false,
          joinedOptimistically: false,
        ),
      );
      return null;
    } on AppException catch (error) {
      if (isClosed) return error;
      emit(
        state.copyWith(
          joinBusy: false,
          joinedOptimistically: false,
          bannedByRefusal:
              error is CommunityForbiddenException &&
              error.reason == CommunityForbiddenReason.banned,
        ),
      );
      return error;
    }
  }

  /// Leaves the community (a member who is not the owner). Returns the
  /// failure (rolled back) or null.
  Future<AppException?> leave() async {
    final before = state.community;
    if (before == null ||
        state.joinBusy ||
        !before.role.isMember ||
        before.role.isOwner) {
      return null;
    }
    final key = _leaveKey ??= _uuid.v4();
    emit(state.copyWith(joinBusy: true, leftOptimistically: true));
    try {
      final left = await _communities.leaveCommunity(
        idempotencyKey: key,
        communityId: communityId,
      );
      _leaveKey = null;
      if (isClosed) return null;
      emit(
        state.copyWith(
          community: left,
          joinBusy: false,
          leftOptimistically: false,
        ),
      );
      return null;
    } on AppException catch (error) {
      if (isClosed) return error;
      emit(state.copyWith(joinBusy: false, leftOptimistically: false));
      return error;
    }
  }

  /// Pins the community to Home, or unpins it. Returns the failure (already
  /// rolled back by the repository) for the screen's snackbar, or null.
  Future<AppException?> togglePin() async {
    if (state.pinBusy) return null;
    emit(state.copyWith(pinBusy: true));
    try {
      if (_tabs.isPinned(HomeTabKind.community, communityId)) {
        await _tabs.unpin(HomeTabKind.community, communityId);
      } else {
        await _tabs.pin(
          HomeTabKind.community,
          communityId,
          title: state.community?.name ?? '',
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
    await _tabsSub.cancel();
    return super.close();
  }
}
