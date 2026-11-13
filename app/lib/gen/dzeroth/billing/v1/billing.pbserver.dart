// This is a generated file - do not edit.
//
// Generated from dzeroth/billing/v1/billing.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:async' as $async;
import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

import 'billing.pb.dart' as $1;
import 'billing.pbjson.dart';

export 'billing.pb.dart';

abstract class BillingServiceBase extends $pb.GeneratedService {
  $async.Future<$1.GetMySubscriptionResponse> getMySubscription(
      $pb.ServerContext ctx, $1.GetMySubscriptionRequest request);
  $async.Future<$1.GetAvailablePlansResponse> getAvailablePlans(
      $pb.ServerContext ctx, $1.GetAvailablePlansRequest request);
  $async.Future<$1.EnsureBillingIdentityResponse> ensureBillingIdentity(
      $pb.ServerContext ctx, $1.EnsureBillingIdentityRequest request);

  $pb.GeneratedMessage createRequest($core.String methodName) {
    switch (methodName) {
      case 'GetMySubscription':
        return $1.GetMySubscriptionRequest();
      case 'GetAvailablePlans':
        return $1.GetAvailablePlansRequest();
      case 'EnsureBillingIdentity':
        return $1.EnsureBillingIdentityRequest();
      default:
        throw $core.ArgumentError('Unknown method: $methodName');
    }
  }

  $async.Future<$pb.GeneratedMessage> handleCall($pb.ServerContext ctx,
      $core.String methodName, $pb.GeneratedMessage request) {
    switch (methodName) {
      case 'GetMySubscription':
        return getMySubscription(ctx, request as $1.GetMySubscriptionRequest);
      case 'GetAvailablePlans':
        return getAvailablePlans(ctx, request as $1.GetAvailablePlansRequest);
      case 'EnsureBillingIdentity':
        return ensureBillingIdentity(
            ctx, request as $1.EnsureBillingIdentityRequest);
      default:
        throw $core.ArgumentError('Unknown method: $methodName');
    }
  }

  $core.Map<$core.String, $core.dynamic> get $json => BillingServiceBase$json;
  $core.Map<$core.String, $core.Map<$core.String, $core.dynamic>>
      get $messageJson => BillingServiceBase$messageJson;
}
