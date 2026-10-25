import 'dart:async';

import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/app_exception.dart';
import '../../../core/network/rate_limit_hold.dart';
import '../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../../gen/dzeroth/posts/v1/posts.pbenum.dart' show ReplyPolicy;
import '../../timeline/data/timeline_store.dart';
import '../../timeline/domain/feed_key.dart';
import '../domain/posts_feature_flag.dart';
import '../domain/reply_audience.dart';

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
    RateLimitHold? rateLimitHold,
  }) : _apiClient = apiClient,
       _store = store,
       _gate = gate,
       _hold = rateLimitHold ?? RateLimitHold();

  final ApiClient _apiClient;
  final TimelineStore _store;
  final PostsFeatureGate _gate;

  /// The RATE_LIMITED hold shared with the timeline: reads send nothing
  /// while it runs (ADR-0010 D5).
  final RateLimitHold _hold;

  final StreamController<String> _removed = StreamController.broadcast();

  /// Ids of posts that left every cached feed (deleted by the caller, or
  /// NOT_FOUND on open). A screen that is still mounted under another one
  /// (Home under a profile or a post) hides them at once, with no refetch.
  Stream<String> get removedPosts => _removed.stream;

  /// Whether the posts sub-feature [name] (`replies`, `quotes`, `media`) is
  /// usable right now (the coarse flag is on and no FEATURE_DISABLED answer
  /// has hidden it). Lets the composer skip uploads a CreatePost would
  /// refuse.
  bool subFeatureEnabled(String name) => _gate.subFeatureEnabled(name);

  /// Creates a post. [idempotencyKey] must be reused when retrying the same
  /// post (the server replays the stored result). [replyPolicy] stays
  /// UNSPECIFIED (everyone) unless the user chose a narrower audience for a
  /// root post or quote (ADR-0021 D2); never set it on a reply.
  Future<pb.PostView> createPost({
    required String idempotencyKey,
    required String text,
    String replyToPostId = '',
    String quoteOfPostId = '',
    List<String> mediaIds = const [],
    List<String> mediaAltTexts = const [],
    ReplyPolicy replyPolicy = ReplyPolicy.REPLY_POLICY_UNSPECIFIED,
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
          replyPolicy: replyPolicy,
        ),
      ),
      requires: [
        if (replyToPostId.isNotEmpty) kPostsSubFeatureReplies,
        if (quoteOfPostId.isNotEmpty) kPostsSubFeatureQuotes,
        if (mediaIds.isNotEmpty) kPostsSubFeatureMedia,
        // Only a chosen audience needs the flag; UNSPECIFIED never does.
        if (replyPolicy != ReplyPolicy.REPLY_POLICY_UNSPECIFIED)
          kFeatureReplyAudience,
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

  /// Schedules a new root post (`SchedulePost`, ADR-0021 D4). [idempotencyKey]
  /// must be reused for every retry of the same request (the server answers a
  /// lost response with the stored item) and replaced when the text, media,
  /// audience or [publishAt] changed. [publishAt] goes out as UTC; the server
  /// truncates it to the minute and the returned item carries the time it
  /// stored, which is the one to show. Nothing is inserted into any feed: the
  /// post exists only once the server publishes it.
  ///
  /// Never sends reply, quote or poll fields (the request has none). Like
  /// [createPost] it is not sent while a sub-feature it needs is known to be
  /// off (`scheduled_posts`, `media`, `reply_audience`).
  Future<pb.ScheduledPost> schedulePost({
    required String idempotencyKey,
    required String text,
    required DateTime publishAt,
    List<String> mediaIds = const [],
    List<String> mediaAltTexts = const [],
    ReplyPolicy replyPolicy = ReplyPolicy.REPLY_POLICY_UNSPECIFIED,
  }) async {
    final response = await _gate.run(
      () => _apiClient.posts.schedulePost(
        pb.SchedulePostRequest(
          idempotencyKey: idempotencyKey,
          text: text,
          mediaIds: mediaIds,
          mediaAltTexts: mediaAltTexts,
          replyPolicy: replyPolicy,
          publishAt: Timestamp.fromDateTime(publishAt.toUtc()),
        ),
      ),
      requires: [
        kFeatureScheduledPosts,
        if (mediaIds.isNotEmpty) kPostsSubFeatureMedia,
        if (replyPolicy != ReplyPolicy.REPLY_POLICY_UNSPECIFIED)
          kFeatureReplyAudience,
      ],
    );
    return response.scheduledPost;
  }

  /// One page of the caller's PENDING and FAILED scheduled posts, oldest
  /// publish time first (`ListScheduledPosts`: 1 + page Firestore reads).
  /// Pass the previous page's `next_page_token` for the next one. Needs only
  /// the posts flag: a caller outside the scheduling rollout can still list
  /// what they scheduled.
  Future<pb.ListScheduledPostsResponse> listScheduledPosts({
    String pageToken = '',
    int pageSize = 20,
  }) {
    return _guardedRead(
      () => _gate.run(
        () => _apiClient.posts.listScheduledPosts(
          pb.ListScheduledPostsRequest(
            pageSize: pageSize,
            pageToken: pageToken,
          ),
        ),
      ),
    );
  }

  /// Cancels a PENDING scheduled post, or dismisses a FAILED one
  /// (`CancelScheduledPost`). Returns the item's current state: PUBLISHED
  /// means it was too late to cancel (not an error). The server only
  /// format-validates [idempotencyKey]; pass a fresh one per tap. NOT_FOUND
  /// ([NotFoundException]) means the item is gone already (cleaned up after
  /// 7 days).
  Future<pb.ScheduledPost> cancelScheduledPost({
    required String scheduledId,
    required String idempotencyKey,
  }) async {
    final response = await _gate.run(
      () => _apiClient.posts.cancelScheduledPost(
        pb.CancelScheduledPostRequest(
          idempotencyKey: idempotencyKey,
          scheduledId: scheduledId,
        ),
      ),
    );
    return response.scheduledPost;
  }

  /// Runs a read RPC unless a RATE_LIMITED answer is still held (the held
  /// exception is thrown without sending), and records a new one.
  Future<T> _guardedRead<T>(Future<T> Function() send) async {
    final held = _hold.check();
    if (held != null) throw held;
    try {
      return await send();
    } on RateLimitedException catch (error) {
      _hold.record(error);
      rethrow;
    }
  }

  /// One post. NOT_FOUND (missing, deleted, or hidden by a block) prunes it
  /// from every cached feed and is rethrown as [NotFoundException].
  Future<pb.PostView> getPost(String postId) async {
    try {
      final response = await _guardedRead(
        () => _gate.run(
          () => _apiClient.posts.getPost(pb.GetPostRequest(postId: postId)),
        ),
      );
      return response.post;
    } on NotFoundException {
      await _store.removePost(postId);
      _removed.add(postId);
      rethrow;
    }
  }

  /// One conversation page (`GetThread`, FEATURE_REPLIES): the focal post,
  /// its parent/root context (or tombstone flags) and a page of replies.
  /// Pass the previous response's `next_page_token` for the next page.
  ///
  /// With the `replies` sub-feature off no RPC is sent
  /// ([FeatureDisabledException], `feature: replies`). NOT_FOUND is the focal
  /// post itself being missing or hidden: pruned from every feed, rethrown.
  Future<pb.GetThreadResponse> getThread(
    String postId, {
    String pageToken = '',
    int pageSize = 0,
  }) async {
    try {
      return await _guardedRead(
        () => _gate.run(
          () => _apiClient.posts.getThread(
            pb.GetThreadRequest(
              postId: postId,
              pageToken: pageToken,
              pageSize: pageSize,
            ),
          ),
          requires: const [kPostsSubFeatureReplies],
        ),
      );
    } on NotFoundException {
      await _store.removePost(postId);
      _removed.add(postId);
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
    _removed.add(postId);
  }
}
