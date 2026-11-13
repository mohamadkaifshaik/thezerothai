import 'dart:convert';

import 'package:connectrpc/connect.dart' as connect;
import 'package:crypto/crypto.dart';
import 'package:dzeroth/features/posts/domain/reply_audience.dart';
import 'package:dzeroth/gen/dzeroth/articles/v1/articles.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart';
import 'package:fixnum/fixnum.dart';

import 'posts_fixtures.dart';

/// The publication key the articles editor derives for one revision.
String articlePublishKey(String authorId, String articleId, int revision) =>
    sha256
        .convert(utf8.encode('$authorId:$articleId:$revision:publish'))
        .toString();

/// One article as the backend articles service holds it, answering GetArticle
/// and PublishArticle through a `FakeTransport` (route [handle]).
///
/// PublishArticle follows backend/internal/articles/service.go and
/// posts/service_create.go:
/// - a pending publication (or a published article) is locked: a retry must
///   carry the pending key, caption and reply policy exactly (raw values, so
///   UNSPECIFIED and EVERYONE differ), or FAILED_PRECONDITION;
/// - posts.Create refuses any reply_policy but UNSPECIFIED with
///   FEATURE_DISABLED `reply_audience` while [replyAudienceOn] is false, a
///   definitive rejection that clears the pending key (the stored caption and
///   policy stay, as on the server).
class FakeArticlesServer {
  FakeArticlesServer({
    this.articleId = 'draft',
    this.authorId = 'owner',
    this.revision = 0,
    this.title = 'Title',
    this.body = 'Body',
  });

  final String articleId;
  final String authorId;
  final int revision;
  final String title;
  final String body;

  bool replyAudienceOn = false;

  /// The reply policy of every PublishArticle received, in order.
  final sent = <ReplyPolicy>[];

  String pendingKey = '';
  String caption = '';
  ReplyPolicy replyPolicy = ReplyPolicy.REPLY_POLICY_UNSPECIFIED;
  bool published = false;

  /// Store the pending key, then lose the reply (UNAVAILABLE) once.
  bool loseNextReply = false;

  /// When set, GetArticle fails with it (a refresh that cannot reach us).
  Object? getError;

  /// Leaves a publication pending, as an earlier attempt under the editor's
  /// key would have.
  void leavePending(ReplyPolicy policy, {String caption = ''}) {
    pendingKey = articlePublishKey(authorId, articleId, revision);
    this.caption = caption;
    replyPolicy = policy;
  }

  pb.Article get article => pb.Article(
    articleId: articleId,
    authorId: authorId,
    revision: Int64(revision),
    title: title,
    bodyJson: jsonEncode([
      {
        'kind': 'paragraph',
        'runs': [
          {'text': body, 'marks': <String>[]},
        ],
      },
    ]),
    postId: published ? 'post-1' : '',
    publicationPending: pendingKey.isNotEmpty && !published,
    publicationCaption: caption,
    publicationReplyPolicy: replyPolicy,
  );

  Future<Object> handle(String procedure, Object input) async {
    if (input is pb.GetArticleRequest) {
      if (getError case final error?) throw error;
      return pb.GetArticleResponse(article: article);
    }
    return _publish(input as pb.PublishArticleRequest);
  }

  pb.PublishArticleResponse _publish(pb.PublishArticleRequest request) {
    sent.add(request.replyPolicy);
    final locked = pendingKey.isNotEmpty
        ? pendingKey != request.idempotencyKey ||
              caption != request.caption ||
              replyPolicy != request.replyPolicy
        : published;
    if (locked) {
      throw connect.ConnectException(
        connect.Code.failedPrecondition,
        'article publication is in progress or complete',
      );
    }
    if (pendingKey.isEmpty) {
      pendingKey = request.idempotencyKey;
      caption = request.caption;
      replyPolicy = request.replyPolicy;
    }
    if (loseNextReply) {
      loseNextReply = false;
      throw connect.ConnectException(connect.Code.unavailable, 'lost');
    }
    if (replyPolicy != ReplyPolicy.REPLY_POLICY_UNSPECIFIED &&
        !replyAudienceOn) {
      pendingKey = '';
      throw serverError(
        connect.Code.failedPrecondition,
        common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
        metadata: {'feature': kFeatureReplyAudience},
      );
    }
    pendingKey = '';
    published = true;
    return pb.PublishArticleResponse(article: article);
  }
}
