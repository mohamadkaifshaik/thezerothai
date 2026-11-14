//
//  Generated code. Do not modify.
//  source: dzeroth/articles/v1/articles.proto
//

import "package:connectrpc/connect.dart" as connect;
import "articles.pb.dart" as dzerotharticlesv1articles;

/// Article bodies are read separately from bounded timeline previews.
abstract final class ArticleService {
  /// Fully-qualified name of the ArticleService service.
  static const name = 'dzeroth.articles.v1.ArticleService';

  static const getArticle = connect.Spec(
    '/$name/GetArticle',
    connect.StreamType.unary,
    dzerotharticlesv1articles.GetArticleRequest.new,
    dzerotharticlesv1articles.GetArticleResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  static const listArticles = connect.Spec(
    '/$name/ListArticles',
    connect.StreamType.unary,
    dzerotharticlesv1articles.ListArticlesRequest.new,
    dzerotharticlesv1articles.ListArticlesResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// Creating a new draft id is refused at 50 unpublished drafts per author (a soft cap): FAILED_PRECONDITION +
  /// LIMIT_REACHED, metadata["limit"] = "article_drafts" and metadata["max"] = the cap as a decimal string. Editing an
  /// existing draft is never refused by the cap.
  static const saveArticle = connect.Spec(
    '/$name/SaveArticle',
    connect.StreamType.unary,
    dzerotharticlesv1articles.SaveArticleRequest.new,
    dzerotharticlesv1articles.SaveArticleResponse.new,
  );

  static const deleteArticle = connect.Spec(
    '/$name/DeleteArticle',
    connect.StreamType.unary,
    dzerotharticlesv1articles.DeleteArticleRequest.new,
    dzerotharticlesv1articles.DeleteArticleResponse.new,
  );

  static const publishArticle = connect.Spec(
    '/$name/PublishArticle',
    connect.StreamType.unary,
    dzerotharticlesv1articles.PublishArticleRequest.new,
    dzerotharticlesv1articles.PublishArticleResponse.new,
  );
}
