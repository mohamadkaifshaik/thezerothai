import '../../../core/network/api_client.dart';
import '../../../core/network/app_exception.dart';
import '../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../timeline/data/timeline_store.dart';
import '../../timeline/domain/feed_key.dart';
import '../domain/posts_feature_flag.dart';

/// Talks to `PostService` (create, delete, get one post) and keeps the
/// cached feeds ([TimelineStore]) consistent with what it learns.
///
/// - Every call goes through [PostsFeatureGate.run]: with the posts flag off
///   no RPC is sent, and a CreatePost that needs a sub-feature known to be
///   off (`replies`, `quotes`, `media`) is not sent either (ADR-0010 D2).
/// - A post that is NOT_FOUND on open, or that the caller deletes, is removed
///   from every cached feed.
/// - A created post is put at the top of the caller's already-loaded feeds
///   (home and the author's own Posts/Replies tabs) so it shows at once.
class PostsRepository {
  PostsRepository({
    required ApiClient apiClient,
    required TimelineStore store,
    required PostsFeatureGate gate,
  }) : _apiClient = apiClient,
       _store = store,
       _gate = gate;

  final ApiClient _apiClient;
  final TimelineStore _store;
  final PostsFeatureGate _gate;

  /// Creates a post. [idempotencyKey] must be reused when retrying the same
  /// post (the server replays the stored result).
  Future<pb.PostView> createPost({
    required String idempotencyKey,
    required String text,
    String replyToPostId = '',
    String quoteOfPostId = '',
    List<String> mediaIds = const [],
    List<String> mediaAltTexts = const [],
  }) async {
    final session = _store.session;
    final response = await _gate.run(
      () => _apiClient.posts.createPost(
        pb.CreatePostRequest(
          idempotencyKey: idempotencyKey,
          text: text,
          replyToPostId: replyToPostId,
          quoteOfPostId: quoteOfPostId,
          mediaIds: mediaIds,
          mediaAltTexts: mediaAltTexts,
        ),
      ),
      requires: [
        if (replyToPostId.isNotEmpty) kPostsSubFeatureReplies,
        if (quoteOfPostId.isNotEmpty) kPostsSubFeatureQuotes,
        if (mediaIds.isNotEmpty) kPostsSubFeatureMedia,
      ],
    );
    final view = response.post;
    final authorId = view.post.author.userId;
    // Replies never appear in Home or the Posts tab; skip until a replies
    // slice decides how to show them.
    if (view.post.replyToPostId.isNotEmpty) return view;
    await _store.insertOwnPost(
      view,
      session: session,
      feeds: [
        const FeedKey.home(),
        if (authorId.isNotEmpty) ...[
          FeedKey.user(authorId),
          FeedKey.user(authorId, includeReplies: true),
        ],
      ],
    );
    return view;
  }

  /// One post. NOT_FOUND (missing, deleted, or hidden by a block) prunes it
  /// from every cached feed and is rethrown as [NotFoundException].
  Future<pb.PostView> getPost(String postId) async {
    try {
      final response = await _gate.run(
        () => _apiClient.posts.getPost(pb.GetPostRequest(postId: postId)),
      );
      return response.post;
    } on NotFoundException {
      await _store.removePost(postId);
      rethrow;
    }
  }

  /// Deletes the caller's post. The server answers success for an unknown
  /// or foreign id too (ADR-0010 D4), so success always means "it is gone":
  /// the post leaves every cached feed.
  Future<void> deletePost({
    required String postId,
    required String idempotencyKey,
  }) async {
    await _gate.run(
      () => _apiClient.posts.deletePost(
        pb.DeletePostRequest(idempotencyKey: idempotencyKey, postId: postId),
      ),
    );
    await _store.removePost(postId);
  }
}
