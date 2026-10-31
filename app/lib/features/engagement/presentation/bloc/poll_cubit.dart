import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../data/poll_repository.dart';
import 'poll_state.dart';

/// The session-wide poll overlay: the optimistic vote with rollback, the
/// fresh counts after a vote or a re-read, and the refusals (W6-13, ADR-0029).
///
/// - Keyed by the *original* post id (the target of a REPOST row). Every card
///   of the same poll (Home, profile, detail, thread) reads the same entry.
/// - [vote] marks the choice at once, sends one `VotePoll`, and on success
///   keeps the response (the committed counts). On failure the buttons come
///   back and the error is reported once ([PollState.failure]). A vote is
///   final, so there is one request per post at a time.
/// - One idempotency key per (post, choice) intent, reused on a retry tap and
///   dropped when the call succeeds or the intent is settled by a refusal.
/// - ALREADY_VOTED re-reads the post once and shows the server's choice;
///   POLL_CLOSED re-reads it once and shows the final results.
///   FEATURE_DISABLED (or an UNIMPLEMENTED skeleton) hides the vote buttons.
/// - [refresh] is "See final results": one `GetPost`.
/// - [reset] (sign-out) forgets everything; late answers are ignored.
///
/// Nothing here logs a choice.
class PollCubit extends Cubit<PollState> {
  PollCubit({
    required PollRepository repository,
    this.onUnexpectedError,
    Uuid? uuid,
  }) : _repository = repository,
       _uuid = uuid ?? const Uuid(),
       super(const PollState());

  final PollRepository _repository;
  final Uuid _uuid;
  final void Function(Object error, StackTrace stack)? onUnexpectedError;

  final Map<String, String> _keys = {};
  int _generation = 0;
  int _serial = 0;

  PollEntry _entry(String postId) => state.entries[postId] ?? const PollEntry();

  void _put(String postId, PollEntry entry, {PollFailure? failure}) {
    if (isClosed) return;
    emit(
      state.copyWith(
        entries: {...state.entries, postId: entry},
        failure: failure,
      ),
    );
  }

  /// Whether a card may offer vote buttons right now (besides the viewer's
  /// own `engagement` flag, which the card reads).
  bool get votingOff => state.votingOff || _repository.votingOff;

  /// Votes [choiceIndex] (0-based) in the poll of [postId].
  Future<void> vote(String postId, int choiceIndex) async {
    if (isClosed || postId.isEmpty || choiceIndex < 0) return;
    final current = _entry(postId);
    if (current.pendingChoice != null || current.refreshing) return;
    final intent = '$postId:$choiceIndex';
    final key = _keys.putIfAbsent(intent, _uuid.v4);
    _put(postId, current.copyWith(pendingChoice: choiceIndex));
    final generation = _generation;
    try {
      final view = await _repository.vote(
        postId: postId,
        choiceIndex: choiceIndex,
        idempotencyKey: key,
      );
      if (generation != _generation) return;
      _keys.remove(intent);
      _put(postId, _entry(postId).copyWith(clearPending: true, fresh: view));
    } on AlreadyVotedException catch (error) {
      if (generation != _generation) return;
      _keys.remove(intent);
      _put(
        postId,
        _entry(postId)
            .copyWith(clearPending: true, knownChoice: error.choiceIndex),
      );
      await _reread(postId, generation, reportFailure: false);
    } on PollClosedException {
      if (generation != _generation) return;
      _keys.remove(intent);
      _put(postId, _entry(postId).copyWith(clearPending: true, closed: true));
      await _reread(postId, generation, reportFailure: false);
    } on AppException catch (error) {
      if (generation != _generation) return;
      _failVote(postId, error);
    } catch (error, stack) {
      onUnexpectedError?.call(error, stack);
      if (generation != _generation) return;
      _failVote(postId, const UnknownApiException('Something went wrong.'));
    }
  }

  /// "See final results": one `GetPost`.
  Future<void> refresh(String postId) async {
    if (isClosed || postId.isEmpty || _entry(postId).refreshing) return;
    _put(postId, _entry(postId).copyWith(refreshing: true));
    await _reread(postId, _generation, reportFailure: true);
  }

  /// The failure was shown; clears it.
  void failureShown() {
    if (!isClosed && state.failure != null) {
      emit(state.copyWith(clearFailure: true));
    }
  }

  /// A fresh `GetMe` changed the flag set: a remembered refusal of voting no
  /// longer decides, the flags do.
  void flagsChanged() {
    _repository.reset();
    if (!isClosed && state.votingOff) emit(state.copyWith(votingOff: false));
  }

  /// Sign-out: forget every entry, key and flag. Requests still in flight are
  /// ignored when they land.
  void reset() {
    _generation++;
    _keys.clear();
    _repository.reset();
    if (!isClosed) emit(const PollState());
  }

  Future<void> _reread(
    String postId,
    int generation, {
    required bool reportFailure,
  }) async {
    try {
      final view = await _repository.refresh(postId);
      if (generation != _generation) return;
      _put(postId, _entry(postId).copyWith(refreshing: false, fresh: view));
    } on AppException catch (error) {
      if (generation != _generation) return;
      _put(
        postId,
        _entry(postId).copyWith(refreshing: false),
        failure: reportFailure
            ? PollFailure(
                postId: postId,
                action: PollAction.refresh,
                error: error,
                serial: ++_serial,
              )
            : null,
      );
    } catch (error, stack) {
      onUnexpectedError?.call(error, stack);
      if (generation != _generation) return;
      _put(postId, _entry(postId).copyWith(refreshing: false));
    }
  }

  void _failVote(String postId, AppException error) {
    if (isClosed) return;
    emit(
      state.copyWith(
        entries: {
          ...state.entries,
          postId: _entry(postId).copyWith(clearPending: true),
        },
        votingOff: error is FeatureDisabledException ? true : null,
        failure: PollFailure(
          postId: postId,
          action: PollAction.vote,
          error: error,
          serial: ++_serial,
        ),
      ),
    );
  }
}
