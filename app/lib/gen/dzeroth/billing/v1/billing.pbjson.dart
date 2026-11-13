// This is a generated file - do not edit.
//
// Generated from dzeroth/billing/v1/billing.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports
// ignore_for_file: unused_import

import 'dart:convert' as $convert;
import 'dart:core' as $core;
import 'dart:typed_data' as $typed_data;

import 'package:protobuf/well_known_types/google/protobuf/timestamp.pbjson.dart'
    as $0;

@$core.Deprecated('Use subscriptionTierDescriptor instead')
const SubscriptionTier$json = {
  '1': 'SubscriptionTier',
  '2': [
    {'1': 'SUBSCRIPTION_TIER_UNSPECIFIED', '2': 0},
    {'1': 'SUBSCRIPTION_TIER_FREE', '2': 1},
    {'1': 'SUBSCRIPTION_TIER_PLUS', '2': 2},
    {'1': 'SUBSCRIPTION_TIER_PREMIUM', '2': 3},
  ],
};

/// Descriptor for `SubscriptionTier`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List subscriptionTierDescriptor = $convert.base64Decode(
    'ChBTdWJzY3JpcHRpb25UaWVyEiEKHVNVQlNDUklQVElPTl9USUVSX1VOU1BFQ0lGSUVEEAASGg'
    'oWU1VCU0NSSVBUSU9OX1RJRVJfRlJFRRABEhoKFlNVQlNDUklQVElPTl9USUVSX1BMVVMQAhId'
    'ChlTVUJTQ1JJUFRJT05fVElFUl9QUkVNSVVNEAM=');

@$core.Deprecated('Use verificationStateDescriptor instead')
const VerificationState$json = {
  '1': 'VerificationState',
  '2': [
    {'1': 'VERIFICATION_STATE_UNSPECIFIED', '2': 0},
    {'1': 'VERIFICATION_STATE_NO_SUBSCRIPTION', '2': 1},
    {'1': 'VERIFICATION_STATE_VERIFIED', '2': 2},
    {'1': 'VERIFICATION_STATE_UNAVAILABLE', '2': 3},
  ],
};

/// Descriptor for `VerificationState`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List verificationStateDescriptor = $convert.base64Decode(
    'ChFWZXJpZmljYXRpb25TdGF0ZRIiCh5WRVJJRklDQVRJT05fU1RBVEVfVU5TUEVDSUZJRUQQAB'
    'ImCiJWRVJJRklDQVRJT05fU1RBVEVfTk9fU1VCU0NSSVBUSU9OEAESHwobVkVSSUZJQ0FUSU9O'
    'X1NUQVRFX1ZFUklGSUVEEAISIgoeVkVSSUZJQ0FUSU9OX1NUQVRFX1VOQVZBSUxBQkxFEAM=');

@$core.Deprecated('Use getMySubscriptionRequestDescriptor instead')
const GetMySubscriptionRequest$json = {
  '1': 'GetMySubscriptionRequest',
};

/// Descriptor for `GetMySubscriptionRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getMySubscriptionRequestDescriptor =
    $convert.base64Decode('ChhHZXRNeVN1YnNjcmlwdGlvblJlcXVlc3Q=');

@$core.Deprecated('Use getMySubscriptionResponseDescriptor instead')
const GetMySubscriptionResponse$json = {
  '1': 'GetMySubscriptionResponse',
  '2': [
    {
      '1': 'tier',
      '3': 1,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.billing.v1.SubscriptionTier',
      '10': 'tier'
    },
    {
      '1': 'verification_state',
      '3': 2,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.billing.v1.VerificationState',
      '10': 'verificationState'
    },
    {
      '1': 'verified_at',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '10': 'verifiedAt'
    },
    {
      '1': 'access_until',
      '3': 4,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '10': 'accessUntil'
    },
    {'1': 'policy_version', '3': 5, '4': 1, '5': 5, '10': 'policyVersion'},
    {
      '1': 'purchases_available',
      '3': 6,
      '4': 1,
      '5': 8,
      '10': 'purchasesAvailable'
    },
  ],
};

/// Descriptor for `GetMySubscriptionResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getMySubscriptionResponseDescriptor = $convert.base64Decode(
    'ChlHZXRNeVN1YnNjcmlwdGlvblJlc3BvbnNlEjgKBHRpZXIYASABKA4yJC5kemVyb3RoLmJpbG'
    'xpbmcudjEuU3Vic2NyaXB0aW9uVGllclIEdGllchJUChJ2ZXJpZmljYXRpb25fc3RhdGUYAiAB'
    'KA4yJS5kemVyb3RoLmJpbGxpbmcudjEuVmVyaWZpY2F0aW9uU3RhdGVSEXZlcmlmaWNhdGlvbl'
    'N0YXRlEjsKC3ZlcmlmaWVkX2F0GAMgASgLMhouZ29vZ2xlLnByb3RvYnVmLlRpbWVzdGFtcFIK'
    'dmVyaWZpZWRBdBI9CgxhY2Nlc3NfdW50aWwYBCABKAsyGi5nb29nbGUucHJvdG9idWYuVGltZX'
    'N0YW1wUgthY2Nlc3NVbnRpbBIlCg5wb2xpY3lfdmVyc2lvbhgFIAEoBVINcG9saWN5VmVyc2lv'
    'bhIvChNwdXJjaGFzZXNfYXZhaWxhYmxlGAYgASgIUhJwdXJjaGFzZXNBdmFpbGFibGU=');

@$core.Deprecated('Use getAvailablePlansRequestDescriptor instead')
const GetAvailablePlansRequest$json = {
  '1': 'GetAvailablePlansRequest',
};

/// Descriptor for `GetAvailablePlansRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getAvailablePlansRequestDescriptor =
    $convert.base64Decode('ChhHZXRBdmFpbGFibGVQbGFuc1JlcXVlc3Q=');

@$core.Deprecated('Use getAvailablePlansResponseDescriptor instead')
const GetAvailablePlansResponse$json = {
  '1': 'GetAvailablePlansResponse',
  '2': [
    {
      '1': 'plans',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.billing.v1.SubscriptionPlan',
      '10': 'plans'
    },
  ],
};

/// Descriptor for `GetAvailablePlansResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getAvailablePlansResponseDescriptor =
    $convert.base64Decode(
        'ChlHZXRBdmFpbGFibGVQbGFuc1Jlc3BvbnNlEjoKBXBsYW5zGAEgAygLMiQuZHplcm90aC5iaW'
        'xsaW5nLnYxLlN1YnNjcmlwdGlvblBsYW5SBXBsYW5z');

@$core.Deprecated('Use subscriptionPlanDescriptor instead')
const SubscriptionPlan$json = {
  '1': 'SubscriptionPlan',
  '2': [
    {
      '1': 'tier',
      '3': 1,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.billing.v1.SubscriptionTier',
      '10': 'tier'
    },
    {'1': 'entitlement_id', '3': 2, '4': 1, '5': 9, '10': 'entitlementId'},
    {'1': 'period', '3': 3, '4': 1, '5': 9, '10': 'period'},
    {'1': 'purchasable', '3': 4, '4': 1, '5': 8, '10': 'purchasable'},
  ],
};

/// Descriptor for `SubscriptionPlan`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List subscriptionPlanDescriptor = $convert.base64Decode(
    'ChBTdWJzY3JpcHRpb25QbGFuEjgKBHRpZXIYASABKA4yJC5kemVyb3RoLmJpbGxpbmcudjEuU3'
    'Vic2NyaXB0aW9uVGllclIEdGllchIlCg5lbnRpdGxlbWVudF9pZBgCIAEoCVINZW50aXRsZW1l'
    'bnRJZBIWCgZwZXJpb2QYAyABKAlSBnBlcmlvZBIgCgtwdXJjaGFzYWJsZRgEIAEoCFILcHVyY2'
    'hhc2FibGU=');

@$core.Deprecated('Use ensureBillingIdentityRequestDescriptor instead')
const EnsureBillingIdentityRequest$json = {
  '1': 'EnsureBillingIdentityRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
  ],
};

/// Descriptor for `EnsureBillingIdentityRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List ensureBillingIdentityRequestDescriptor =
    $convert.base64Decode(
        'ChxFbnN1cmVCaWxsaW5nSWRlbnRpdHlSZXF1ZXN0EicKD2lkZW1wb3RlbmN5X2tleRgBIAEoCV'
        'IOaWRlbXBvdGVuY3lLZXk=');

@$core.Deprecated('Use ensureBillingIdentityResponseDescriptor instead')
const EnsureBillingIdentityResponse$json = {
  '1': 'EnsureBillingIdentityResponse',
  '2': [
    {'1': 'app_user_id', '3': 1, '4': 1, '5': 9, '10': 'appUserId'},
  ],
};

/// Descriptor for `EnsureBillingIdentityResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List ensureBillingIdentityResponseDescriptor =
    $convert.base64Decode(
        'Ch1FbnN1cmVCaWxsaW5nSWRlbnRpdHlSZXNwb25zZRIeCgthcHBfdXNlcl9pZBgBIAEoCVIJYX'
        'BwVXNlcklk');

const $core.Map<$core.String, $core.dynamic> BillingServiceBase$json = {
  '1': 'BillingService',
  '2': [
    {
      '1': 'GetMySubscription',
      '2': '.dzeroth.billing.v1.GetMySubscriptionRequest',
      '3': '.dzeroth.billing.v1.GetMySubscriptionResponse'
    },
    {
      '1': 'GetAvailablePlans',
      '2': '.dzeroth.billing.v1.GetAvailablePlansRequest',
      '3': '.dzeroth.billing.v1.GetAvailablePlansResponse'
    },
    {
      '1': 'EnsureBillingIdentity',
      '2': '.dzeroth.billing.v1.EnsureBillingIdentityRequest',
      '3': '.dzeroth.billing.v1.EnsureBillingIdentityResponse'
    },
  ],
};

@$core.Deprecated('Use billingServiceDescriptor instead')
const $core.Map<$core.String, $core.Map<$core.String, $core.dynamic>>
    BillingServiceBase$messageJson = {
  '.dzeroth.billing.v1.GetMySubscriptionRequest': GetMySubscriptionRequest$json,
  '.dzeroth.billing.v1.GetMySubscriptionResponse':
      GetMySubscriptionResponse$json,
  '.google.protobuf.Timestamp': $0.Timestamp$json,
  '.dzeroth.billing.v1.GetAvailablePlansRequest': GetAvailablePlansRequest$json,
  '.dzeroth.billing.v1.GetAvailablePlansResponse':
      GetAvailablePlansResponse$json,
  '.dzeroth.billing.v1.SubscriptionPlan': SubscriptionPlan$json,
  '.dzeroth.billing.v1.EnsureBillingIdentityRequest':
      EnsureBillingIdentityRequest$json,
  '.dzeroth.billing.v1.EnsureBillingIdentityResponse':
      EnsureBillingIdentityResponse$json,
};

/// Descriptor for `BillingService`. Decode as a `google.protobuf.ServiceDescriptorProto`.
final $typed_data.Uint8List billingServiceDescriptor = $convert.base64Decode(
    'Cg5CaWxsaW5nU2VydmljZRJwChFHZXRNeVN1YnNjcmlwdGlvbhIsLmR6ZXJvdGguYmlsbGluZy'
    '52MS5HZXRNeVN1YnNjcmlwdGlvblJlcXVlc3QaLS5kemVyb3RoLmJpbGxpbmcudjEuR2V0TXlT'
    'dWJzY3JpcHRpb25SZXNwb25zZRJwChFHZXRBdmFpbGFibGVQbGFucxIsLmR6ZXJvdGguYmlsbG'
    'luZy52MS5HZXRBdmFpbGFibGVQbGFuc1JlcXVlc3QaLS5kemVyb3RoLmJpbGxpbmcudjEuR2V0'
    'QXZhaWxhYmxlUGxhbnNSZXNwb25zZRJ8ChVFbnN1cmVCaWxsaW5nSWRlbnRpdHkSMC5kemVyb3'
    'RoLmJpbGxpbmcudjEuRW5zdXJlQmlsbGluZ0lkZW50aXR5UmVxdWVzdBoxLmR6ZXJvdGguYmls'
    'bGluZy52MS5FbnN1cmVCaWxsaW5nSWRlbnRpdHlSZXNwb25zZQ==');
