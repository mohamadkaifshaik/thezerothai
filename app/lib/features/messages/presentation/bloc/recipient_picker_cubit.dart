import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/common/v1/common.pb.dart' as common;
import '../../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../../onboarding/data/identity_repository.dart';
import '../../../onboarding/domain/handle_rules.dart' show kHandlePattern;
import '../../domain/people_source.dart';

/// Typeahead waits this long after the last keystroke (the client rule:
/// debounce 300 ms).
const kPickerSearchDebounce = Duration(milliseconds: 300);

/// Typeahead starts at this many characters (the client rule: at least 2).
const kPickerSearchMinChars = 2;

/// What "To:" has to show beyond the Following list.
@immutable
class RecipientPickerState {
  const RecipientPickerState({
    this.query = '',
    this.remote,
    this.searching = false,
    this.searchError,
    this.resolving = false,
    this.resolveError,
  });

  /// The text typed in "To:".
  final String query;

  /// The rows the source's typeahead answered for the current query; null
  /// when none was asked (search off, a short query, or the local filter).
  final List<graph.UserListItem>? remote;
  final bool searching;

  /// The last typeahead failure: the picker falls back to the local filter.
  final AppException? searchError;

  /// A "Message @handle" row is being resolved with `GetProfile`.
  final bool resolving;

  /// The last resolve failure, shown once by the screen.
  final AppException? resolveError;

  /// The query without a leading `@`, trimmed and lower-cased.
  String get normalized {
    final text = query.trim().toLowerCase();
    return text.startsWith('@') ? text.substring(1) : text;
  }

  bool get hasQuery => normalized.isNotEmpty;

  /// The handle the "Message @handle" row offers, or null when the text is
  /// not a valid handle.
  String? get handleCandidate =>
      kHandlePattern.hasMatch(normalized) ? normalized : null;

  RecipientPickerState copyWith({
    String? query,
    Object? remote = _keep,
    bool? searching,
    Object? searchError = _keep,
    bool? resolving,
    Object? resolveError = _keep,
  }) => RecipientPickerState(
    query: query ?? this.query,
    remote: identical(remote, _keep)
        ? this.remote
        : remote as List<graph.UserListItem>?,
    searching: searching ?? this.searching,
    searchError: identical(searchError, _keep)
        ? this.searchError
        : searchError as AppException?,
    resolving: resolving ?? this.resolving,
    resolveError: identical(resolveError, _keep)
        ? this.resolveError
        : resolveError as AppException?,
  );
}

const Object _keep = Object();

/// Drives the "To:" field of the new-message picker (W7-17, ADR-0027 D5).
///
/// - The Following list itself is a `UserListCubit` over
///   [PeopleSource.page]; this cubit only owns what is typed.
/// - Typeahead goes to [PeopleSource.search] only when [searchEnabled] (the
///   caller's `search` flag), the source searches remotely, the normalised
///   query has at least [kPickerSearchMinChars] characters, and 300 ms passed
///   since the last key: typing "ab" quickly makes one call. A failure
///   (RATE_LIMITED included) is recorded and the picker uses the local filter
///   from then on; nothing retries by itself.
/// - Without it, the screen filters the Following rows already loaded and
///   offers "Message @handle", which [resolveHandle] turns into a person with
///   one `GetProfile`.
/// - Nothing here logs the query or a handle.
class RecipientPickerCubit extends Cubit<RecipientPickerState> {
  RecipientPickerCubit({
    required PeopleSource source,
    required IdentityRepository identityRepository,
    required this.searchEnabled,
    this.ownUserId,
    this.debounce = kPickerSearchDebounce,
    this.onUnexpectedError,
  }) : _source = source,
       _identity = identityRepository,
       super(const RecipientPickerState());

  final PeopleSource _source;
  final IdentityRepository _identity;
  final bool searchEnabled;
  final String? ownUserId;
  final Duration debounce;
  final void Function(Object error, StackTrace stack)? onUnexpectedError;

  Timer? _timer;
  bool _searchDown = false;

  bool get _remote => searchEnabled && _source.searchesRemotely && !_searchDown;

  /// The text of "To:" changed.
  void queryChanged(String text) {
    _timer?.cancel();
    final next = state.copyWith(
      query: text,
      remote: null,
      searching: false,
      searchError: null,
      resolveError: null,
    );
    emit(next);
    if (!_remote || next.normalized.length < kPickerSearchMinChars) return;
    emit(state.copyWith(searching: true));
    final asked = next.normalized;
    _timer = Timer(debounce, () => unawaited(_search(asked)));
  }

  Future<void> _search(String asked) async {
    try {
      final rows = await _source.search(asked);
      if (isClosed || state.normalized != asked) return;
      emit(state.copyWith(remote: rows, searching: false));
    } on AppException catch (error, stack) {
      if (isClosed || state.normalized != asked) return;
      if (error is UnknownApiException) onUnexpectedError?.call(error, stack);
      _searchDown = true;
      emit(state.copyWith(searching: false, searchError: error));
    }
  }

  /// "Message @handle": resolves [handle] with `GetProfile` and returns the
  /// person, or null after recording [RecipientPickerState.resolveError]
  /// (one answer for a missing, suspended or blocking account).
  Future<common.AuthorSnapshot?> resolveHandle(String handle) async {
    if (state.resolving) return null;
    emit(state.copyWith(resolving: true, resolveError: null));
    try {
      final profile = await _identity.getProfile(handle: handle);
      if (isClosed) return null;
      if (profile.userId == ownUserId) {
        emit(
          state.copyWith(
            resolving: false,
            resolveError: const ValidationException(
              "You can't message yourself.",
            ),
          ),
        );
        return null;
      }
      emit(state.copyWith(resolving: false));
      return common.AuthorSnapshot(
        userId: profile.userId,
        handle: profile.handle,
        displayName: profile.displayName,
        avatarUrl: profile.avatarUrl,
        verified: profile.verified,
        isPrivate: profile.isPrivate,
      );
    } on AppException catch (error, stack) {
      if (error is UnknownApiException) onUnexpectedError?.call(error, stack);
      if (!isClosed) {
        emit(state.copyWith(resolving: false, resolveError: error));
      }
      return null;
    }
  }

  /// The screen showed [RecipientPickerState.resolveError].
  void resolveErrorShown() {
    if (state.resolveError != null) emit(state.copyWith(resolveError: null));
  }

  @override
  Future<void> close() {
    _timer?.cancel();
    return super.close();
  }
}
