// This is a generated file - do not edit.
//
// Generated from dzeroth/beacons/v1/beacons.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:async' as $async;
import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

import 'beacons.pb.dart' as $2;
import 'beacons.pbjson.dart';

export 'beacons.pb.dart';

abstract class BeaconServiceBase extends $pb.GeneratedService {
  $async.Future<$2.CreateBeaconResponse> createBeacon(
      $pb.ServerContext ctx, $2.CreateBeaconRequest request);
  $async.Future<$2.UpdateBeaconResponse> updateBeacon(
      $pb.ServerContext ctx, $2.UpdateBeaconRequest request);
  $async.Future<$2.CancelBeaconResponse> cancelBeacon(
      $pb.ServerContext ctx, $2.CancelBeaconRequest request);
  $async.Future<$2.GetBeaconResponse> getBeacon(
      $pb.ServerContext ctx, $2.GetBeaconRequest request);
  $async.Future<$2.ListBeaconsResponse> listBeacons(
      $pb.ServerContext ctx, $2.ListBeaconsRequest request);
  $async.Future<$2.ListMyBeaconsResponse> listMyBeacons(
      $pb.ServerContext ctx, $2.ListMyBeaconsRequest request);
  $async.Future<$2.RequestToJoinResponse> requestToJoin(
      $pb.ServerContext ctx, $2.RequestToJoinRequest request);
  $async.Future<$2.WithdrawJoinRequestResponse> withdrawJoinRequest(
      $pb.ServerContext ctx, $2.WithdrawJoinRequestRequest request);
  $async.Future<$2.RespondToJoinRequestResponse> respondToJoinRequest(
      $pb.ServerContext ctx, $2.RespondToJoinRequestRequest request);
  $async.Future<$2.LeaveBeaconResponse> leaveBeacon(
      $pb.ServerContext ctx, $2.LeaveBeaconRequest request);
  $async.Future<$2.RemoveParticipantResponse> removeParticipant(
      $pb.ServerContext ctx, $2.RemoveParticipantRequest request);
  $async.Future<$2.ListParticipantsResponse> listParticipants(
      $pb.ServerContext ctx, $2.ListParticipantsRequest request);
  $async.Future<$2.ListSharedBeaconsResponse> listSharedBeacons(
      $pb.ServerContext ctx, $2.ListSharedBeaconsRequest request);

  $pb.GeneratedMessage createRequest($core.String methodName) {
    switch (methodName) {
      case 'CreateBeacon':
        return $2.CreateBeaconRequest();
      case 'UpdateBeacon':
        return $2.UpdateBeaconRequest();
      case 'CancelBeacon':
        return $2.CancelBeaconRequest();
      case 'GetBeacon':
        return $2.GetBeaconRequest();
      case 'ListBeacons':
        return $2.ListBeaconsRequest();
      case 'ListMyBeacons':
        return $2.ListMyBeaconsRequest();
      case 'RequestToJoin':
        return $2.RequestToJoinRequest();
      case 'WithdrawJoinRequest':
        return $2.WithdrawJoinRequestRequest();
      case 'RespondToJoinRequest':
        return $2.RespondToJoinRequestRequest();
      case 'LeaveBeacon':
        return $2.LeaveBeaconRequest();
      case 'RemoveParticipant':
        return $2.RemoveParticipantRequest();
      case 'ListParticipants':
        return $2.ListParticipantsRequest();
      case 'ListSharedBeacons':
        return $2.ListSharedBeaconsRequest();
      default:
        throw $core.ArgumentError('Unknown method: $methodName');
    }
  }

  $async.Future<$pb.GeneratedMessage> handleCall($pb.ServerContext ctx,
      $core.String methodName, $pb.GeneratedMessage request) {
    switch (methodName) {
      case 'CreateBeacon':
        return createBeacon(ctx, request as $2.CreateBeaconRequest);
      case 'UpdateBeacon':
        return updateBeacon(ctx, request as $2.UpdateBeaconRequest);
      case 'CancelBeacon':
        return cancelBeacon(ctx, request as $2.CancelBeaconRequest);
      case 'GetBeacon':
        return getBeacon(ctx, request as $2.GetBeaconRequest);
      case 'ListBeacons':
        return listBeacons(ctx, request as $2.ListBeaconsRequest);
      case 'ListMyBeacons':
        return listMyBeacons(ctx, request as $2.ListMyBeaconsRequest);
      case 'RequestToJoin':
        return requestToJoin(ctx, request as $2.RequestToJoinRequest);
      case 'WithdrawJoinRequest':
        return withdrawJoinRequest(
            ctx, request as $2.WithdrawJoinRequestRequest);
      case 'RespondToJoinRequest':
        return respondToJoinRequest(
            ctx, request as $2.RespondToJoinRequestRequest);
      case 'LeaveBeacon':
        return leaveBeacon(ctx, request as $2.LeaveBeaconRequest);
      case 'RemoveParticipant':
        return removeParticipant(ctx, request as $2.RemoveParticipantRequest);
      case 'ListParticipants':
        return listParticipants(ctx, request as $2.ListParticipantsRequest);
      case 'ListSharedBeacons':
        return listSharedBeacons(ctx, request as $2.ListSharedBeaconsRequest);
      default:
        throw $core.ArgumentError('Unknown method: $methodName');
    }
  }

  $core.Map<$core.String, $core.dynamic> get $json => BeaconServiceBase$json;
  $core.Map<$core.String, $core.Map<$core.String, $core.dynamic>>
      get $messageJson => BeaconServiceBase$messageJson;
}
