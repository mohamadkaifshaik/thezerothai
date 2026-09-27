// This is a generated file - do not edit.
//
// Generated from dzeroth/graph/v1/graph.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:async' as $async;
import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

import 'graph.pb.dart' as $2;
import 'graph.pbjson.dart';

export 'graph.pb.dart';

abstract class GraphServiceBase extends $pb.GeneratedService {
  $async.Future<$2.FollowResponse> follow(
      $pb.ServerContext ctx, $2.FollowRequest request);
  $async.Future<$2.UnfollowResponse> unfollow(
      $pb.ServerContext ctx, $2.UnfollowRequest request);
  $async.Future<$2.ListFollowRequestsResponse> listFollowRequests(
      $pb.ServerContext ctx, $2.ListFollowRequestsRequest request);
  $async.Future<$2.RespondToFollowRequestResponse> respondToFollowRequest(
      $pb.ServerContext ctx, $2.RespondToFollowRequestRequest request);
  $async.Future<$2.BlockResponse> block(
      $pb.ServerContext ctx, $2.BlockRequest request);
  $async.Future<$2.UnblockResponse> unblock(
      $pb.ServerContext ctx, $2.UnblockRequest request);
  $async.Future<$2.MuteResponse> mute(
      $pb.ServerContext ctx, $2.MuteRequest request);
  $async.Future<$2.UnmuteResponse> unmute(
      $pb.ServerContext ctx, $2.UnmuteRequest request);
  $async.Future<$2.GetRelationshipsResponse> getRelationships(
      $pb.ServerContext ctx, $2.GetRelationshipsRequest request);
  $async.Future<$2.ListFollowersResponse> listFollowers(
      $pb.ServerContext ctx, $2.ListFollowersRequest request);
  $async.Future<$2.ListFollowingResponse> listFollowing(
      $pb.ServerContext ctx, $2.ListFollowingRequest request);
  $async.Future<$2.ListBlockedUsersResponse> listBlockedUsers(
      $pb.ServerContext ctx, $2.ListBlockedUsersRequest request);
  $async.Future<$2.ListMutedUsersResponse> listMutedUsers(
      $pb.ServerContext ctx, $2.ListMutedUsersRequest request);

  $pb.GeneratedMessage createRequest($core.String methodName) {
    switch (methodName) {
      case 'Follow':
        return $2.FollowRequest();
      case 'Unfollow':
        return $2.UnfollowRequest();
      case 'ListFollowRequests':
        return $2.ListFollowRequestsRequest();
      case 'RespondToFollowRequest':
        return $2.RespondToFollowRequestRequest();
      case 'Block':
        return $2.BlockRequest();
      case 'Unblock':
        return $2.UnblockRequest();
      case 'Mute':
        return $2.MuteRequest();
      case 'Unmute':
        return $2.UnmuteRequest();
      case 'GetRelationships':
        return $2.GetRelationshipsRequest();
      case 'ListFollowers':
        return $2.ListFollowersRequest();
      case 'ListFollowing':
        return $2.ListFollowingRequest();
      case 'ListBlockedUsers':
        return $2.ListBlockedUsersRequest();
      case 'ListMutedUsers':
        return $2.ListMutedUsersRequest();
      default:
        throw $core.ArgumentError('Unknown method: $methodName');
    }
  }

  $async.Future<$pb.GeneratedMessage> handleCall($pb.ServerContext ctx,
      $core.String methodName, $pb.GeneratedMessage request) {
    switch (methodName) {
      case 'Follow':
        return follow(ctx, request as $2.FollowRequest);
      case 'Unfollow':
        return unfollow(ctx, request as $2.UnfollowRequest);
      case 'ListFollowRequests':
        return listFollowRequests(ctx, request as $2.ListFollowRequestsRequest);
      case 'RespondToFollowRequest':
        return respondToFollowRequest(
            ctx, request as $2.RespondToFollowRequestRequest);
      case 'Block':
        return block(ctx, request as $2.BlockRequest);
      case 'Unblock':
        return unblock(ctx, request as $2.UnblockRequest);
      case 'Mute':
        return mute(ctx, request as $2.MuteRequest);
      case 'Unmute':
        return unmute(ctx, request as $2.UnmuteRequest);
      case 'GetRelationships':
        return getRelationships(ctx, request as $2.GetRelationshipsRequest);
      case 'ListFollowers':
        return listFollowers(ctx, request as $2.ListFollowersRequest);
      case 'ListFollowing':
        return listFollowing(ctx, request as $2.ListFollowingRequest);
      case 'ListBlockedUsers':
        return listBlockedUsers(ctx, request as $2.ListBlockedUsersRequest);
      case 'ListMutedUsers':
        return listMutedUsers(ctx, request as $2.ListMutedUsersRequest);
      default:
        throw $core.ArgumentError('Unknown method: $methodName');
    }
  }

  $core.Map<$core.String, $core.dynamic> get $json => GraphServiceBase$json;
  $core.Map<$core.String, $core.Map<$core.String, $core.dynamic>>
      get $messageJson => GraphServiceBase$messageJson;
}
