import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/engagement/v1/engagement.pb.dart' as pb;
import '../../data/engagement_repository.dart';
import '../../domain/engagement_entry.dart';
import 'engagement_state.dart';

/// One kind of action (like or repost) on one target.
class _Lane {
  /// A request is in flight.
  bool busy = false;

  /// The latest intent the user asked for while this lane is active; null
  /// when idle.
  bool? wanted;

  /// The idempotency key of the current intent and the intent it belongs to.
  String? key;
  bool? keyIntent;
}

/// What the cubit knows about one target.
class _Target {
  _Target(EngagementEntry shown) : base = shown, confirmed = shown;

  /// What the row said when the caller first acted.
  final EngagementEntry base;

  /// The last state the server confirmed (the row's own state until then).
  EngagementEntry confirmed;

  final _Lane like = _Lane();
  final _Lane repost = _Lane();

  bool get busy => like.busy || repost.busy;
}

/// The session-wide engagement overlay (likes and reposts): optimistic
/// update with rollback, one idempotency key per user intent, and per-post
/// serialisation (ADR-0018 "Rule 4", plan T7).
///
/// - Keyed by *target id*: the original for a REPOST row, else the post.
///   Every card of the same target (Home, profile, detail, thread) reads the
///   same entry, so a like shows everywhere at once.
/// - [setLiked] / [setReposted] flip the entry at once, send one request,
///   and on failure restore the last server-confirmed state and report the
///   error once ([EngagementState.failure]). Never auto-retried: the user
///   taps again, which reuses the intent's key.
/// - While a request is in flight further taps only record the *latest*
///   intent (the entry already shows it). When the request settles, one
///   follow-up is sent only if that intent differs from what the server now
///   has; a stale intent is never resent.
/// - Like and repost are independent lanes, so liking while a repost is
///   being sent does not wait.
/// - A count that is unknown (REPOST rows) stays unknown until a server
///   answer brings the real count.
/// - [reset] (sign-out) forgets everything; requests still in flight are
///   ignored when they land.
class EngagementCubit extends Cubit<EngagementState> {
  EngagementCubit({
    required EngagementRepository repository,
    this.onUnexpectedError,
    Uuid? uuid,
  }) : _repository = repository,
       _uuid = uuid ?? const Uuid(),
       super(const EngagementState());

  final EngagementRepository _repository;
  final Uuid _uuid;
  final void Function(Object error, StackTrace stack)? onUnexpectedError;

  final Map<String, _Target> _targets = {};
  int _generation = 0;
  int _serial = 0;

  /// Likes ([liked] true) or unlikes [postId]. [shown] is what the row
  /// displays right now (the starting point the first time).
  Future<void> setLiked(
    String postId, {
    required bool liked,
    required EngagementEntry shown,
  }) => _set(postId, liked, shown, isLike: true);

  /// Reposts ([reposted] true) or undoes the repost of [postId].
  Future<void> setReposted(
    String postId, {
    required bool reposted,
    required EngagementEntry shown,
  }) => _set(postId, reposted, shown, isLike: false);

  /// The failure was shown; clears it.
  void failureShown() {
    if (!isClosed && state.failure != null) {
      emit(state.copyWith(clearFailure: true));
    }
  }

  /// Sign-out: forget every entry, key and queued intent.
  void reset() {
    _generation++;
    _targets.clear();
    if (!isClosed) emit(const EngagementState());
  }

  Future<void> _set(
    String postId,
    bool intent,
    EngagementEntry shown, {
    required bool isLike,
  }) async {
    if (isClosed || postId.isEmpty) return;
    var target = _targets[postId];
    // The row was refreshed since the last action (the server's newer data
    // wins): start again from what it says now.
    if (target == null || (!target.busy && !target.base.sameState(shown))) {
      target = _targets[postId] = _Target(shown);
    }
    final lane = isLike ? target.like : target.repost;
    if (lane.busy) {
      // Latest intent wins; the display follows it, one request at a time.
      lane.wanted = intent;
      _publish(postId);
      return;
    }
    final confirmedFlag = isLike
        ? target.confirmed.liked
        : target.confirmed.reposted;
    if (confirmedFlag == intent) return;

    lane.busy = true;
    lane.wanted = intent;
    _publish(postId);
    final generation = _generation;
    while (true) {
      final wanted = lane.wanted!;
      final key = _keyFor(lane, wanted);
      try {
        final result = await _send(postId, wanted, key, isLike: isLike);
        if (generation != _generation) return;
        lane.key = null;
        lane.keyIntent = null;
        target.confirmed = _confirm(target.confirmed, result, isLike);
        final flag = isLike
            ? target.confirmed.liked
            : target.confirmed.reposted;
        if (lane.wanted != null && lane.wanted != flag) continue;
        lane.busy = false;
        lane.wanted = null;
        _publish(postId);
        return;
      } on AppException catch (error) {
        if (generation != _generation) return;
        _fail(postId, lane, isLike, wanted, error);
        return;
      } catch (error, stack) {
        onUnexpectedError?.call(error, stack);
        if (generation != _generation) return;
        _fail(
          postId,
          lane,
          isLike,
          wanted,
          const UnknownApiException('Something went wrong.'),
        );
        return;
      }
    }
  }

  /// The key of the current intent: reused until it succeeds; the opposite
  /// intent (unlike after a failed like) is a different request and gets its
  /// own key.
  String _keyFor(_Lane lane, bool intent) {
    if (lane.key == null || lane.keyIntent != intent) {
      lane.key = _uuid.v4();
      lane.keyIntent = intent;
    }
    return lane.key!;
  }

  Future<pb.PostEngagement> _send(
    String postId,
    bool intent,
    String key, {
    required bool isLike,
  }) {
    if (isLike) {
      return intent
          ? _repository.like(postId: postId, idempotencyKey: key)
          : _repository.unlike(postId: postId, idempotencyKey: key);
    }
    return intent
        ? _repository.repost(postId: postId, idempotencyKey: key)
        : _repository.undoRepost(postId: postId, idempotencyKey: key);
  }

  EngagementEntry _confirm(
    EngagementEntry entry,
    pb.PostEngagement result,
    bool isLike,
  ) => isLike
      ? entry.copyWith(
          liked: result.likedByViewer,
          likeCount: result.likeCount.toInt(),
        )
      : entry.copyWith(
          reposted: result.repostedByViewer,
          repostCount: result.repostCount.toInt(),
        );

  void _fail(
    String postId,
    _Lane lane,
    bool isLike,
    bool intent,
    AppException error,
  ) {
    // Rollback: with no wanted intent the display is the confirmed state.
    lane.busy = false;
    lane.wanted = null;
    _publish(
      postId,
      failure: EngagementFailure(
        postId: postId,
        action: isLike
            ? (intent ? EngagementAction.like : EngagementAction.unlike)
            : (intent ? EngagementAction.repost : EngagementAction.undoRepost),
        error: error,
        serial: ++_serial,
      ),
    );
  }

  /// The entry the cards show: the confirmed state with each active lane's
  /// wanted intent applied (flag, and the count moved by one).
  EngagementEntry _display(_Target t) {
    var e = t.confirmed;
    final like = t.like.wanted;
    if (like != null && like != e.liked) {
      e = e.copyWith(
        liked: like,
        likeCount: _moved(e.likeCount, like ? 1 : -1),
      );
    }
    final repost = t.repost.wanted;
    if (repost != null && repost != e.reposted) {
      e = e.copyWith(
        reposted: repost,
        repostCount: _moved(e.repostCount, repost ? 1 : -1),
      );
    }
    return EngagementEntry(
      liked: e.liked,
      reposted: e.reposted,
      likeCount: e.likeCount,
      repostCount: e.repostCount,
      likeBusy: t.like.busy,
      repostBusy: t.repost.busy,
      base: t.base,
    );
  }

  static int? _moved(int? count, int delta) =>
      count == null ? null : (count + delta < 0 ? 0 : count + delta);

  void _publish(String postId, {EngagementFailure? failure}) {
    final target = _targets[postId];
    if (isClosed || target == null) return;
    emit(
      state.copyWith(
        entries: {...state.entries, postId: _display(target)},
        failure: failure,
      ),
    );
  }
}
