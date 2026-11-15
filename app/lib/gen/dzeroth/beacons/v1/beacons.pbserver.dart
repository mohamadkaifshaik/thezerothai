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

import 'beacons.pb.dart' as $3;
import 'beacons.pbjson.dart';

export 'beacons.pb.dart';

abstract class BeaconServiceBase extends $pb.GeneratedService {
  $async.Future<$3.CreateBeaconResponse> createBeacon(
      $pb.ServerContext ctx, $3.CreateBeaconRequest request);
  $async.Future<$3.UpdateBeaconResponse> updateBeacon(
      $pb.ServerContext ctx, $3.UpdateBeaconRequest request);
  $async.Future<$3.CancelBeaconResponse> cancelBeacon(
      $pb.ServerContext ctx, $3.CancelBeaconRequest request);
  $async.Future<$3.GetBeaconResponse> getBeacon(
      $pb.ServerContext ctx, $3.GetBeaconRequest request);
  $async.Future<$3.ListBeaconsResponse> listBeacons(
      $pb.ServerContext ctx, $3.ListBeaconsRequest request);
  $async.Future<$3.ListMyBeaconsResponse> listMyBeacons(
      $pb.ServerContext ctx, $3.ListMyBeaconsRequest request);
  $async.Future<$3.RequestToJoinResponse> requestToJoin(
      $pb.ServerContext ctx, $3.RequestToJoinRequest request);
  $async.Future<$3.WithdrawJoinRequestResponse> withdrawJoinRequest(
      $pb.ServerContext ctx, $3.WithdrawJoinRequestRequest request);
  $async.Future<$3.RespondToJoinRequestResponse> respondToJoinRequest(
      $pb.ServerContext ctx, $3.RespondToJoinRequestRequest request);
  $async.Future<$3.LeaveBeaconResponse> leaveBeacon(
      $pb.ServerContext ctx, $3.LeaveBeaconRequest request);
  $async.Future<$3.RemoveParticipantResponse> removeParticipant(
      $pb.ServerContext ctx, $3.RemoveParticipantRequest request);
  $async.Future<$3.ListParticipantsResponse> listParticipants(
      $pb.ServerContext ctx, $3.ListParticipantsRequest request);
  $async.Future<$3.ListSharedBeaconsResponse> listSharedBeacons(
      $pb.ServerContext ctx, $3.ListSharedBeaconsRequest request);
  $async.Future<$3.ListNearbyBeaconsResponse> listNearbyBeacons(
      $pb.ServerContext ctx, $3.ListNearbyBeaconsRequest request);

  $pb.GeneratedMessage createRequest($core.String methodName) {
    switch (methodName) {
      case 'CreateBeacon':
        return $3.CreateBeaconRequest();
      case 'UpdateBeacon':
        return $3.UpdateBeaconRequest();
      case 'CancelBeacon':
        return $3.CancelBeaconRequest();
      case 'GetBeacon':
        return $3.GetBeaconRequest();
      case 'ListBeacons':
        return $3.ListBeaconsRequest();
      case 'ListMyBeacons':
        return $3.ListMyBeaconsRequest();
      case 'RequestToJoin':
        return $3.RequestToJoinRequest();
      case 'WithdrawJoinRequest':
        return $3.WithdrawJoinRequestRequest();
      case 'RespondToJoinRequest':
        return $3.RespondToJoinRequestRequest();
      case 'LeaveBeacon':
        return $3.LeaveBeaconRequest();
      case 'RemoveParticipant':
        return $3.RemoveParticipantRequest();
      case 'ListParticipants':
        return $3.ListParticipantsRequest();
      case 'ListSharedBeacons':
        return $3.ListSharedBeaconsRequest();
      case 'ListNearbyBeacons':
        return $3.ListNearbyBeaconsRequest();
      default:
        throw $core.ArgumentError('Unknown method: $methodName');
    }
  }

  $async.Future<$pb.GeneratedMessage> handleCall($pb.ServerContext ctx,
      $core.String methodName, $pb.GeneratedMessage request) {
    switch (methodName) {
      case 'CreateBeacon':
        return createBeacon(ctx, request as $3.CreateBeaconRequest);
      case 'UpdateBeacon':
        return updateBeacon(ctx, request as $3.UpdateBeaconRequest);
      case 'CancelBeacon':
        return cancelBeacon(ctx, request as $3.CancelBeaconRequest);
      case 'GetBeacon':
        return getBeacon(ctx, request as $3.GetBeaconRequest);
      case 'ListBeacons':
        return listBeacons(ctx, request as $3.ListBeaconsRequest);
      case 'ListMyBeacons':
        return listMyBeacons(ctx, request as $3.ListMyBeaconsRequest);
      case 'RequestToJoin':
        return requestToJoin(ctx, request as $3.RequestToJoinRequest);
      case 'WithdrawJoinRequest':
        return withdrawJoinRequest(
            ctx, request as $3.WithdrawJoinRequestRequest);
      case 'RespondToJoinRequest':
        return respondToJoinRequest(
            ctx, request as $3.RespondToJoinRequestRequest);
      case 'LeaveBeacon':
        return leaveBeacon(ctx, request as $3.LeaveBeaconRequest);
      case 'RemoveParticipant':
        return removeParticipant(ctx, request as $3.RemoveParticipantRequest);
      case 'ListParticipants':
        return listParticipants(ctx, request as $3.ListParticipantsRequest);
      case 'ListSharedBeacons':
        return listSharedBeacons(ctx, request as $3.ListSharedBeaconsRequest);
      case 'ListNearbyBeacons':
        return listNearbyBeacons(ctx, request as $3.ListNearbyBeaconsRequest);
      default:
        throw $core.ArgumentError('Unknown method: $methodName');
    }
  }

  $core.Map<$core.String, $core.dynamic> get $json => BeaconServiceBase$json;
  $core.Map<$core.String, $core.Map<$core.String, $core.dynamic>>
      get $messageJson => BeaconServiceBase$messageJson;
}
