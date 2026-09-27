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

import 'timeline.pb.dart' as $3;
import 'timeline.pbjson.dart';

export 'timeline.pb.dart';

abstract class TimelineServiceBase extends $pb.GeneratedService {
  $async.Future<$3.GetHomeTimelineResponse> getHomeTimeline(
      $pb.ServerContext ctx, $3.GetHomeTimelineRequest request);
  $async.Future<$3.GetUserTimelineResponse> getUserTimeline(
      $pb.ServerContext ctx, $3.GetUserTimelineRequest request);

  $pb.GeneratedMessage createRequest($core.String methodName) {
    switch (methodName) {
      case 'GetHomeTimeline':
        return $3.GetHomeTimelineRequest();
      case 'GetUserTimeline':
        return $3.GetUserTimelineRequest();
      default:
        throw $core.ArgumentError('Unknown method: $methodName');
    }
  }

  $async.Future<$pb.GeneratedMessage> handleCall($pb.ServerContext ctx,
      $core.String methodName, $pb.GeneratedMessage request) {
    switch (methodName) {
      case 'GetHomeTimeline':
        return getHomeTimeline(ctx, request as $3.GetHomeTimelineRequest);
      case 'GetUserTimeline':
        return getUserTimeline(ctx, request as $3.GetUserTimelineRequest);
      default:
        throw $core.ArgumentError('Unknown method: $methodName');
    }
  }

  $core.Map<$core.String, $core.dynamic> get $json => TimelineServiceBase$json;
  $core.Map<$core.String, $core.Map<$core.String, $core.dynamic>>
      get $messageJson => TimelineServiceBase$messageJson;
}
