// This is a generated file - do not edit.
//
// Generated from dzeroth/keys/v1/keys.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:async' as $async;
import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

import 'keys.pb.dart' as $1;
import 'keys.pbjson.dart';

export 'keys.pb.dart';

abstract class KeyServiceBase extends $pb.GeneratedService {
  $async.Future<$1.RegisterKeyDeviceResponse> registerKeyDevice(
      $pb.ServerContext ctx, $1.RegisterKeyDeviceRequest request);
  $async.Future<$1.ListMyKeyDevicesResponse> listMyKeyDevices(
      $pb.ServerContext ctx, $1.ListMyKeyDevicesRequest request);
  $async.Future<$1.RemoveKeyDeviceResponse> removeKeyDevice(
      $pb.ServerContext ctx, $1.RemoveKeyDeviceRequest request);
  $async.Future<$1.UploadKeyPackagesResponse> uploadKeyPackages(
      $pb.ServerContext ctx, $1.UploadKeyPackagesRequest request);
  $async.Future<$1.GetKeyDevicesResponse> getKeyDevices(
      $pb.ServerContext ctx, $1.GetKeyDevicesRequest request);
  $async.Future<$1.ClaimKeyPackagesResponse> claimKeyPackages(
      $pb.ServerContext ctx, $1.ClaimKeyPackagesRequest request);

  $pb.GeneratedMessage createRequest($core.String methodName) {
    switch (methodName) {
      case 'RegisterKeyDevice':
        return $1.RegisterKeyDeviceRequest();
      case 'ListMyKeyDevices':
        return $1.ListMyKeyDevicesRequest();
      case 'RemoveKeyDevice':
        return $1.RemoveKeyDeviceRequest();
      case 'UploadKeyPackages':
        return $1.UploadKeyPackagesRequest();
      case 'GetKeyDevices':
        return $1.GetKeyDevicesRequest();
      case 'ClaimKeyPackages':
        return $1.ClaimKeyPackagesRequest();
      default:
        throw $core.ArgumentError('Unknown method: $methodName');
    }
  }

  $async.Future<$pb.GeneratedMessage> handleCall($pb.ServerContext ctx,
      $core.String methodName, $pb.GeneratedMessage request) {
    switch (methodName) {
      case 'RegisterKeyDevice':
        return registerKeyDevice(ctx, request as $1.RegisterKeyDeviceRequest);
      case 'ListMyKeyDevices':
        return listMyKeyDevices(ctx, request as $1.ListMyKeyDevicesRequest);
      case 'RemoveKeyDevice':
        return removeKeyDevice(ctx, request as $1.RemoveKeyDeviceRequest);
      case 'UploadKeyPackages':
        return uploadKeyPackages(ctx, request as $1.UploadKeyPackagesRequest);
      case 'GetKeyDevices':
        return getKeyDevices(ctx, request as $1.GetKeyDevicesRequest);
      case 'ClaimKeyPackages':
        return claimKeyPackages(ctx, request as $1.ClaimKeyPackagesRequest);
      default:
        throw $core.ArgumentError('Unknown method: $methodName');
    }
  }

  $core.Map<$core.String, $core.dynamic> get $json => KeyServiceBase$json;
  $core.Map<$core.String, $core.Map<$core.String, $core.dynamic>>
      get $messageJson => KeyServiceBase$messageJson;
}
