// This is a generated file - do not edit.
//
// Generated from dzeroth/notifications/v1/notifications.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:async' as $async;
import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

import 'notifications.pb.dart' as $2;
import 'notifications.pbjson.dart';

export 'notifications.pb.dart';

abstract class NotificationServiceBase extends $pb.GeneratedService {
  $async.Future<$2.ListNotificationsResponse> listNotifications(
      $pb.ServerContext ctx, $2.ListNotificationsRequest request);
  $async.Future<$2.MarkNotificationsSeenResponse> markNotificationsSeen(
      $pb.ServerContext ctx, $2.MarkNotificationsSeenRequest request);
  $async.Future<$2.RegisterDeviceResponse> registerDevice(
      $pb.ServerContext ctx, $2.RegisterDeviceRequest request);
  $async.Future<$2.UnregisterDeviceResponse> unregisterDevice(
      $pb.ServerContext ctx, $2.UnregisterDeviceRequest request);

  $pb.GeneratedMessage createRequest($core.String methodName) {
    switch (methodName) {
      case 'ListNotifications':
        return $2.ListNotificationsRequest();
      case 'MarkNotificationsSeen':
        return $2.MarkNotificationsSeenRequest();
      case 'RegisterDevice':
        return $2.RegisterDeviceRequest();
      case 'UnregisterDevice':
        return $2.UnregisterDeviceRequest();
      default:
        throw $core.ArgumentError('Unknown method: $methodName');
    }
  }

  $async.Future<$pb.GeneratedMessage> handleCall($pb.ServerContext ctx,
      $core.String methodName, $pb.GeneratedMessage request) {
    switch (methodName) {
      case 'ListNotifications':
        return listNotifications(ctx, request as $2.ListNotificationsRequest);
      case 'MarkNotificationsSeen':
        return markNotificationsSeen(
            ctx, request as $2.MarkNotificationsSeenRequest);
      case 'RegisterDevice':
        return registerDevice(ctx, request as $2.RegisterDeviceRequest);
      case 'UnregisterDevice':
        return unregisterDevice(ctx, request as $2.UnregisterDeviceRequest);
      default:
        throw $core.ArgumentError('Unknown method: $methodName');
    }
  }

  $core.Map<$core.String, $core.dynamic> get $json =>
      NotificationServiceBase$json;
  $core.Map<$core.String, $core.Map<$core.String, $core.dynamic>>
      get $messageJson => NotificationServiceBase$messageJson;
}
