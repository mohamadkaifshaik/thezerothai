import 'dart:convert';

import 'package:connectrpc/connect.dart' as connect;
import 'package:fixnum/fixnum.dart';
import 'package:uuid/uuid.dart';

import '../../../core/network/api_client.dart';
import '../../../gen/dzeroth/articles/v1/articles.pb.dart' as pb;
import '../../posts/domain/posts_feature_flag.dart';
import '../../posts/domain/reply_audience.dart';
import '../../timeline/data/timeline_store.dart';
import '../../timeline/domain/feed_key.dart';
import '../domain/article.dart';
import '../domain/articles_repository.dart';

class RpcArticlesRepository implements ArticlesRepository {
  RpcArticlesRepository({
    required ApiClient apiClient,
    required TimelineStore store,
    required PostsFeatureGate gate,
    required String? Function() currentUid,
    required bool Function() isReplyAudienceEnabled,
  }) : _api = apiClient,
       _store = store,
       _gate = gate,
       _uid = currentUid,
       _replyAudienceFlag = isReplyAudienceEnabled;
  final ApiClient _api;
  final TimelineStore _store;
  final PostsFeatureGate _gate;
  final String? Function() _uid;

  /// Whether `GetMe.enabled_features` lists [kFeatureReplyAudience].
  final bool Function() _replyAudienceFlag;

  @override
  bool get canChooseReplyAudience =>
      _replyAudienceFlag() && _gate.subFeatureEnabled(kFeatureReplyAudience);

  Future<T> _run<T>(Future<T> Function() call) async {
    final uid = _uid();
    final epoch = _store.session;
    if (uid == null || uid.isEmpty) throw StateError('Sign in required');
    final value = await _gate.run(call);
    if (_uid() != uid || _store.session != epoch) {
      throw StateError('Account changed');
    }
    return value;
  }

  @override
  Future<ArticleRecord> create() async {
    final uid = _uid();
    if (uid == null) throw StateError('Sign in required');
    return save(
      ArticleDraft(id: const Uuid().v4(), authorId: uid),
      expectedRevision: 0,
    );
  }

  @override
  Future<ArticleRecord> get(String id) async {
    final response = await _run(
      () => _api.articles.getArticle(pb.GetArticleRequest(articleId: id)),
    );
    final record = _from(response.article);
    final author = response.post.post.author;
    return ArticleRecord(
      draft: record.draft,
      updatedAt: record.updatedAt,
      postId: record.postId,
      coverUrl: record.coverUrl,
      authorName: author.displayName,
      authorHandle: author.handle,
      authorAvatar: author.avatarUrl,
      publicationPending: record.publicationPending,
      publicationCaption: record.publicationCaption,
      publicationReplyPolicy: record.publicationReplyPolicy,
      excerpt: record.excerpt,
      images: record.images,
    );
  }

  @override
  Future<ArticlePage> list({
    required bool published,
    String pageToken = '',
  }) async {
    final response = await _run(
      () => _api.articles.listArticles(
        pb.ListArticlesRequest(
          published: published,
          pageSize: 30,
          pageToken: pageToken,
        ),
      ),
    );
    // List rows carry the server excerpt and no body: opening one reads the
    // full article through get().
    return ArticlePage(
      response.articles.map((a) => _from(a, withBody: false)).toList(),
      nextPageToken: response.nextPageToken,
    );
  }

  @override
  Future<ArticleRecord> save(
    ArticleDraft draft, {
    required int expectedRevision,
  }) async {
    var conflict = false;
    final pb.SaveArticleResponse response;
    try {
      response = await _run(() async {
        try {
          return await _api.articles.saveArticle(
            pb.SaveArticleRequest(
              article: pb.Article(
                articleId: draft.id,
                authorId: draft.authorId,
                revision: Int64(draft.revision),
                title: draft.title,
                bodyJson: draft.bodyJson,
                coverMediaId: draft.coverMediaId ?? '',
              ),
              expectedRevision: Int64(expectedRevision),
            ),
          );
        } on connect.ConnectException catch (error) {
          // The revision CAS failed: the caller must reconcile, not retry.
          // Throw a non-Connect sentinel so the gate does not report an
          // expected conflict as an unexpected API error.
          if (error.code != connect.Code.aborted) rethrow;
          conflict = true;
          throw const ArticleRevisionConflict();
        }
      });
    } catch (_) {
      // _gate.run (guardApiCall) maps every non-AppException, the sentinel
      // included, to a NetworkException, so the flag carries the conflict out.
      if (conflict) throw const ArticleRevisionConflict();
      rethrow;
    }
    return _from(response.article);
  }

  @override
  Future<void> delete(ArticleRecord article) async {
    await _run(
      () => _api.articles.deleteArticle(
        pb.DeleteArticleRequest(
          articleId: article.draft.id,
          expectedRevision: Int64(article.draft.revision),
        ),
      ),
    );
    if (article.postId.isNotEmpty) await _store.removePost(article.postId);
  }

  @override
  Future<ArticleRecord> publish(
    ArticleRecord article, {
    required String idempotencyKey,
    String caption = '',
    ReplyAudience replyAudience = ReplyAudience.everyone,
  }) async {
    final epoch = _store.session;
    // A pending publication repeats the exact stored value (the server
    // compares it raw on a retry under the pending key). Otherwise the choice
    // maps like the composer's: Everyone is UNSPECIFIED, which posts.Create
    // accepts with reply_audience off; any explicit value, EVERYONE included,
    // is FEATURE_DISABLED then. No local refusal for a known-off flag: the
    // server must see a pending retry to clear it.
    final replyPolicy = article.publicationPending
        ? article.publicationReplyPolicy
        : replyAudience.wire;
    final response = await _run(
      () => _api.articles.publishArticle(
        pb.PublishArticleRequest(
          articleId: article.draft.id,
          expectedRevision: Int64(article.draft.revision),
          idempotencyKey: idempotencyKey,
          caption: caption,
          replyPolicy: replyPolicy,
        ),
      ),
    );
    if (response.hasPost()) {
      final uid = response.post.post.author.userId;
      await _store.insertOwnPost(
        response.post,
        session: epoch,
        feeds: [
          const FeedKey.home(),
          FeedKey.user(uid),
          FeedKey.user(uid, includeReplies: true),
          FeedKey.user(uid, tab: UserFeedTab.articles),
        ],
      );
    }
    return _from(response.article);
  }

  ArticleRecord _from(pb.Article article, {bool withBody = true}) {
    final body = withBody
        ? jsonDecode(article.bodyJson.isEmpty ? '[]' : article.bodyJson)
        : const <Object?>[];
    if (body is! List) throw const FormatException('Invalid article body');
    return ArticleRecord(
      draft: ArticleDraft(
        id: article.articleId,
        authorId: article.authorId,
        revision: article.revision.toInt(),
        title: article.title,
        coverMediaId: article.coverMediaId.isEmpty
            ? null
            : article.coverMediaId,
        blocks: body.map(ArticleBlock.fromJson),
      ),
      updatedAt: article.updatedAt.toDateTime(),
      postId: article.postId,
      coverUrl: article.coverUrl,
      publicationPending: article.publicationPending,
      publicationCaption: article.publicationCaption,
      publicationReplyPolicy: article.publicationReplyPolicy,
      excerpt: article.excerpt,
      images: {for (final ref in article.images) ref.mediaId: ref},
    );
  }
}
