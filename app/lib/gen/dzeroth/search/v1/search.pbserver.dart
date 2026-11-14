// This is a generated file - do not edit.
//
// Generated from dzeroth/search/v1/search.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:async' as $async;
import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

import 'search.pb.dart' as $6;
import 'search.pbjson.dart';

export 'search.pb.dart';

abstract class SearchServiceBase extends $pb.GeneratedService {
  $async.Future<$6.SearchPeopleResponse> searchPeople(
      $pb.ServerContext ctx, $6.SearchPeopleRequest request);
  $async.Future<$6.SearchPostsResponse> searchPosts(
      $pb.ServerContext ctx, $6.SearchPostsRequest request);
  $async.Future<$6.GetTrendsResponse> getTrends(
      $pb.ServerContext ctx, $6.GetTrendsRequest request);
  $async.Future<$6.SearchListsResponse> searchLists(
      $pb.ServerContext ctx, $6.SearchListsRequest request);
  $async.Future<$6.SearchCommunitiesResponse> searchCommunities(
      $pb.ServerContext ctx, $6.SearchCommunitiesRequest request);

  $pb.GeneratedMessage createRequest($core.String methodName) {
    switch (methodName) {
      case 'SearchPeople':
        return $6.SearchPeopleRequest();
      case 'SearchPosts':
        return $6.SearchPostsRequest();
      case 'GetTrends':
        return $6.GetTrendsRequest();
      case 'SearchLists':
        return $6.SearchListsRequest();
      case 'SearchCommunities':
        return $6.SearchCommunitiesRequest();
      default:
        throw $core.ArgumentError('Unknown method: $methodName');
    }
  }

  $async.Future<$pb.GeneratedMessage> handleCall($pb.ServerContext ctx,
      $core.String methodName, $pb.GeneratedMessage request) {
    switch (methodName) {
      case 'SearchPeople':
        return searchPeople(ctx, request as $6.SearchPeopleRequest);
      case 'SearchPosts':
        return searchPosts(ctx, request as $6.SearchPostsRequest);
      case 'GetTrends':
        return getTrends(ctx, request as $6.GetTrendsRequest);
      case 'SearchLists':
        return searchLists(ctx, request as $6.SearchListsRequest);
      case 'SearchCommunities':
        return searchCommunities(ctx, request as $6.SearchCommunitiesRequest);
      default:
        throw $core.ArgumentError('Unknown method: $methodName');
    }
  }

  $core.Map<$core.String, $core.dynamic> get $json => SearchServiceBase$json;
  $core.Map<$core.String, $core.Map<$core.String, $core.dynamic>>
      get $messageJson => SearchServiceBase$messageJson;
}
