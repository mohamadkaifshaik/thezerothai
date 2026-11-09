// This is a generated file - do not edit.
//
// Generated from dzeroth/posts/v1/posts.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:async' as $async;
import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

import 'posts.pb.dart' as $3;
import 'posts.pbjson.dart';

export 'posts.pb.dart';

abstract class PostServiceBase extends $pb.GeneratedService {
  $async.Future<$3.CreatePostResponse> createPost(
      $pb.ServerContext ctx, $3.CreatePostRequest request);
  $async.Future<$3.DeletePostResponse> deletePost(
      $pb.ServerContext ctx, $3.DeletePostRequest request);
  $async.Future<$3.GetPostResponse> getPost(
      $pb.ServerContext ctx, $3.GetPostRequest request);
  $async.Future<$3.GetThreadResponse> getThread(
      $pb.ServerContext ctx, $3.GetThreadRequest request);
  $async.Future<$3.SchedulePostResponse> schedulePost(
      $pb.ServerContext ctx, $3.SchedulePostRequest request);
  $async.Future<$3.ListScheduledPostsResponse> listScheduledPosts(
      $pb.ServerContext ctx, $3.ListScheduledPostsRequest request);
  $async.Future<$3.CancelScheduledPostResponse> cancelScheduledPost(
      $pb.ServerContext ctx, $3.CancelScheduledPostRequest request);

  $pb.GeneratedMessage createRequest($core.String methodName) {
    switch (methodName) {
      case 'CreatePost':
        return $3.CreatePostRequest();
      case 'DeletePost':
        return $3.DeletePostRequest();
      case 'GetPost':
        return $3.GetPostRequest();
      case 'GetThread':
        return $3.GetThreadRequest();
      case 'SchedulePost':
        return $3.SchedulePostRequest();
      case 'ListScheduledPosts':
        return $3.ListScheduledPostsRequest();
      case 'CancelScheduledPost':
        return $3.CancelScheduledPostRequest();
      default:
        throw $core.ArgumentError('Unknown method: $methodName');
    }
  }

  $async.Future<$pb.GeneratedMessage> handleCall($pb.ServerContext ctx,
      $core.String methodName, $pb.GeneratedMessage request) {
    switch (methodName) {
      case 'CreatePost':
        return createPost(ctx, request as $3.CreatePostRequest);
      case 'DeletePost':
        return deletePost(ctx, request as $3.DeletePostRequest);
      case 'GetPost':
        return getPost(ctx, request as $3.GetPostRequest);
      case 'GetThread':
        return getThread(ctx, request as $3.GetThreadRequest);
      case 'SchedulePost':
        return schedulePost(ctx, request as $3.SchedulePostRequest);
      case 'ListScheduledPosts':
        return listScheduledPosts(ctx, request as $3.ListScheduledPostsRequest);
      case 'CancelScheduledPost':
        return cancelScheduledPost(
            ctx, request as $3.CancelScheduledPostRequest);
      default:
        throw $core.ArgumentError('Unknown method: $methodName');
    }
  }

  $core.Map<$core.String, $core.dynamic> get $json => PostServiceBase$json;
  $core.Map<$core.String, $core.Map<$core.String, $core.dynamic>>
      get $messageJson => PostServiceBase$messageJson;
}
