import 'dart:async';

import 'package:uuid/uuid.dart';

import '../../../core/feature_flags/service_feature_gate.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/app_exception.dart';
import '../../../core/storage/session_epoch.dart';
import '../../../gen/dzeroth/engagement/v1/engagement.pb.dart' as pb;
import '../domain/bookmark_entry.dart';

/// Something the session's bookmark state did, for `BookmarksCubit`.
sealed class BookmarkEvent {
  const BookmarkEvent();
}

/// An entry changed, or the session was cleared.
final class BookmarksChanged extends BookmarkEvent {
  const BookmarksChanged();
}

/// A toggle failed and was rolled back to the last server-confirmed state.
final class BookmarkFailed extends BookmarkEvent {
  const BookmarkFailed({
    required this.postId,
    required this.wanted,
    required this.error,
  });

  final String postId;

  /// The intent that failed: true = add, false = remove.
  final bool wanted;
  final AppException error;
}

/// The last request of a burst of toggles settled on a state different from
/// where it started (the toast "Added to Bookmarks" / "Removed from
/// Bookmarks").
final class BookmarkSettled extends BookmarkEvent {
  const BookmarkSettled({required this.postId, required this.saved});

  final String postId;
  final bool saved;
}

class _Rec {
  _Rec({required this.confirmed, required this.touched, this.base});

  /// The last state the server confirmed (or a list page reported).
  bool confirmed;
  final bool touched;
  final bool? base;

  /// The latest intent while a request burst runs; null when idle.
  bool? wanted;
  bool busy = false;

  /// [confirmed] when the current burst started (decides the toast).
  bool startedAs = false;

  /// The idempotency key of the current intent and the intent it belongs to.
  String? key;
  bool? keyIntent;

  BookmarkEntry get entry => BookmarkEntry(
    saved: wanted ?? confirmed,
    busy: busy,
    touched: touched,
    base: base,
  );
}

/// The client's one source of "is this post bookmarked" and the only caller
/// of AddBookmark / RemoveBookmark (ADR-0023, plan W2-6 / W2-7). Widgets
/// never ask it directly: `BookmarksCubit` mirrors it.
///
/// - **Overlay.** Per post, a [BookmarkEntry]: the session's toggles plus the
///   posts of any list page ([recordListed]). [BookmarkEntry.resolve] decides
///   between that and the server flag a row may carry. Session memory only,
///   no drift table; dropped as soon as the [SessionEpoch] ends (sign-out),
///   and an RPC that lands after that is ignored.
/// - **Toggles.** [setBookmarked] flips the entry at once, sends one request
///   at a time per post, and on failure restores the last confirmed state and
///   reports [BookmarkFailed]. Taps during a request only record the latest
///   intent; when the request settles one follow-up is sent only if that
///   intent differs from what the server now has. One idempotency key per
///   intent, reused on a retry after a failure, new for the opposite intent.
///   Never auto-retried; the transport never resends these (not side-effect
///   free). 1 RPC per tap in the common case.
/// - **Flag.** AddBookmark goes through [ServiceFeatureGate] (0 RPCs while
///   `bookmarks` is off for the caller). RemoveBookmark deliberately does not:
///   ADR-0023 D5 lets a user dropped from the allowlist still remove what
///   they saved, and a FEATURE_DISABLED answer to Add must not block it.
///
/// `postId` is always the target: the original for a REPOST row.
class BookmarksRepository {
  BookmarksRepository({
    required ApiClient apiClient,
    required ServiceFeatureGate gate,
    required SessionEpoch epoch,
    Uuid? uuid,
    void Function(Object error, StackTrace stack)? onUnexpectedError,
  }) : _apiClient = apiClient,
       _gate = gate,
       _epoch = epoch,
       _seenEpoch = epoch.value,
       _uuid = uuid ?? const Uuid(),
       _onUnexpectedError = onUnexpectedError;

  final ApiClient _apiClient;
  final ServiceFeatureGate _gate;
  final SessionEpoch _epoch;
  final Uuid _uuid;
  final void Function(Object error, StackTrace stack)? _onUnexpectedError;

  final Map<String, _Rec> _recs = {};
  final StreamController<BookmarkEvent> _events =
      StreamController<BookmarkEvent>.broadcast(sync: true);
  int _seenEpoch;
  int _generation = 0;

  /// Whether AddBookmark may be sent at all right now.
  bool get enabled => _gate.enabled;

  /// Changes, failures and settled toggles, in order.
  Stream<BookmarkEvent> get events => _events.stream;

  /// A copy of every entry the session knows.
  Map<String, BookmarkEntry> snapshot() {
    _sync(notify: false);
    return {for (final e in _recs.entries) e.key: e.value.entry};
  }

  /// Whether [postId] is bookmarked: the session entry resolved against the
  /// row's server flag [server] (`null`: none). See [BookmarkEntry.resolve].
  bool isBookmarked(String postId, {bool? server}) {
    _sync(notify: false);
    return _recs[postId]?.entry.resolve(server) ?? server ?? false;
  }

  /// A ListBookmarks page (or any server answer) said these posts are
  /// bookmarked: remember them in the local set. A request in flight keeps
  /// its own intent.
  void recordListed(Iterable<String> postIds) {
    _sync();
    var changed = false;
    for (final id in postIds) {
      if (id.isEmpty) continue;
      final rec = _recs[id];
      if (rec == null) {
        _recs[id] = _Rec(confirmed: true, touched: false);
        changed = true;
      } else if (!rec.busy && !rec.confirmed) {
        rec.confirmed = true;
        changed = true;
      }
    }
    if (changed) _emit(const BookmarksChanged());
  }

  /// Sign-out: forget everything; requests still in flight are ignored when
  /// they land.
  void clearSession() => _wipe();

  /// Bookmarks ([saved] true) or removes [postId]. [server] is the row's own
  /// flag right now (`null`: none), the starting point the first time.
  Future<void> setBookmarked(
    String postId, {
    required bool saved,
    bool? server,
  }) async {
    if (postId.isEmpty) return;
    _sync();
    var rec = _recs[postId];
    // New to the session, listed only, or the row was refreshed since the
    // last toggle (the server's newer data wins): start from what it says.
    if (rec == null || !rec.touched || (!rec.busy && rec.base != server)) {
      rec = _recs[postId] = _Rec(
        confirmed: rec?.entry.resolve(server) ?? server ?? false,
        touched: true,
        base: server,
      );
    }
    if (rec.busy) {
      // Latest intent wins; one request at a time.
      rec.wanted = saved;
      _emit(const BookmarksChanged());
      return;
    }
    if (rec.confirmed == saved) return;

    rec.busy = true;
    rec.wanted = saved;
    rec.startedAs = rec.confirmed;
    _emit(const BookmarksChanged());
    final generation = _generation;
    while (true) {
      final wanted = rec.wanted!;
      try {
        final state = await _send(postId, wanted, _keyFor(rec, wanted));
        if (generation != _generation || _staleEpoch) return;
        rec.key = null;
        rec.keyIntent = null;
        rec.confirmed = state.bookmarked;
        if (rec.wanted != null && rec.wanted != rec.confirmed) continue;
        rec.busy = false;
        rec.wanted = null;
        _emit(const BookmarksChanged());
        if (rec.confirmed != rec.startedAs) {
          _emit(BookmarkSettled(postId: postId, saved: rec.confirmed));
        }
        return;
      } on AppException catch (error) {
        if (generation != _generation || _staleEpoch) return;
        _fail(postId, rec, wanted, error);
        return;
      } catch (error, stack) {
        _onUnexpectedError?.call(error, stack);
        if (generation != _generation || _staleEpoch) return;
        _fail(
          postId,
          rec,
          wanted,
          const UnknownApiException('Something went wrong.'),
        );
        return;
      }
    }
  }

  Future<pb.BookmarkState> _send(String postId, bool add, String key) async {
    if (add) {
      final response = await _gate.run(
        () => _apiClient.engagement.addBookmark(
          pb.AddBookmarkRequest(idempotencyKey: key, postId: postId),
        ),
      );
      return response.state;
    }
    final response = await guardApiCall(
      () => _apiClient.engagement.removeBookmark(
        pb.RemoveBookmarkRequest(idempotencyKey: key, postId: postId),
      ),
    );
    return response.state;
  }

  /// The key of the current intent: reused until it succeeds; the opposite
  /// intent is a different request and gets its own key.
  String _keyFor(_Rec rec, bool intent) {
    if (rec.key == null || rec.keyIntent != intent) {
      rec.key = _uuid.v4();
      rec.keyIntent = intent;
    }
    return rec.key!;
  }

  void _fail(String postId, _Rec rec, bool wanted, AppException error) {
    // Rollback: with no wanted intent the display is the confirmed state.
    rec.busy = false;
    rec.wanted = null;
    _emit(const BookmarksChanged());
    _emit(BookmarkFailed(postId: postId, wanted: wanted, error: error));
  }

  bool get _staleEpoch => _epoch.value != _seenEpoch;

  /// Drops the session when the shared [SessionEpoch] ended since it was
  /// last looked at (sign-out), whoever ended it.
  void _sync({bool notify = true}) {
    if (_staleEpoch) _wipe(notify: notify);
  }

  void _wipe({bool notify = true}) {
    _seenEpoch = _epoch.value;
    _generation++;
    _recs.clear();
    if (notify) _emit(const BookmarksChanged());
  }

  void _emit(BookmarkEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  Future<void> dispose() => _events.close();
}
