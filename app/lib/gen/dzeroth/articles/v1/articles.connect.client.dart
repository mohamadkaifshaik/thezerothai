//
//  Generated code. Do not modify.
//  source: dzeroth/articles/v1/articles.proto
//

import "package:connectrpc/connect.dart" as connect;
import "articles.pb.dart" as dzerotharticlesv1articles;
import "articles.connect.spec.dart" as specs;

/// Article bodies are read separately from bounded timeline previews.
extension type ArticleServiceClient (connect.Transport _transport) {
  Future<dzerotharticlesv1articles.GetArticleResponse> getArticle(
    dzerotharticlesv1articles.GetArticleRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.ArticleService.getArticle,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  Future<dzerotharticlesv1articles.ListArticlesResponse> listArticles(
    dzerotharticlesv1articles.ListArticlesRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.ArticleService.listArticles,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  Future<dzerotharticlesv1articles.SaveArticleResponse> saveArticle(
    dzerotharticlesv1articles.SaveArticleRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.ArticleService.saveArticle,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  Future<dzerotharticlesv1articles.DeleteArticleResponse> deleteArticle(
    dzerotharticlesv1articles.DeleteArticleRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.ArticleService.deleteArticle,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  Future<dzerotharticlesv1articles.PublishArticleResponse> publishArticle(
    dzerotharticlesv1articles.PublishArticleRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.ArticleService.publishArticle,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }
}
