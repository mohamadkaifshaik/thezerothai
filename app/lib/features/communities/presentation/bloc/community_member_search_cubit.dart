import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import '../../domain/communities_feature_flag.dart';
import '../../domain/community_search.dart';

/// One `SearchCommunityMembers` (F36): the members of one community whose
/// handle starts with [prefix], in the [filter]'s state.
typedef SearchCommunityMembers = Future<List<pb.CommunityMember>> Function({
  required String prefix,
  required pb.CommunityMemberFilter filter,
});

/// Which tab of the members page a search looks in.
enum MemberSearchScope {
  /// JOINED members: `SearchCommunityMembers`.
  members,

  /// The owner and the moderators: the page filters its own loaded
  /// Moderators list by handle prefix, with no call (at most 11 rows, all
  /// loaded; the server takes no MODERATORS filter for a search).
  moderators,

  /// BANNED users (owner and moderators only): `SearchCommunityMembers`.
  banned,
}

/// - [idle]: nothing to search (blank or one character); the page shows its
///   list.
/// - [invalid] / [tooLong]: the text can't be a handle prefix; a hint, no
///   call.
/// - [local]: the Moderators tab filters its own list ([prefix]); no call.
/// - [loading], [ready], [error]: one search's states. While a search loads
///   the previous [MemberSearchState.results] stay (no skeleton flash).
enum MemberSearchStatus { idle, invalid, tooLong, local, loading, ready, error }

@immutable
class MemberSearchState {
  const MemberSearchState({
    this.status = MemberSearchStatus.idle,
    this.results = const [],
    this.resultsPrefix = '',
    this.prefix = '',
    this.error,
    this.unavailable = false,
  });

  final MemberSearchStatus status;
  final List<pb.CommunityMember> results;

  /// The prefix [results] answer (shown in the count line while the next
  /// search loads).
  final String resultsPrefix;

  /// The prefix being searched (or filtered, [MemberSearchStatus.local]).
  final String prefix;
  final AppException? error;

  /// The server answered that `community_member_search` is off (or does not
  /// serve the RPC yet): the field goes away for this page.
  final bool unavailable;

  /// Whether the page shows the search instead of its list.
  bool get active => !unavailable && status != MemberSearchStatus.idle;

  MemberSearchState copyWith({
    MemberSearchStatus? status,
    List<pb.CommunityMember>? results,
    String? resultsPrefix,
    String? prefix,
    AppException? error,
    bool clearError = false,
    bool? unavailable,
  }) => MemberSearchState(
    status: status ?? this.status,
    results: results ?? this.results,
    resultsPrefix: resultsPrefix ?? this.resultsPrefix,
    prefix: prefix ?? this.prefix,
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

  /// The page switched tabs: the same text, searched in [scope] at once (the
  /// other tab's results are not kept).
  void setScope(MemberSearchScope scope) {
    if (scope == _scope) return;
    _scope = scope;
    _restart(wait: false, keep: false);
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

  void _restart({required bool wait, bool keep = true}) {
    _timer?.cancel();
    final generation = ++_generation;
    if (state.unavailable) return;
    MemberSearchState cleared(MemberSearchStatus status) => MemberSearchState(
      status: status,
      prefix: memberSearchPrefix(_raw) ?? '',
    );
    switch (memberSearchInputOf(_raw)) {
      case MemberSearchInput.blank:
      case MemberSearchInput.tooShort:
        emit(cleared(MemberSearchStatus.idle));
      case MemberSearchInput.invalid:
        emit(cleared(MemberSearchStatus.invalid));
      case MemberSearchInput.tooLong:
        emit(cleared(MemberSearchStatus.tooLong));
      case MemberSearchInput.ready:
        final prefix = memberSearchPrefix(_raw)!;
        if (_scope == MemberSearchScope.moderators) {
          emit(cleared(MemberSearchStatus.local));
          return;
        }
        // The last answer stays on screen while the next one loads, unless
        // it was another tab's.
        final stays =
            keep &&
            (state.status == MemberSearchStatus.ready ||
                state.status == MemberSearchStatus.loading) &&
            state.results.isNotEmpty;
        emit(
          stays
              ? state.copyWith(
                  status: MemberSearchStatus.loading,
                  prefix: prefix,
                  clearError: true,
                )
              : MemberSearchState(
                  status: MemberSearchStatus.loading,
                  prefix: prefix,
                ),
        );
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
          results: rows,
          resultsPrefix: prefix,
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
      emit(
        MemberSearchState(
          status: MemberSearchStatus.error,
          prefix: prefix,
          error: error,
        ),
      );
    } on AppException catch (error) {
      if (isClosed || generation != _generation) return;
      emit(
        MemberSearchState(
          status: MemberSearchStatus.error,
          prefix: prefix,
          error: error,
        ),
      );
    }
  }

  @override
  Future<void> close() {
    _timer?.cancel();
    return super.close();
  }
}
