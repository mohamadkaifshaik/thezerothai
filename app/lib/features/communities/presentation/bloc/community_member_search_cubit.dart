import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import '../../domain/communities_feature_flag.dart';
import '../../domain/community_role.dart';
import '../../domain/community_search.dart';

/// One `SearchCommunityMembers` (F36): the members of one community whose
/// handle starts with [prefix], in the [filter]'s state.
typedef SearchCommunityMembers = Future<List<pb.CommunityMember>> Function({
  required String prefix,
  required pb.CommunityMemberFilter filter,
});

/// Which tab of the members page a search looks in.
enum MemberSearchScope {
  /// JOINED members.
  members,

  /// The owner and the moderators: a JOINED search (the server takes no
  /// MODERATORS filter for a search) keeping the rows whose role moderates.
  moderators,

  /// BANNED users (owner and moderators only).
  banned,
}

/// [idle] nothing to search (blank or one character): the page shows its
/// list. [invalid] the text can't start a handle: a hint, no call.
/// [loading], [ready] and [error] are one search's states.
enum MemberSearchStatus { idle, invalid, loading, ready, error }

@immutable
class MemberSearchState {
  const MemberSearchState({
    this.status = MemberSearchStatus.idle,
    this.results = const [],
    this.error,
    this.unavailable = false,
  });

  final MemberSearchStatus status;
  final List<pb.CommunityMember> results;
  final AppException? error;

  /// The server answered that `community_member_search` is off (or does not
  /// serve the RPC yet): the field goes away for this page.
  final bool unavailable;

  /// Whether the page shows the search instead of its list.
  bool get active => !unavailable && status != MemberSearchStatus.idle;

  MemberSearchState copyWith({
    MemberSearchStatus? status,
    List<pb.CommunityMember>? results,
    AppException? error,
    bool clearError = false,
    bool? unavailable,
  }) => MemberSearchState(
    status: status ?? this.status,
    results: results ?? this.results,
    error: clearError ? null : (error ?? this.error),
    unavailable: unavailable ?? this.unavailable,
  );
}

/// The members page's search field (F36): debounced ([debounce], 300 ms),
/// at least 2 characters of a handle, one call per settled prefix, the
/// latest answer wins. The active tab sets the [MemberSearchScope].
class CommunityMemberSearchCubit extends Cubit<MemberSearchState> {
  CommunityMemberSearchCubit({
    required SearchCommunityMembers search,
    this.debounce = kCommunityMemberSearchDebounce,
  }) : _search = search,
       super(const MemberSearchState());

  final SearchCommunityMembers _search;
  final Duration debounce;

  MemberSearchScope _scope = MemberSearchScope.members;
  String _raw = '';
  Timer? _timer;
  int _generation = 0;

  MemberSearchScope get scope => _scope;

  /// The field's text changed.
  void textChanged(String raw) {
    _raw = raw;
    _restart(wait: true);
  }

  /// The page switched tabs: the same text, searched in [scope] at once.
  void setScope(MemberSearchScope scope) {
    if (scope == _scope) return;
    _scope = scope;
    _restart(wait: false);
  }

  /// Asks again (Retry, or after a moderation action moved someone).
  void retry() => _restart(wait: false);

  /// Takes [userId]'s row out of the results (a ban or unban moved them);
  /// returns it and its index for [restore], or null.
  (pb.CommunityMember, int)? removeUser(String userId) {
    final i = state.results.indexWhere((m) => m.user.user.userId == userId);
    if (i < 0) return null;
    final row = state.results[i];
    emit(state.copyWith(results: [...state.results]..removeAt(i)));
    return (row, i);
  }

  /// Puts back a row [removeUser] took (the call failed).
  void restore(pb.CommunityMember row, int index) {
    if (isClosed) return;
    final results = [...state.results];
    results.insert(index.clamp(0, results.length), row);
    emit(state.copyWith(results: results));
  }

  void _restart({required bool wait}) {
    _timer?.cancel();
    final generation = ++_generation;
    if (state.unavailable) return;
    switch (memberSearchInputOf(_raw)) {
      case MemberSearchInput.blank:
      case MemberSearchInput.tooShort:
        emit(
          state.copyWith(
            status: MemberSearchStatus.idle,
            results: const [],
            clearError: true,
          ),
        );
      case MemberSearchInput.invalid:
        emit(
          state.copyWith(
            status: MemberSearchStatus.invalid,
            results: const [],
            clearError: true,
          ),
        );
      case MemberSearchInput.ready:
        emit(
          state.copyWith(
            status: MemberSearchStatus.loading,
            results: const [],
            clearError: true,
          ),
        );
        final prefix = memberSearchPrefix(_raw)!;
        if (wait) {
          _timer = Timer(debounce, () => _run(generation, prefix));
        } else {
          _run(generation, prefix);
        }
    }
  }

  Future<void> _run(int generation, String prefix) async {
    final scope = _scope;
    try {
      final rows = await _search(
        prefix: prefix,
        filter: scope == MemberSearchScope.banned
            ? pb.CommunityMemberFilter.COMMUNITY_MEMBER_FILTER_BANNED
            : pb.CommunityMemberFilter.COMMUNITY_MEMBER_FILTER_JOINED,
      );
      if (isClosed || generation != _generation) return;
      emit(
        state.copyWith(
          status: MemberSearchStatus.ready,
          results: scope == MemberSearchScope.moderators
              ? [
                  for (final m in rows)
                    if (m.memberRole.canModerate) m,
                ]
              : rows,
        ),
      );
    } on FeatureDisabledException catch (error) {
      if (isClosed || generation != _generation) return;
      if (error.feature == kFeatureCommunityMemberSearch) {
        emit(
          const MemberSearchState(
            status: MemberSearchStatus.idle,
            unavailable: true,
          ),
        );
        return;
      }
      emit(state.copyWith(status: MemberSearchStatus.error, error: error));
    } on AppException catch (error) {
      if (isClosed || generation != _generation) return;
      emit(state.copyWith(status: MemberSearchStatus.error, error: error));
    }
  }

  @override
  Future<void> close() {
    _timer?.cancel();
    return super.close();
  }
}
