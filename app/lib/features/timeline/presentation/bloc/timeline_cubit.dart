import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../../posts/data/posts_repository.dart';
import '../../data/timeline_repository.dart';
import '../../data/timeline_store.dart';
import '../../domain/feed_key.dart';
import 'timeline_state.dart';

/// Automatic refreshes happen at most this often (ADR-0004 section 7).
const kAutoRefreshInterval = Duration(seconds: 60);

/// Drives one cached feed (Home, or a profile's Posts tab) over
/// [TimelineRepository] (T17/T18, ADR-0004 section 7, ADR-0010 D5/D13/D14).
///
/// - [load] renders the cache at once (one `cached` read per screen open),
///   then refreshes unless this feed was refreshed less than
///   [kAutoRefreshInterval] ago (the stamp lives in the repository, so
///   re-opening Home does not cost an RPC each time).
/// - Automatic refreshes ([refreshIfStale]: resume, the 30 s foreground
///   tick) never insert posts above what the user reads: new posts are held
///   back and counted in [TimelineState.newPosts] (the pill) until
///   [showNewPosts]. A pull ([refresh]) shows them directly. Posts are
///   counted by `post_id`, so a post returned by two refreshes (settle
///   window, D13) counts once.
/// - Automatic refreshes are skipped once the list holds
///   [kTimelineRetention] rows or more (the store trims there and the list
///   would jump) and while the server asked us to wait (RATE_LIMITED): the
///   cache stays visible under a non-blocking notice, with no retry storm.
/// - Errors with nothing cached are blocking ([TimelineStatus.error]);
///   otherwise they are a [TimelineState.notice].
/// - Blocked/muted authors are hidden locally ([hideAuthor], D6) and a
///   deleted post is removed optimistically ([deletePost]), both without a
///   refetch.
class TimelineCubit extends Cubit<TimelineState> {
  TimelineCubit({
    required FeedKey feed,
    required TimelineRepository timeline,
    required PostsRepository posts,
    this.viewerUserId,
    this.onPostDeleted,
    Uuid? uuid,
  }) : _feed = feed,
       _timeline = timeline,
       _posts = posts,
       _uuid = uuid ?? const Uuid(),
       super(const TimelineState()) {
    _removedSub = _posts.removedPosts.listen((postId) {
      _removed.add(postId);
      _emitVisible();
    });
  }

  final FeedKey _feed;
  final TimelineRepository _timeline;
  final PostsRepository _posts;
  final Uuid _uuid;

  /// The signed-in user: their own posts are never held behind the pill. It
  /// can arrive after the cubit is created (the profile loads asynchronously),
  /// so the screen updates it when the profile appears.
  String? viewerUserId;

  /// Called after a post deleted through this cubit was confirmed by the
  /// server (the profile decrements its post count).
  final void Function(pb.PostView post)? onPostDeleted;

  late final StreamSubscription<String> _removedSub;

  TimelineSnapshot _snapshot = const TimelineSnapshot();
  final Set<String> _known = {};
  final Set<String> _held = {};
  final Set<String> _removed = {};
  final Set<String> _hiddenAuthors = {};
  final Map<String, String> _deleteKeys = {};

  /// Opens the feed: cache first, then (throttled) one refresh.
  Future<void> load() async {
    final cached = await _timeline.cached(_feed);
    if (isClosed) return;
    _snapshot = cached;
    _known.addAll(_postIds(cached));
    final visible = _visible(cached);
    emit(
      state.copyWith(
        status: visible.any((e) => !e.isGap)
            ? TimelineStatus.ready
            : TimelineStatus.loading,
        entries: visible,
        hasMore: cached.hasMore,
      ),
    );
    final since = _timeline.sinceRefresh(_feed);
    if (since != null && since < kAutoRefreshInterval) {
      // Refreshed moments ago (another screen instance): nothing to ask.
      if (state.status == TimelineStatus.loading) {
        emit(state.copyWith(status: TimelineStatus.ready));
      }
      return;
    }
    await _refresh(userInitiated: false);
  }

  /// Pull-to-refresh: new posts are shown directly.
  Future<void> refresh() => _refresh(userInitiated: true);

  /// Resume / foreground tick: throttled, and held behind the pill.
  Future<void> refreshIfStale() async {
    if (isClosed || state.refreshing || state.loadingMore) return;
    if (state.entries.length >= kTimelineRetention) return;
    if (_timeline.rateLimitedFor() != null) return;
    // Throttle on the last attempt, not the last success: during an outage the
    // tick must not retry every 30 s.
    final since = _timeline.sinceRefreshAttempt(_feed);
    if (since != null && since < kAutoRefreshInterval) return;
    await _refresh(userInitiated: false);
  }

  Future<void> _refresh({required bool userInitiated}) async {
    if (isClosed || state.refreshing) return;
    final limited = _timeline.rateLimitedFor();
    if (limited != null) {
      _holdBack(limited);
      return;
    }
    final hadPosts = state.hasPosts;
    emit(state.copyWith(refreshing: true));
    try {
      final snapshot = await _timeline.refresh(_feed);
      if (isClosed) return;
      if (userInitiated) _held.clear();
      _apply(snapshot, holdNew: !userInitiated && hadPosts);
      emit(
        state.copyWith(
          status: TimelineStatus.ready,
          refreshing: false,
          clearError: true,
          clearNotice: true,
        ),
      );
    } on AppException catch (e) {
      _fail(e);
    } catch (_) {
      _fail(const UnknownApiException('Something went wrong.'));
    }
  }

  /// Shows the rows a refresh held back (the pill was tapped).
  void showNewPosts() {
    if (_held.isEmpty) return;
    _held.clear();
    _emitVisible();
  }

  /// Infinite scroll. No-op without an older page, while loading, or after a
  /// failure until [retryLoadMore].
  Future<void> loadMore() async {
    if (isClosed ||
        !state.hasMore ||
        state.loadingMore ||
        state.refreshing ||
        state.loadMoreFailed) {
      return;
    }
    final limited = _timeline.rateLimitedFor();
    if (limited != null) {
      _holdBack(limited);
      return;
    }
    emit(state.copyWith(loadingMore: true));
    try {
      final snapshot = await _timeline.loadOlder(_feed);
      if (isClosed) return;
      _apply(snapshot);
      emit(state.copyWith(loadingMore: false));
    } on AppException catch (e) {
      _failMore(e);
    } catch (_) {
      _failMore(const UnknownApiException('Something went wrong.'));
    }
  }

  /// The user tapped Retry under a failed older-page load.
  Future<void> retryLoadMore() async {
    if (isClosed || !state.loadMoreFailed) return;
    emit(state.copyWith(loadMoreFailed: false));
    await loadMore();
  }

  /// Loads the gap row [itemKey]: exactly one call with its gap token.
  Future<void> fillGap(String itemKey) async {
    if (isClosed || state.loadingGapKey != null) return;
    final limited = _timeline.rateLimitedFor();
    if (limited != null) {
      _holdBack(limited);
      return;
    }
    emit(state.copyWith(loadingGapKey: itemKey));
    try {
      final snapshot = await _timeline.fillGap(_feed, itemKey);
      if (isClosed) return;
      _apply(snapshot);
      emit(state.copyWith(clearLoadingGap: true));
    } on AppException catch (e) {
      if (isClosed) return;
      emit(state.copyWith(clearLoadingGap: true, notice: e));
    } catch (_) {
      if (isClosed) return;
      emit(
        state.copyWith(
          clearLoadingGap: true,
          notice: const UnknownApiException('Something went wrong.'),
        ),
      );
    }
  }

  /// Re-reads the cache (no RPC): after the caller's own post was stored.
  Future<void> reloadFromCache() async {
    final cached = await _timeline.cached(_feed);
    if (isClosed) return;
    _apply(cached);
  }

  /// D6: the caller blocked or muted [userId]; their posts leave the list.
  void hideAuthor(String userId) {
    if (_hiddenAuthors.add(userId)) _emitVisible();
  }

  /// D6: the caller unblocked or unmuted [userId]; their cached posts return.
  void restoreAuthor(String userId) {
    if (_hiddenAuthors.remove(userId)) _emitVisible();
  }

  /// Deletes the caller's post. It leaves the list at once and comes back if
  /// the call fails (the error is rethrown for the card's snackbar). One
  /// idempotency key per post until it succeeds, so a retry is the same
  /// intent.
  Future<void> deletePost(String postId) async {
    final removedView = _snapshot.entries
        .map((e) => e.postView)
        .where((v) => v != null && v.post.postId == postId)
        .firstOrNull;
    final key = _deleteKeys[postId] ??= _uuid.v4();
    _removed.add(postId);
    _emitVisible();
    try {
      await _posts.deletePost(postId: postId, idempotencyKey: key);
    } catch (_) {
      _removed.remove(postId);
      _emitVisible();
      rethrow;
    }
    _deleteKeys.remove(postId);
    if (removedView != null) onPostDeleted?.call(removedView);
  }

  // -- internals -----------------------------------------------------------

  Iterable<String> _postIds(TimelineSnapshot s) => [
    for (final e in s.entries)
      if (!e.isGap) e.postView!.post.postId,
  ];

  /// Stores [snapshot] as the latest and emits the visible rows. With
  /// [holdNew], posts not seen before (and not the viewer's own) are held
  /// behind the pill instead of being inserted.
  void _apply(TimelineSnapshot snapshot, {bool holdNew = false}) {
    for (final e in snapshot.entries) {
      final view = e.postView;
      if (view == null) continue;
      final id = view.post.postId;
      if (holdNew &&
          !_known.contains(id) &&
          view.post.author.userId != viewerUserId) {
        _held.add(id);
      }
      _known.add(id);
    }
    _snapshot = snapshot;
    _emitVisible();
  }

  List<TimelineEntry> _visible(TimelineSnapshot s) {
    final rows = <TimelineEntry>[];
    for (final e in s.entries) {
      final view = e.postView;
      if (view != null) {
        final id = view.post.postId;
        if (_held.contains(id) ||
            _removed.contains(id) ||
            _hiddenAuthors.contains(view.post.author.userId)) {
          continue;
        }
      } else if (rows.isEmpty) {
        // A gap with nothing visible above it (its posts are held back).
        continue;
      }
      rows.add(e);
    }
    return rows;
  }

  void _emitVisible() {
    if (isClosed) return;
    emit(
      state.copyWith(
        entries: _visible(_snapshot),
        hasMore: _snapshot.hasMore,
        newPosts: _held.length,
      ),
    );
  }

  /// A RATE_LIMITED answer is known: show it without sending anything.
  void _holdBack(RateLimitedException limited) {
    if (isClosed) return;
    if (state.hasPosts) {
      emit(state.copyWith(notice: limited));
    } else {
      emit(state.copyWith(status: TimelineStatus.error, error: limited));
    }
  }

  void _fail(AppException error) {
    if (isClosed) return;
    if (state.hasPosts) {
      emit(state.copyWith(refreshing: false, notice: error));
    } else {
      emit(
        state.copyWith(
          status: TimelineStatus.error,
          refreshing: false,
          error: error,
        ),
      );
    }
  }

  void _failMore(AppException error) {
    if (isClosed) return;
    emit(
      state.copyWith(
        loadingMore: false,
        loadMoreFailed: true,
        notice: error is RateLimitedException ? error : null,
      ),
    );
  }

  @override
  Future<void> close() async {
    await _removedSub.cancel();
    return super.close();
  }
}
