// This is a generated file - do not edit.
//
// Generated from dzeroth/billing/v1/billing.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

class SubscriptionTier extends $pb.ProtobufEnum {
  static const SubscriptionTier SUBSCRIPTION_TIER_UNSPECIFIED =
      SubscriptionTier._(
          0, _omitEnumNames ? '' : 'SUBSCRIPTION_TIER_UNSPECIFIED');
  static const SubscriptionTier SUBSCRIPTION_TIER_FREE =
      SubscriptionTier._(1, _omitEnumNames ? '' : 'SUBSCRIPTION_TIER_FREE');
  static const SubscriptionTier SUBSCRIPTION_TIER_PLUS =
      SubscriptionTier._(2, _omitEnumNames ? '' : 'SUBSCRIPTION_TIER_PLUS');
  static const SubscriptionTier SUBSCRIPTION_TIER_PREMIUM =
      SubscriptionTier._(3, _omitEnumNames ? '' : 'SUBSCRIPTION_TIER_PREMIUM');

  static const $core.List<SubscriptionTier> values = <SubscriptionTier>[
    SUBSCRIPTION_TIER_UNSPECIFIED,
    SUBSCRIPTION_TIER_FREE,
    SUBSCRIPTION_TIER_PLUS,
    SUBSCRIPTION_TIER_PREMIUM,
  ];

  static final $core.List<SubscriptionTier?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 3);
  static SubscriptionTier? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const SubscriptionTier._(super.value, super.name);
}

class VerificationState extends $pb.ProtobufEnum {
  static const VerificationState VERIFICATION_STATE_UNSPECIFIED =
      VerificationState._(
          0, _omitEnumNames ? '' : 'VERIFICATION_STATE_UNSPECIFIED');
  static const VerificationState VERIFICATION_STATE_NO_SUBSCRIPTION =
      VerificationState._(
          1, _omitEnumNames ? '' : 'VERIFICATION_STATE_NO_SUBSCRIPTION');
  static const VerificationState VERIFICATION_STATE_VERIFIED =
      VerificationState._(
          2, _omitEnumNames ? '' : 'VERIFICATION_STATE_VERIFIED');
  static const VerificationState VERIFICATION_STATE_UNAVAILABLE =
      VerificationState._(
          3, _omitEnumNames ? '' : 'VERIFICATION_STATE_UNAVAILABLE');

  static const $core.List<VerificationState> values = <VerificationState>[
    VERIFICATION_STATE_UNSPECIFIED,
    VERIFICATION_STATE_NO_SUBSCRIPTION,
    VERIFICATION_STATE_VERIFIED,
    VERIFICATION_STATE_UNAVAILABLE,
  ];

  static final $core.List<VerificationState?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 3);
  static VerificationState? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const VerificationState._(super.value, super.name);
}

const $core.bool _omitEnumNames =
    $core.bool.fromEnvironment('protobuf.omit_enum_names');
