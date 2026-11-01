// This is a generated file - do not edit.
//
// Generated from dzeroth/timeline/v1/timeline.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:async' as $async;
import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

import 'timeline.pb.dart' as $5;
import 'timeline.pbjson.dart';

export 'timeline.pb.dart';

abstract class TimelineServiceBase extends $pb.GeneratedService {
  $async.Future<$5.GetHomeTimelineResponse> getHomeTimeline(
      $pb.ServerContext ctx, $5.GetHomeTimelineRequest request);
  $async.Future<$5.GetUserTimelineResponse> getUserTimeline(
      $pb.ServerContext ctx, $5.GetUserTimelineRequest request);
  $async.Future<$5.GetListTimelineResponse> getListTimeline(
      $pb.ServerContext ctx, $5.GetListTimelineRequest request);
  $async.Future<$5.GetCommunityTimelineResponse> getCommunityTimeline(
      $pb.ServerContext ctx, $5.GetCommunityTimelineRequest request);
  $async.Future<$5.SetHomeTabsResponse> setHomeTabs(
      $pb.ServerContext ctx, $5.SetHomeTabsRequest request);

  $pb.GeneratedMessage createRequest($core.String methodName) {
    switch (methodName) {
      case 'GetHomeTimeline':
        return $5.GetHomeTimelineRequest();
      case 'GetUserTimeline':
        return $5.GetUserTimelineRequest();
      case 'GetListTimeline':
        return $5.GetListTimelineRequest();
      case 'GetCommunityTimeline':
        return $5.GetCommunityTimelineRequest();
      case 'SetHomeTabs':
        return $5.SetHomeTabsRequest();
      default:
        throw $core.ArgumentError('Unknown method: $methodName');
    }
  }

  $async.Future<$pb.GeneratedMessage> handleCall($pb.ServerContext ctx,
      $core.String methodName, $pb.GeneratedMessage request) {
    switch (methodName) {
      case 'GetHomeTimeline':
        return getHomeTimeline(ctx, request as $5.GetHomeTimelineRequest);
      case 'GetUserTimeline':
        return getUserTimeline(ctx, request as $5.GetUserTimelineRequest);
      case 'GetListTimeline':
        return getListTimeline(ctx, request as $5.GetListTimelineRequest);
      case 'GetCommunityTimeline':
        return getCommunityTimeline(
            ctx, request as $5.GetCommunityTimelineRequest);
      case 'SetHomeTabs':
        return setHomeTabs(ctx, request as $5.SetHomeTabsRequest);
      default:
        throw $core.ArgumentError('Unknown method: $methodName');
    }
  }

  $core.Map<$core.String, $core.dynamic> get $json => TimelineServiceBase$json;
  $core.Map<$core.String, $core.Map<$core.String, $core.dynamic>>
      get $messageJson => TimelineServiceBase$messageJson;
}
