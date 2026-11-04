// This is a generated file - do not edit.
//
// Generated from dzeroth/articles/v1/articles.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:async' as $async;
import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

import 'articles.pb.dart' as $3;
import 'articles.pbjson.dart';

export 'articles.pb.dart';

abstract class ArticleServiceBase extends $pb.GeneratedService {
  $async.Future<$3.GetArticleResponse> getArticle(
      $pb.ServerContext ctx, $3.GetArticleRequest request);
  $async.Future<$3.ListArticlesResponse> listArticles(
      $pb.ServerContext ctx, $3.ListArticlesRequest request);
  $async.Future<$3.SaveArticleResponse> saveArticle(
      $pb.ServerContext ctx, $3.SaveArticleRequest request);
  $async.Future<$3.DeleteArticleResponse> deleteArticle(
      $pb.ServerContext ctx, $3.DeleteArticleRequest request);
  $async.Future<$3.PublishArticleResponse> publishArticle(
      $pb.ServerContext ctx, $3.PublishArticleRequest request);

  $pb.GeneratedMessage createRequest($core.String methodName) {
    switch (methodName) {
      case 'GetArticle':
        return $3.GetArticleRequest();
      case 'ListArticles':
        return $3.ListArticlesRequest();
      case 'SaveArticle':
        return $3.SaveArticleRequest();
      case 'DeleteArticle':
        return $3.DeleteArticleRequest();
      case 'PublishArticle':
        return $3.PublishArticleRequest();
      default:
        throw $core.ArgumentError('Unknown method: $methodName');
    }
  }

  $async.Future<$pb.GeneratedMessage> handleCall($pb.ServerContext ctx,
      $core.String methodName, $pb.GeneratedMessage request) {
    switch (methodName) {
      case 'GetArticle':
        return getArticle(ctx, request as $3.GetArticleRequest);
      case 'ListArticles':
        return listArticles(ctx, request as $3.ListArticlesRequest);
      case 'SaveArticle':
        return saveArticle(ctx, request as $3.SaveArticleRequest);
      case 'DeleteArticle':
        return deleteArticle(ctx, request as $3.DeleteArticleRequest);
      case 'PublishArticle':
        return publishArticle(ctx, request as $3.PublishArticleRequest);
      default:
        throw $core.ArgumentError('Unknown method: $methodName');
    }
  }

  $core.Map<$core.String, $core.dynamic> get $json => ArticleServiceBase$json;
  $core.Map<$core.String, $core.Map<$core.String, $core.dynamic>>
      get $messageJson => ArticleServiceBase$messageJson;
}
