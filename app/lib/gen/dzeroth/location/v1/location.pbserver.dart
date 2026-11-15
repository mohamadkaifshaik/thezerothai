// This is a generated file - do not edit.
//
// Generated from dzeroth/location/v1/location.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:async' as $async;
import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

import 'location.pb.dart' as $1;
import 'location.pbjson.dart';

export 'location.pb.dart';

abstract class LocationServiceBase extends $pb.GeneratedService {
  $async.Future<$1.GetLocationSettingsResponse> getLocationSettings(
      $pb.ServerContext ctx, $1.GetLocationSettingsRequest request);
  $async.Future<$1.SetAreaResponse> setArea(
      $pb.ServerContext ctx, $1.SetAreaRequest request);
  $async.Future<$1.ClearAreaResponse> clearArea(
      $pb.ServerContext ctx, $1.ClearAreaRequest request);
  $async.Future<$1.ListAreasResponse> listAreas(
      $pb.ServerContext ctx, $1.ListAreasRequest request);

  $pb.GeneratedMessage createRequest($core.String methodName) {
    switch (methodName) {
      case 'GetLocationSettings':
        return $1.GetLocationSettingsRequest();
      case 'SetArea':
        return $1.SetAreaRequest();
      case 'ClearArea':
        return $1.ClearAreaRequest();
      case 'ListAreas':
        return $1.ListAreasRequest();
      default:
        throw $core.ArgumentError('Unknown method: $methodName');
    }
  }

  $async.Future<$pb.GeneratedMessage> handleCall($pb.ServerContext ctx,
      $core.String methodName, $pb.GeneratedMessage request) {
    switch (methodName) {
      case 'GetLocationSettings':
        return getLocationSettings(
            ctx, request as $1.GetLocationSettingsRequest);
      case 'SetArea':
        return setArea(ctx, request as $1.SetAreaRequest);
      case 'ClearArea':
        return clearArea(ctx, request as $1.ClearAreaRequest);
      case 'ListAreas':
        return listAreas(ctx, request as $1.ListAreasRequest);
      default:
        throw $core.ArgumentError('Unknown method: $methodName');
    }
  }

  $core.Map<$core.String, $core.dynamic> get $json => LocationServiceBase$json;
  $core.Map<$core.String, $core.Map<$core.String, $core.dynamic>>
      get $messageJson => LocationServiceBase$messageJson;
}
