import 'article.dart';

class ArticleRecord {
  const ArticleRecord({
    required this.draft,
    required this.updatedAt,
    this.postId = '',
    this.coverUrl = '',
    this.authorName = '',
    this.authorHandle = '',
    this.authorAvatar = '',
    this.publicationPending = false,
    this.publicationCaption = '',
    this.publicationReplyPolicy = 'everyone',
    this.excerpt = '',
  });
  final ArticleDraft draft;
  final DateTime updatedAt;
  final String postId;
  final String coverUrl;
  final String authorName;
  final String authorHandle;
  final String authorAvatar;
  final bool publicationPending;
  final String publicationCaption;
  final String publicationReplyPolicy;

  /// Server-computed plain-text excerpt. List rows carry only this (their
  /// draft has no blocks); open the article with get() to read the body.
  final String excerpt;
  bool get published => postId.isNotEmpty;

  /// The list summary: the server excerpt, or one derived from loaded blocks.
  String get summary => excerpt.isNotEmpty ? excerpt : draft.excerpt();
}

class ArticlePage {
  const ArticlePage(this.articles, {this.nextPageToken = ''});
  final List<ArticleRecord> articles;
  final String nextPageToken;
}

/// Every write is acknowledged by the service before the UI says it is saved.
abstract class ArticlesRepository {
  Future<ArticleRecord> create();
  Future<ArticleRecord> get(String id);
  Future<ArticlePage> list({required bool published, String pageToken = ''});
  Future<ArticleRecord> save(
    ArticleDraft draft, {
    required int expectedRevision,
  });
  Future<void> delete(ArticleRecord article);
  Future<ArticleRecord> publish(
    ArticleRecord article, {
    required String idempotencyKey,
    String caption = '',
    String replyPolicy = 'everyone',
  });
}
