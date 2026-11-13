import 'package:uuid/uuid.dart';

import '../../../core/feature_flags/service_feature_gate.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/app_exception.dart';
import '../../../gen/dzeroth/engagement/v1/engagement.pb.dart' as pb;
import '../../../gen/dzeroth/engagement/v1/engagement.pbenum.dart'
    show ShareChannel;
import '../../timeline/data/timeline_store.dart';

/// Talks to `EngagementService` (like, unlike, repost, undo repost) behind the
/// `engagement` flag.
///
/// - Every call goes through the [ServiceFeatureGate]: with the flag off no
///   RPC is sent (0 reads), and a FEATURE_DISABLED answer is remembered until
///   the next `GetMe`. Errors are typed ([guardApiCall]); nothing here
///   retries: the four RPCs are not marked side-effect-free, so the
///   transport never resends them, and only `EngagementCubit` may resend
///   (latest intent wins).
/// - The RPCs are state-setting and keyed by (post, caller) on the server, so
///   [idempotencyKey] is validated for format only; callers still reuse one
///   key per user intent.
/// - A success is written into the cached feed rows of that post (drift) so a
///   restart still shows the caller's own like/repost; a failing cache write
///   never turns a server success into an error.
///
/// [recordPostShare] reports a share made outside the app and rides its own
/// gate ([shareGate], the `share_count` flag): a refusal of that call never
/// switches off likes or reposts, and the other way round.
///
/// `postId` is always the target: the original for a REPOST row.
class EngagementRepository {
  EngagementRepository({
    required ApiClient apiClient,
    required ServiceFeatureGate gate,
    ServiceFeatureGate? shareGate,
    TimelineStore? store,
    Uuid? uuid,
  }) : _apiClient = apiClient,
       _gate = gate,
       _shareGate = shareGate,
       _store = store,
       _uuid = uuid ?? const Uuid();

  final ApiClient _apiClient;
  final ServiceFeatureGate _gate;
  final ServiceFeatureGate? _shareGate;
  final TimelineStore? _store;
  final Uuid _uuid;

  /// Posts whose outside share this session already reported (the server
  /// counts one account once per post, so a second report can only be a
  /// wasted request), and those being reported now.
  final Set<String> _reportedShares = {};
  final Set<String> _sharesInFlight = {};
  int _shareSession = 0;

  /// Sign-out: forgets which shares were reported, and drops answers still in
  /// flight.
  void clearShareSession() {
    _shareSession++;
    _reportedShares.clear();
    _sharesInFlight.clear();
  }

  /// Reports that the caller shared [postId] outside the app ("Copy link"
  /// succeeded, or the share sheet reported a completed share): one
  /// `RecordPostShare`, once per post per session. Returns the post's
  /// engagement (its `share_count`) as the server now sees it, or null when
  /// nothing was reported or learned: the flag is off for the caller, the post
  /// was already reported, a report is in flight, or the call failed.
  ///
  /// Fire and forget: it never throws and is never retried (the share itself
  /// already happened). A failed call is forgotten, so a later share of the
  /// same post may report again. Callers must call it only after the copy or
  /// share really succeeded.
  Future<pb.PostEngagement?> recordPostShare({
    required String postId,
    required ShareChannel channel,
  }) async {
    final gate = _shareGate;
    if (postId.isEmpty || gate == null || !gate.enabled) return null;
    if (_reportedShares.contains(postId) || !_sharesInFlight.add(postId)) {
      return null;
    }
    final session = _shareSession;
    try {
      final response = await gate.run(
        () => _apiClient.engagement.recordPostShare(
          pb.RecordPostShareRequest(
            idempotencyKey: _uuid.v4(),
            postId: postId,
            channel: channel,
          ),
        ),
      );
      if (session != _shareSession) return null;
      _reportedShares.add(postId);
      return response.engagement;
    } on AppException {
      // Silent by design: the share happened, the count is only a tally.
      return null;
    } catch (_) {
      return null;
    } finally {
      if (session == _shareSession) _sharesInFlight.remove(postId);
    }
  }

  /// Whether engagement RPCs may be sent at all right now.
  bool get enabled => _gate.enabled;

  Future<pb.PostEngagement> like({
    required String postId,
    required String idempotencyKey,
  }) => _send(
    postId,
    () => _apiClient.engagement.likePost(
      pb.LikePostRequest(idempotencyKey: idempotencyKey, postId: postId),
    ),
    (response) => response.engagement,
    likes: true,
  );

  Future<pb.PostEngagement> unlike({
    required String postId,
    required String idempotencyKey,
  }) => _send(
    postId,
    () => _apiClient.engagement.unlikePost(
      pb.UnlikePostRequest(idempotencyKey: idempotencyKey, postId: postId),
    ),
    (response) => response.engagement,
    likes: true,
  );

  Future<pb.PostEngagement> repost({
    required String postId,
    required String idempotencyKey,
  }) => _send(
    postId,
    () => _apiClient.engagement.repostPost(
      pb.RepostPostRequest(idempotencyKey: idempotencyKey, postId: postId),
    ),
    (response) => response.engagement,
    likes: false,
  );

  Future<pb.PostEngagement> undoRepost({
    required String postId,
    required String idempotencyKey,
  }) => _send(
    postId,
    () => _apiClient.engagement.undoRepost(
      pb.UndoRepostRequest(idempotencyKey: idempotencyKey, postId: postId),
    ),
    (response) => response.engagement,
    likes: false,
  );

  Future<pb.PostEngagement> _send<R>(
    String postId,
    Future<R> Function() call,
    pb.PostEngagement Function(R response) unwrap, {
    required bool likes,
  }) async {
    final session = _store?.session;
    final result = unwrap(await _gate.run(call));
    await _remember(postId, result, session, likes: likes);
    return result;
  }

  Future<void> _remember(
    String postId,
    pb.PostEngagement result,
    int? session, {
    required bool likes,
  }) async {
    final store = _store;
    if (store == null || session == null) return;
    try {
      await store.patchEngagement(
        postId: postId,
        session: session,
        liked: likes ? result.likedByViewer : null,
        likeCount: likes ? result.likeCount.toInt() : null,
        reposted: likes ? null : result.repostedByViewer,
        repostCount: likes ? null : result.repostCount.toInt(),
      );
    } catch (_) {
      // Best effort: the server already applied the change.
    }
  }
}
