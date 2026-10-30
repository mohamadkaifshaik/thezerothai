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

import 'identity.pb.dart' as $2;
import 'identity.pbjson.dart';

export 'identity.pb.dart';

abstract class IdentityServiceBase extends $pb.GeneratedService {
  $async.Future<$2.CreateProfileResponse> createProfile(
      $pb.ServerContext ctx, $2.CreateProfileRequest request);
  $async.Future<$2.CheckHandleAvailabilityResponse> checkHandleAvailability(
      $pb.ServerContext ctx, $2.CheckHandleAvailabilityRequest request);
  $async.Future<$2.GetMeResponse> getMe(
      $pb.ServerContext ctx, $2.GetMeRequest request);
  $async.Future<$2.GetProfileResponse> getProfile(
      $pb.ServerContext ctx, $2.GetProfileRequest request);
  $async.Future<$2.UpdateProfileResponse> updateProfile(
      $pb.ServerContext ctx, $2.UpdateProfileRequest request);
  $async.Future<$2.ChangeHandleResponse> changeHandle(
      $pb.ServerContext ctx, $2.ChangeHandleRequest request);
  $async.Future<$2.DeleteAccountResponse> deleteAccount(
      $pb.ServerContext ctx, $2.DeleteAccountRequest request);
  $async.Future<$2.RequestAccountExportResponse> requestAccountExport(
      $pb.ServerContext ctx, $2.RequestAccountExportRequest request);
  $async.Future<$2.GetAccountExportResponse> getAccountExport(
      $pb.ServerContext ctx, $2.GetAccountExportRequest request);

  $pb.GeneratedMessage createRequest($core.String methodName) {
    switch (methodName) {
      case 'CreateProfile':
        return $2.CreateProfileRequest();
      case 'CheckHandleAvailability':
        return $2.CheckHandleAvailabilityRequest();
      case 'GetMe':
        return $2.GetMeRequest();
      case 'GetProfile':
        return $2.GetProfileRequest();
      case 'UpdateProfile':
        return $2.UpdateProfileRequest();
      case 'ChangeHandle':
        return $2.ChangeHandleRequest();
      case 'DeleteAccount':
        return $2.DeleteAccountRequest();
      case 'RequestAccountExport':
        return $2.RequestAccountExportRequest();
      case 'GetAccountExport':
        return $2.GetAccountExportRequest();
      default:
        throw $core.ArgumentError('Unknown method: $methodName');
    }
  }

  $async.Future<$pb.GeneratedMessage> handleCall($pb.ServerContext ctx,
      $core.String methodName, $pb.GeneratedMessage request) {
    switch (methodName) {
      case 'CreateProfile':
        return createProfile(ctx, request as $2.CreateProfileRequest);
      case 'CheckHandleAvailability':
        return checkHandleAvailability(
            ctx, request as $2.CheckHandleAvailabilityRequest);
      case 'GetMe':
        return getMe(ctx, request as $2.GetMeRequest);
      case 'GetProfile':
        return getProfile(ctx, request as $2.GetProfileRequest);
      case 'UpdateProfile':
        return updateProfile(ctx, request as $2.UpdateProfileRequest);
      case 'ChangeHandle':
        return changeHandle(ctx, request as $2.ChangeHandleRequest);
      case 'DeleteAccount':
        return deleteAccount(ctx, request as $2.DeleteAccountRequest);
      case 'RequestAccountExport':
        return requestAccountExport(
            ctx, request as $2.RequestAccountExportRequest);
      case 'GetAccountExport':
        return getAccountExport(ctx, request as $2.GetAccountExportRequest);
      default:
        throw $core.ArgumentError('Unknown method: $methodName');
    }
  }

  $core.Map<$core.String, $core.dynamic> get $json => IdentityServiceBase$json;
  $core.Map<$core.String, $core.Map<$core.String, $core.dynamic>>
      get $messageJson => IdentityServiceBase$messageJson;
}
