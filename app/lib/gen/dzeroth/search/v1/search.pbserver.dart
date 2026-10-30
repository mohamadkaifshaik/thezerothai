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

import 'search.pb.dart' as $4;
import 'search.pbjson.dart';

export 'search.pb.dart';

abstract class SearchServiceBase extends $pb.GeneratedService {
  $async.Future<$4.SearchPeopleResponse> searchPeople(
      $pb.ServerContext ctx, $4.SearchPeopleRequest request);
  $async.Future<$4.SearchPostsResponse> searchPosts(
      $pb.ServerContext ctx, $4.SearchPostsRequest request);
  $async.Future<$4.GetTrendsResponse> getTrends(
      $pb.ServerContext ctx, $4.GetTrendsRequest request);

  $pb.GeneratedMessage createRequest($core.String methodName) {
    switch (methodName) {
      case 'SearchPeople':
        return $4.SearchPeopleRequest();
      case 'SearchPosts':
        return $4.SearchPostsRequest();
      case 'GetTrends':
        return $4.GetTrendsRequest();
      default:
        throw $core.ArgumentError('Unknown method: $methodName');
    }
  }

  $async.Future<$pb.GeneratedMessage> handleCall($pb.ServerContext ctx,
      $core.String methodName, $pb.GeneratedMessage request) {
    switch (methodName) {
      case 'SearchPeople':
        return searchPeople(ctx, request as $4.SearchPeopleRequest);
      case 'SearchPosts':
        return searchPosts(ctx, request as $4.SearchPostsRequest);
      case 'GetTrends':
        return getTrends(ctx, request as $4.GetTrendsRequest);
      default:
        throw $core.ArgumentError('Unknown method: $methodName');
    }
  }

  $core.Map<$core.String, $core.dynamic> get $json => SearchServiceBase$json;
  $core.Map<$core.String, $core.Map<$core.String, $core.dynamic>>
      get $messageJson => SearchServiceBase$messageJson;
}
