// This is a generated file - do not edit.
//
// Generated from dzeroth/communities/v1/communities.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:async' as $async;
import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

import 'communities.pb.dart' as $3;
import 'communities.pbjson.dart';

export 'communities.pb.dart';

abstract class CommunityServiceBase extends $pb.GeneratedService {
  $async.Future<$3.CreateCommunityResponse> createCommunity(
      $pb.ServerContext ctx, $3.CreateCommunityRequest request);
  $async.Future<$3.UpdateCommunityResponse> updateCommunity(
      $pb.ServerContext ctx, $3.UpdateCommunityRequest request);
  $async.Future<$3.GetCommunityResponse> getCommunity(
      $pb.ServerContext ctx, $3.GetCommunityRequest request);
  $async.Future<$3.ListCommunitiesResponse> listCommunities(
      $pb.ServerContext ctx, $3.ListCommunitiesRequest request);
  $async.Future<$3.ListMyCommunitiesResponse> listMyCommunities(
      $pb.ServerContext ctx, $3.ListMyCommunitiesRequest request);
  $async.Future<$3.JoinCommunityResponse> joinCommunity(
      $pb.ServerContext ctx, $3.JoinCommunityRequest request);
  $async.Future<$3.LeaveCommunityResponse> leaveCommunity(
      $pb.ServerContext ctx, $3.LeaveCommunityRequest request);
  $async.Future<$3.ListCommunityMembersResponse> listCommunityMembers(
      $pb.ServerContext ctx, $3.ListCommunityMembersRequest request);
  $async.Future<$3.HideCommunityPostResponse> hideCommunityPost(
      $pb.ServerContext ctx, $3.HideCommunityPostRequest request);
  $async.Future<$3.RestoreCommunityPostResponse> restoreCommunityPost(
      $pb.ServerContext ctx, $3.RestoreCommunityPostRequest request);
  $async.Future<$3.SetMemberRoleResponse> setMemberRole(
      $pb.ServerContext ctx, $3.SetMemberRoleRequest request);
  $async.Future<$3.ListModerationLogResponse> listModerationLog(
      $pb.ServerContext ctx, $3.ListModerationLogRequest request);

  $pb.GeneratedMessage createRequest($core.String methodName) {
    switch (methodName) {
      case 'CreateCommunity':
        return $3.CreateCommunityRequest();
      case 'UpdateCommunity':
        return $3.UpdateCommunityRequest();
      case 'GetCommunity':
        return $3.GetCommunityRequest();
      case 'ListCommunities':
        return $3.ListCommunitiesRequest();
      case 'ListMyCommunities':
        return $3.ListMyCommunitiesRequest();
      case 'JoinCommunity':
        return $3.JoinCommunityRequest();
      case 'LeaveCommunity':
        return $3.LeaveCommunityRequest();
      case 'ListCommunityMembers':
        return $3.ListCommunityMembersRequest();
      case 'HideCommunityPost':
        return $3.HideCommunityPostRequest();
      case 'RestoreCommunityPost':
        return $3.RestoreCommunityPostRequest();
      case 'SetMemberRole':
        return $3.SetMemberRoleRequest();
      case 'ListModerationLog':
        return $3.ListModerationLogRequest();
      default:
        throw $core.ArgumentError('Unknown method: $methodName');
    }
  }

  $async.Future<$pb.GeneratedMessage> handleCall($pb.ServerContext ctx,
      $core.String methodName, $pb.GeneratedMessage request) {
    switch (methodName) {
      case 'CreateCommunity':
        return createCommunity(ctx, request as $3.CreateCommunityRequest);
      case 'UpdateCommunity':
        return updateCommunity(ctx, request as $3.UpdateCommunityRequest);
      case 'GetCommunity':
        return getCommunity(ctx, request as $3.GetCommunityRequest);
      case 'ListCommunities':
        return listCommunities(ctx, request as $3.ListCommunitiesRequest);
      case 'ListMyCommunities':
        return listMyCommunities(ctx, request as $3.ListMyCommunitiesRequest);
      case 'JoinCommunity':
        return joinCommunity(ctx, request as $3.JoinCommunityRequest);
      case 'LeaveCommunity':
        return leaveCommunity(ctx, request as $3.LeaveCommunityRequest);
      case 'ListCommunityMembers':
        return listCommunityMembers(
            ctx, request as $3.ListCommunityMembersRequest);
      case 'HideCommunityPost':
        return hideCommunityPost(ctx, request as $3.HideCommunityPostRequest);
      case 'RestoreCommunityPost':
        return restoreCommunityPost(
            ctx, request as $3.RestoreCommunityPostRequest);
      case 'SetMemberRole':
        return setMemberRole(ctx, request as $3.SetMemberRoleRequest);
      case 'ListModerationLog':
        return listModerationLog(ctx, request as $3.ListModerationLogRequest);
      default:
        throw $core.ArgumentError('Unknown method: $methodName');
    }
  }

  $core.Map<$core.String, $core.dynamic> get $json => CommunityServiceBase$json;
  $core.Map<$core.String, $core.Map<$core.String, $core.dynamic>>
      get $messageJson => CommunityServiceBase$messageJson;
}
