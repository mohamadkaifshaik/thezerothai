// This is a generated file - do not edit.
//
// Generated from dzeroth/engagement/v1/engagement.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:async' as $async;
import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

import 'engagement.pb.dart' as $3;
import 'engagement.pbjson.dart';

export 'engagement.pb.dart';

abstract class EngagementServiceBase extends $pb.GeneratedService {
  $async.Future<$3.LikePostResponse> likePost(
      $pb.ServerContext ctx, $3.LikePostRequest request);
  $async.Future<$3.UnlikePostResponse> unlikePost(
      $pb.ServerContext ctx, $3.UnlikePostRequest request);
  $async.Future<$3.RepostPostResponse> repostPost(
      $pb.ServerContext ctx, $3.RepostPostRequest request);
  $async.Future<$3.UndoRepostResponse> undoRepost(
      $pb.ServerContext ctx, $3.UndoRepostRequest request);
  $async.Future<$3.AddBookmarkResponse> addBookmark(
      $pb.ServerContext ctx, $3.AddBookmarkRequest request);
  $async.Future<$3.RemoveBookmarkResponse> removeBookmark(
      $pb.ServerContext ctx, $3.RemoveBookmarkRequest request);
  $async.Future<$3.ListBookmarksResponse> listBookmarks(
      $pb.ServerContext ctx, $3.ListBookmarksRequest request);

  $pb.GeneratedMessage createRequest($core.String methodName) {
    switch (methodName) {
      case 'LikePost':
        return $3.LikePostRequest();
      case 'UnlikePost':
        return $3.UnlikePostRequest();
      case 'RepostPost':
        return $3.RepostPostRequest();
      case 'UndoRepost':
        return $3.UndoRepostRequest();
      case 'AddBookmark':
        return $3.AddBookmarkRequest();
      case 'RemoveBookmark':
        return $3.RemoveBookmarkRequest();
      case 'ListBookmarks':
        return $3.ListBookmarksRequest();
      default:
        throw $core.ArgumentError('Unknown method: $methodName');
    }
  }

  $async.Future<$pb.GeneratedMessage> handleCall($pb.ServerContext ctx,
      $core.String methodName, $pb.GeneratedMessage request) {
    switch (methodName) {
      case 'LikePost':
        return likePost(ctx, request as $3.LikePostRequest);
      case 'UnlikePost':
        return unlikePost(ctx, request as $3.UnlikePostRequest);
      case 'RepostPost':
        return repostPost(ctx, request as $3.RepostPostRequest);
      case 'UndoRepost':
        return undoRepost(ctx, request as $3.UndoRepostRequest);
      case 'AddBookmark':
        return addBookmark(ctx, request as $3.AddBookmarkRequest);
      case 'RemoveBookmark':
        return removeBookmark(ctx, request as $3.RemoveBookmarkRequest);
      case 'ListBookmarks':
        return listBookmarks(ctx, request as $3.ListBookmarksRequest);
      default:
        throw $core.ArgumentError('Unknown method: $methodName');
    }
  }

  $core.Map<$core.String, $core.dynamic> get $json =>
      EngagementServiceBase$json;
  $core.Map<$core.String, $core.Map<$core.String, $core.dynamic>>
      get $messageJson => EngagementServiceBase$messageJson;
}
