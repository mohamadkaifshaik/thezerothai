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

import 'engagement.pb.dart' as $0;
import 'engagement.pbjson.dart';

export 'engagement.pb.dart';

abstract class EngagementServiceBase extends $pb.GeneratedService {
  $async.Future<$0.LikePostResponse> likePost(
      $pb.ServerContext ctx, $0.LikePostRequest request);
  $async.Future<$0.UnlikePostResponse> unlikePost(
      $pb.ServerContext ctx, $0.UnlikePostRequest request);
  $async.Future<$0.RepostPostResponse> repostPost(
      $pb.ServerContext ctx, $0.RepostPostRequest request);
  $async.Future<$0.UndoRepostResponse> undoRepost(
      $pb.ServerContext ctx, $0.UndoRepostRequest request);

  $pb.GeneratedMessage createRequest($core.String methodName) {
    switch (methodName) {
      case 'LikePost':
        return $0.LikePostRequest();
      case 'UnlikePost':
        return $0.UnlikePostRequest();
      case 'RepostPost':
        return $0.RepostPostRequest();
      case 'UndoRepost':
        return $0.UndoRepostRequest();
      default:
        throw $core.ArgumentError('Unknown method: $methodName');
    }
  }

  $async.Future<$pb.GeneratedMessage> handleCall($pb.ServerContext ctx,
      $core.String methodName, $pb.GeneratedMessage request) {
    switch (methodName) {
      case 'LikePost':
        return likePost(ctx, request as $0.LikePostRequest);
      case 'UnlikePost':
        return unlikePost(ctx, request as $0.UnlikePostRequest);
      case 'RepostPost':
        return repostPost(ctx, request as $0.RepostPostRequest);
      case 'UndoRepost':
        return undoRepost(ctx, request as $0.UndoRepostRequest);
      default:
        throw $core.ArgumentError('Unknown method: $methodName');
    }
  }

  $core.Map<$core.String, $core.dynamic> get $json =>
      EngagementServiceBase$json;
  $core.Map<$core.String, $core.Map<$core.String, $core.dynamic>>
      get $messageJson => EngagementServiceBase$messageJson;
}
