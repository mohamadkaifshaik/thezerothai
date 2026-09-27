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

import 'posts.pb.dart' as $2;
import 'posts.pbjson.dart';

export 'posts.pb.dart';

abstract class PostServiceBase extends $pb.GeneratedService {
  $async.Future<$2.CreatePostResponse> createPost(
      $pb.ServerContext ctx, $2.CreatePostRequest request);
  $async.Future<$2.DeletePostResponse> deletePost(
      $pb.ServerContext ctx, $2.DeletePostRequest request);
  $async.Future<$2.GetPostResponse> getPost(
      $pb.ServerContext ctx, $2.GetPostRequest request);
  $async.Future<$2.GetThreadResponse> getThread(
      $pb.ServerContext ctx, $2.GetThreadRequest request);

  $pb.GeneratedMessage createRequest($core.String methodName) {
    switch (methodName) {
      case 'CreatePost':
        return $2.CreatePostRequest();
      case 'DeletePost':
        return $2.DeletePostRequest();
      case 'GetPost':
        return $2.GetPostRequest();
      case 'GetThread':
        return $2.GetThreadRequest();
      default:
        throw $core.ArgumentError('Unknown method: $methodName');
    }
  }

  $async.Future<$pb.GeneratedMessage> handleCall($pb.ServerContext ctx,
      $core.String methodName, $pb.GeneratedMessage request) {
    switch (methodName) {
      case 'CreatePost':
        return createPost(ctx, request as $2.CreatePostRequest);
      case 'DeletePost':
        return deletePost(ctx, request as $2.DeletePostRequest);
      case 'GetPost':
        return getPost(ctx, request as $2.GetPostRequest);
      case 'GetThread':
        return getThread(ctx, request as $2.GetThreadRequest);
      default:
        throw $core.ArgumentError('Unknown method: $methodName');
    }
  }

  $core.Map<$core.String, $core.dynamic> get $json => PostServiceBase$json;
  $core.Map<$core.String, $core.Map<$core.String, $core.dynamic>>
      get $messageJson => PostServiceBase$messageJson;
}
