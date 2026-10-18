import '../../../core/feature_flags/service_feature_gate.dart';
import '../../../core/network/api_client.dart';
import '../../../gen/dzeroth/engagement/v1/engagement.pb.dart' as pb;
import '../../timeline/data/timeline_store.dart';

/// Talks to `EngagementService` (like, unlike, repost, undo repost;
/// ADR-0018) behind the `engagement` flag.
///
/// - Every call goes through the [ServiceFeatureGate]: with the flag off no
///   RPC is sent (0 reads), and a FEATURE_DISABLED answer is remembered until
///   the next `GetMe`. Errors are typed ([guardApiCall]); nothing here
///   retries: the four RPCs are not marked side-effect-free, so the
///   transport never resends them, and only `EngagementCubit` may resend
///   (latest intent wins, ADR-0018 "Rule 4").
/// - The RPCs are state-setting and keyed by (post, caller) on the server, so
///   [idempotencyKey] is validated for format only; callers still reuse one
///   key per user intent.
/// - A success is written into the cached feed rows of that post (drift) so a
///   restart still shows the caller's own like/repost; a failing cache write
///   never turns a server success into an error.
///
/// `postId` is always the target: the original for a REPOST row.
class EngagementRepository {
  EngagementRepository({
    required ApiClient apiClient,
    required ServiceFeatureGate gate,
    TimelineStore? store,
  }) : _apiClient = apiClient,
       _gate = gate,
       _store = store;

  final ApiClient _apiClient;
  final ServiceFeatureGate _gate;
  final TimelineStore? _store;

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
