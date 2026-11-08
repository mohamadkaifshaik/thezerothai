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
  bool get published => postId.isNotEmpty;
}

class ArticlePage {
  const ArticlePage(this.articles, {this.nextPageToken = ''});
  final List<ArticleRecord> articles;
  final String nextPageToken;
}

/// A save whose expected revision is no longer the server's (ABORTED): the
/// article changed elsewhere, or an earlier save committed but its reply was
/// lost. The caller reloads and decides; nothing was written.
class ArticleRevisionConflict implements Exception {
  const ArticleRevisionConflict();

  @override
  String toString() => 'ArticleRevisionConflict';
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
