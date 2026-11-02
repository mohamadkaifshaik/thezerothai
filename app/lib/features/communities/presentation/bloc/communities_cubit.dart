import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import '../../data/communities_repository.dart';
import '../../domain/community_role.dart';
import 'communities_state.dart';

/// `/communities` (W5-31): the caller's communities and the directory, one
/// RPC each per [load] (ListMyCommunities, ListCommunities; nothing else on
/// open).
///
/// - **Independent.** Each list has its own status and error; one failing (or
///   not being served yet) never blanks the other.
/// - **Join.** Optimistic: the row reads "Joined" at once ([joining]); the
///   answer replaces the row with the server's `Community` (its `viewer_role`
///   and `member_count`; the client derives no role). On error the row goes
///   back, and a `banned` refusal makes it say so. One idempotency key per
///   community, reused when the same Join is retried (rule 4).
class CommunitiesCubit extends Cubit<CommunitiesState> {
  CommunitiesCubit({required CommunitiesRepository repository})
    : _repository = repository,
      super(const CommunitiesState());

  static const _uuid = Uuid();
  static const _pageSize = 50;

  final CommunitiesRepository _repository;
  final Map<String, String> _joinKeys = {};
  int _generation = 0;

  Future<void> load() {
    final generation = ++_generation;
    // A refresh keeps what is shown; only an empty list goes back to the
    // skeleton.
    emit(
      state.copyWith(
        mineStatus: state.mine.isEmpty ? CommunitiesLoad.loading : null,
        directoryStatus: state.directory.isEmpty
            ? CommunitiesLoad.loading
            : null,
        clearMineError: true,
        clearDirectoryError: true,
      ),
    );
    return Future.wait([_loadMine(generation), _loadDirectory(generation)]);
  }

  bool _stale(int generation) => isClosed || generation != _generation;

  Future<void> _loadMine(int generation) async {
    try {
      final r = await _repository.listMyCommunities(pageSize: _pageSize);
      if (_stale(generation)) return;
      emit(
        state.copyWith(
          mineStatus: CommunitiesLoad.ready,
          mine: r.communities,
          canCreate: r.canCreate,
        ),
      );
    } on AppException catch (error) {
      if (_stale(generation)) return;
      emit(
        state.copyWith(
          mineStatus: CommunitiesLoad.error,
          mine: const [],
          canCreate: false,
          mineError: error,
        ),
      );
    }
  }

  Future<void> _loadDirectory(int generation) async {
    try {
      final r = await _repository.listCommunities(pageSize: _pageSize);
      if (_stale(generation)) return;
      emit(
        state.copyWith(
          directoryStatus: CommunitiesLoad.ready,
          directory: r.communities,
        ),
      );
    } on AppException catch (error) {
      if (_stale(generation)) return;
      emit(
        state.copyWith(
          directoryStatus: CommunitiesLoad.error,
          directory: const [],
          directoryError: error,
        ),
      );
    }
  }

  /// Joins [community]. Returns the failure (already rolled back) for the
  /// screen's snackbar, or null.
  Future<AppException?> join(pb.Community community) async {
    final id = community.communityId;
    if (state.joining.contains(id) || community.role.isMember) return null;
    final key = _joinKeys.putIfAbsent(id, _uuid.v4);
    emit(
      state.copyWith(
        joining: {...state.joining, id},
        banned: {...state.banned}..remove(id),
      ),
    );
    try {
      final joined = await _repository.joinCommunity(
        idempotencyKey: key,
        communityId: id,
      );
      _joinKeys.remove(id);
      if (isClosed) return null;
      emit(
        state.copyWith(
          joining: {...state.joining}..remove(id),
          directory: [
            for (final c in state.directory) c.communityId == id ? joined : c,
          ],
          mine: state.mine.any((c) => c.communityId == id)
              ? [for (final c in state.mine) c.communityId == id ? joined : c]
              : [...state.mine, joined],
        ),
      );
      return null;
    } on AppException catch (error) {
      if (isClosed) return error;
      final banned =
          error is CommunityForbiddenException &&
          error.reason == CommunityForbiddenReason.banned;
      emit(
        state.copyWith(
          joining: {...state.joining}..remove(id),
          banned: banned ? {...state.banned, id} : null,
        ),
      );
      return error;
    }
  }
}
