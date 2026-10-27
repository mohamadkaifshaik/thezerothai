import 'dart:async';

import 'package:connectrpc/connect.dart' as connect;
import 'package:flutter/foundation.dart';

import '../../../core/feature_flags/service_feature_gate.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/app_exception.dart';
import '../../../core/network/rate_limit_hold.dart';
import '../../../core/storage/session_epoch.dart';
import '../../../gen/dzeroth/engagement/v1/engagement.pb.dart' as pb;
import '../../../gen/dzeroth/posts/v1/posts.pb.dart' as posts_pb;
import '../domain/engagement_entry.dart' show engagementTargetId;
import '../domain/likes_list_feature_flag.dart';

/// How long an UNIMPLEMENTED answer to `ListLikedPosts` keeps the Likes tab
/// away (the RPC is a skeleton on an environment where W3-10 is not deployed
/// yet while the flag is already on). No call is sent meanwhile, nothing is
/// reported, no `GetMe` refresh is asked for.
const kLikesUnavailableBackoff = Duration(minutes: 10);

/// Most `ListLikedPosts` calls one [LikesRepository.fetchPage] makes when the
/// pages keep coming back without a row we do not already have (the server
/// drops hidden, blocked and missing posts and never refills a page). The
/// screen asks again for the rest; the cap only keeps one ask from spending
/// the whole per-minute bucket (10 / min).
const kLikesMaxCallsPerFetch = 5;

/// One round of the Likes list: the new rows (live posts, newest like first,
/// none the caller already has) and where to go on. Only an empty
/// [nextPageToken] ends the list; [posts] can be empty before that.
@immutable
class LikesPage {
  const LikesPage({required this.posts, required this.nextPageToken});

  final List<posts_pb.PostView> posts;
  final String nextPageToken;

  bool get hasMore => nextPageToken.isNotEmpty;
}

/// The caller's own likes, most recent first (`ListLikedPosts`, ADR-0024 D6,
/// plan W3-18): the one caller of that RPC.
///
/// - **Session memory only.** Nothing is stored on the device: the list is
///   asked for again on every open (page 1 replaces what was there) and the
///   rows live in the screen's cubit. This class is the seam: a later
///   full-history source or an offline cache changes [fetchPage]'s body and
///   no caller.
/// - **Paging.** [fetchPage] follows `next_page_token` through pages that add
///   no new row (short and even empty pages with a token are normal), drops
///   rows the caller already has (by post id), and stops on a row, on the end
///   (empty token) or on a token that did not advance.
/// - **Flag.** The call goes through the [ServiceFeatureGate] of `likes_list`:
///   0 RPCs while it is off, and a FEATURE_DISABLED answer is remembered until
///   the next `GetMe`. UNIMPLEMENTED (the server skeleton) is treated like a
///   disabled flag for [kLikesUnavailableBackoff], without a report or a
///   `GetMe` refresh; [available] says whether the tab may be offered.
/// - **Rate limits.** The shared [RateLimitHold] (the per-uid read budget,
///   named limits) is checked before sending. The per-minute bucket of this
///   RPC (10 / min, no limit name) holds only this repository, so it never
///   freezes Home or Bookmarks.
/// - **Sign-out.** Works like `BookmarksRepository`: [clearSession] (or an
///   ended [SessionEpoch]) drops the session, a page that lands afterwards is
///   ignored ([fetchPage] returns null) and [sessionEnds] tells the open list.
///
/// A `VALIDATION field=page_token` answer (an expired or foreign token) is
/// thrown as is; the cubit drops the token and loads page 1 again.
class LikesRepository {
  LikesRepository({
    required ApiClient apiClient,
    required ServiceFeatureGate gate,
    required SessionEpoch epoch,
    void Function(Object error, StackTrace stack)? onUnexpectedError,
    RateLimitHold? rateLimitHold,
    DateTime Function()? now,
  }) : _apiClient = apiClient,
       _gate = gate,
       _epoch = epoch,
       _seenEpoch = epoch.value,
       _onUnexpectedError = onUnexpectedError,
       _hold = rateLimitHold ?? RateLimitHold(),
       _now = now ?? DateTime.now;

  final ApiClient _apiClient;
  final ServiceFeatureGate _gate;
  final SessionEpoch _epoch;
  final void Function(Object error, StackTrace stack)? _onUnexpectedError;
  final RateLimitHold _hold;
  final DateTime Function() _now;

  /// Holds back only this RPC's own per-minute bucket.
  final RateLimitHold _bucketHold = RateLimitHold();
  final StreamController<void> _sessionEnds = StreamController<void>.broadcast(
    sync: true,
  );
  int _seenEpoch;
  int _generation = 0;
  DateTime? _unavailableUntil;

  /// Whether the Likes tab may be offered right now: the flag is on for the
  /// caller, the server did not switch it off, and the RPC is not in its
  /// UNIMPLEMENTED backoff.
  bool get available => _gate.enabled && !_inBackoff;

  bool get _inBackoff {
    final until = _unavailableUntil;
    return until != null && _now().isBefore(until);
  }

  /// Fires when the session ended (sign-out): a screen holding rows drops
  /// them.
  Stream<void> get sessionEnds => _sessionEnds.stream;

  /// Counts the times the session was forgotten.
  int get sessionGeneration {
    _sync(notify: false);
    return _generation;
  }

  /// Sign-out: forget the session; a request still in flight is ignored when
  /// it lands.
  void clearSession() => _wipe();

  /// The next round of the list, after [after] (empty: the first page).
  /// [known] are the post ids the caller already shows: a row with one of
  /// those ids is dropped. Returns null, and keeps nothing, when the session
  /// ended while the request ran.
  Future<LikesPage?> fetchPage({
    String after = '',
    Set<String> known = const {},
    int pageSize = 20,
  }) async {
    _sync();
    final generation = _generation;
    final seen = {...known};
    final fresh = <posts_pb.PostView>[];
    var token = after;
    for (var call = 0; call < kLikesMaxCallsPerFetch; call++) {
      final response = await _list(token, pageSize);
      if (generation != _generation || _staleEpoch) return null;
      for (final view in response.posts) {
        final id = engagementTargetId(view.post);
        if (id.isEmpty || !seen.add(id)) continue;
        fresh.add(view);
      }
      final following = response.nextPageToken;
      if (fresh.isNotEmpty || following.isEmpty) {
        return LikesPage(posts: fresh, nextPageToken: following);
      }
      // A token that did not advance would loop for ever: it ends the list.
      if (following == token) {
        return const LikesPage(posts: [], nextPageToken: '');
      }
      token = following;
    }
    return LikesPage(posts: fresh, nextPageToken: token);
  }

  Future<pb.ListLikedPostsResponse> _list(String token, int pageSize) async {
    if (_inBackoff) throw _unavailable();
    final held = _hold.check() ?? _bucketHold.check();
    if (held != null) throw held;
    var unimplemented = false;
    try {
      return await _gate.run(() async {
        try {
          return await _apiClient.engagement.listLikedPosts(
            pb.ListLikedPostsRequest(pageSize: pageSize, pageToken: token),
          );
        } on connect.ConnectException catch (error) {
          unimplemented = error.code == connect.Code.unimplemented;
          rethrow;
        }
      });
    } on RateLimitedException catch (error) {
      // A named limit is the shared per-uid read budget: it holds every read
      // screen. No name: this RPC's own per-minute bucket.
      (error.limitName == null ? _bucketHold : _hold).record(error);
      rethrow;
    } on UnknownApiException catch (error, stack) {
      if (unimplemented) {
        _unavailableUntil = _now().add(kLikesUnavailableBackoff);
        throw _unavailable();
      }
      _onUnexpectedError?.call(error, stack);
      rethrow;
    }
  }

  FeatureDisabledException _unavailable() => const FeatureDisabledException(
    'This feature is not available.',
    feature: kFeatureLikesList,
  );

  bool get _staleEpoch => _epoch.value != _seenEpoch;

  void _sync({bool notify = true}) {
    if (_staleEpoch) _wipe(notify: notify);
  }

  void _wipe({bool notify = true}) {
    _seenEpoch = _epoch.value;
    _generation++;
    _unavailableUntil = null;
    _bucketHold.clear();
    if (notify && !_sessionEnds.isClosed) _sessionEnds.add(null);
  }

  Future<void> dispose() => _sessionEnds.close();
}
