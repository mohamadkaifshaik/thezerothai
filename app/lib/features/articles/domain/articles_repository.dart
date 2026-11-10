import '../../../gen/dzeroth/posts/v1/posts.pbenum.dart' show ReplyPolicy;
import '../../posts/domain/reply_audience.dart';
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
    this.publicationReplyPolicy = ReplyPolicy.REPLY_POLICY_UNSPECIFIED,
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

  /// The reply policy stored with a pending (or refused) publication, exactly
  /// as the server holds it: a retry under the pending key must repeat it
  /// (the server compares the raw value, so UNSPECIFIED and EVERYONE differ).
  final ReplyPolicy publicationReplyPolicy;

  /// [publicationReplyPolicy] as a publish-dialog choice.
  ReplyAudience get publicationReplyAudience =>
      ReplyAudience.fromWire(publicationReplyPolicy);

  /// Server-computed plain-text excerpt. List rows carry only this (their
  /// draft has no blocks); open the article with get() to read the body.
  final String excerpt;
  bool get published => postId.isNotEmpty;

  /// This record once the server refused its pending publication
  /// definitively (which clears the pending key): the same article, no
  /// longer pending, its stored caption and policy kept.
  ArticleRecord withPublicationRefused() => ArticleRecord(
    draft: draft,
    updatedAt: updatedAt,
    postId: postId,
    coverUrl: coverUrl,
    authorName: authorName,
    authorHandle: authorHandle,
    authorAvatar: authorAvatar,
    publicationCaption: publicationCaption,
    publicationReplyPolicy: publicationReplyPolicy,
    excerpt: excerpt,
  );

  /// The list summary: the server excerpt, or one derived from loaded blocks.
  String get summary => excerpt.isNotEmpty ? excerpt : draft.excerpt();
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
  /// Whether the publish dialog may offer a narrower reply audience: the
  /// viewer's `enabled_features` lists `reply_audience` and no FEATURE_DISABLED
  /// answer for it arrived since the last `GetMe`. Otherwise only Everyone.
  bool get canChooseReplyAudience;
  Future<ArticleRecord> create();
  Future<ArticleRecord> get(String id);
  Future<ArticlePage> list({required bool published, String pageToken = ''});
  Future<ArticleRecord> save(
    ArticleDraft draft, {
    required int expectedRevision,
  });
  Future<void> delete(ArticleRecord article);

  /// Publishes [article]. [replyAudience] goes out as [ReplyAudience.wire]
  /// (Everyone is UNSPECIFIED, which the server takes with `reply_audience`
  /// on or off).
  ///
  /// While [article] is `publicationPending`, [replyAudience] is ignored: the
  /// stored [ArticleRecord.publicationReplyPolicy] is sent exactly, so a retry
  /// under the pending key is never refused as locked because the capability
  /// changed since the first attempt.
  Future<ArticleRecord> publish(
    ArticleRecord article, {
    required String idempotencyKey,
    String caption = '',
    ReplyAudience replyAudience = ReplyAudience.everyone,
  });
}
