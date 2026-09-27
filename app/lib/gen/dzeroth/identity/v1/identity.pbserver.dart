// This is a generated file - do not edit.
//
// Generated from dzeroth/identity/v1/identity.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:async' as $async;
import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

import 'identity.pb.dart' as $1;
import 'identity.pbjson.dart';

export 'identity.pb.dart';

abstract class IdentityServiceBase extends $pb.GeneratedService {
  $async.Future<$1.CreateProfileResponse> createProfile(
      $pb.ServerContext ctx, $1.CreateProfileRequest request);
  $async.Future<$1.CheckHandleAvailabilityResponse> checkHandleAvailability(
      $pb.ServerContext ctx, $1.CheckHandleAvailabilityRequest request);
  $async.Future<$1.GetMeResponse> getMe(
      $pb.ServerContext ctx, $1.GetMeRequest request);
  $async.Future<$1.GetProfileResponse> getProfile(
      $pb.ServerContext ctx, $1.GetProfileRequest request);
  $async.Future<$1.UpdateProfileResponse> updateProfile(
      $pb.ServerContext ctx, $1.UpdateProfileRequest request);
  $async.Future<$1.ChangeHandleResponse> changeHandle(
      $pb.ServerContext ctx, $1.ChangeHandleRequest request);
  $async.Future<$1.DeleteAccountResponse> deleteAccount(
      $pb.ServerContext ctx, $1.DeleteAccountRequest request);
  $async.Future<$1.RequestAccountExportResponse> requestAccountExport(
      $pb.ServerContext ctx, $1.RequestAccountExportRequest request);
  $async.Future<$1.GetAccountExportResponse> getAccountExport(
      $pb.ServerContext ctx, $1.GetAccountExportRequest request);

  $pb.GeneratedMessage createRequest($core.String methodName) {
    switch (methodName) {
      case 'CreateProfile':
        return $1.CreateProfileRequest();
      case 'CheckHandleAvailability':
        return $1.CheckHandleAvailabilityRequest();
      case 'GetMe':
        return $1.GetMeRequest();
      case 'GetProfile':
        return $1.GetProfileRequest();
      case 'UpdateProfile':
        return $1.UpdateProfileRequest();
      case 'ChangeHandle':
        return $1.ChangeHandleRequest();
      case 'DeleteAccount':
        return $1.DeleteAccountRequest();
      case 'RequestAccountExport':
        return $1.RequestAccountExportRequest();
      case 'GetAccountExport':
        return $1.GetAccountExportRequest();
      default:
        throw $core.ArgumentError('Unknown method: $methodName');
    }
  }

  $async.Future<$pb.GeneratedMessage> handleCall($pb.ServerContext ctx,
      $core.String methodName, $pb.GeneratedMessage request) {
    switch (methodName) {
      case 'CreateProfile':
        return createProfile(ctx, request as $1.CreateProfileRequest);
      case 'CheckHandleAvailability':
        return checkHandleAvailability(
            ctx, request as $1.CheckHandleAvailabilityRequest);
      case 'GetMe':
        return getMe(ctx, request as $1.GetMeRequest);
      case 'GetProfile':
        return getProfile(ctx, request as $1.GetProfileRequest);
      case 'UpdateProfile':
        return updateProfile(ctx, request as $1.UpdateProfileRequest);
      case 'ChangeHandle':
        return changeHandle(ctx, request as $1.ChangeHandleRequest);
      case 'DeleteAccount':
        return deleteAccount(ctx, request as $1.DeleteAccountRequest);
      case 'RequestAccountExport':
        return requestAccountExport(
            ctx, request as $1.RequestAccountExportRequest);
      case 'GetAccountExport':
        return getAccountExport(ctx, request as $1.GetAccountExportRequest);
      default:
        throw $core.ArgumentError('Unknown method: $methodName');
    }
  }

  $core.Map<$core.String, $core.dynamic> get $json => IdentityServiceBase$json;
  $core.Map<$core.String, $core.Map<$core.String, $core.dynamic>>
      get $messageJson => IdentityServiceBase$messageJson;
}
