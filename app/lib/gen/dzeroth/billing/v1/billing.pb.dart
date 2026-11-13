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
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart'
    as $0;

import 'billing.pbenum.dart';

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

export 'billing.pbenum.dart';

class GetMySubscriptionRequest extends $pb.GeneratedMessage {
  factory GetMySubscriptionRequest() => GetMySubscriptionRequest._();

  GetMySubscriptionRequest._();

  factory GetMySubscriptionRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetMySubscriptionRequest()..mergeFromBuffer(data, registry);
  factory GetMySubscriptionRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetMySubscriptionRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetMySubscriptionRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.billing.v1'),
      createEmptyInstance: GetMySubscriptionRequest.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetMySubscriptionRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetMySubscriptionRequest copyWith(
          void Function(GetMySubscriptionRequest) updates) =>
      super.copyWith((message) => updates(message as GetMySubscriptionRequest))
          as GetMySubscriptionRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use GetMySubscriptionRequest() / GetMySubscriptionRequest.new instead')
  static GetMySubscriptionRequest create() => GetMySubscriptionRequest._();
  static $pb.GeneratedMessage $_createMessage() => GetMySubscriptionRequest._();
  @$core.override
  GetMySubscriptionRequest createEmptyInstance() =>
      GetMySubscriptionRequest._();
  @$core.pragma('dart2js:noInline')
  static GetMySubscriptionRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<GetMySubscriptionRequest>(
          GetMySubscriptionRequest.$_createMessage);
  static GetMySubscriptionRequest? _defaultInstance;
}

class GetMySubscriptionResponse extends $pb.GeneratedMessage {
  factory GetMySubscriptionResponse({
    SubscriptionTier? tier,
    VerificationState? verificationState,
    $0.Timestamp? verifiedAt,
    $0.Timestamp? accessUntil,
    $core.int? policyVersion,
    $core.bool? purchasesAvailable,
  }) {
    final result = GetMySubscriptionResponse._();
    if (tier != null) result.tier = tier;
    if (verificationState != null) result.verificationState = verificationState;
    if (verifiedAt != null) result.verifiedAt = verifiedAt;
    if (accessUntil != null) result.accessUntil = accessUntil;
    if (policyVersion != null) result.policyVersion = policyVersion;
    if (purchasesAvailable != null)
      result.purchasesAvailable = purchasesAvailable;
    return result;
  }

  GetMySubscriptionResponse._();

  factory GetMySubscriptionResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetMySubscriptionResponse()..mergeFromBuffer(data, registry);
  factory GetMySubscriptionResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetMySubscriptionResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetMySubscriptionResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.billing.v1'),
      createEmptyInstance: GetMySubscriptionResponse.$_createMessage)
    ..aE<SubscriptionTier>(1, _omitFieldNames ? '' : 'tier',
        enumValues: SubscriptionTier.values)
    ..aE<VerificationState>(2, _omitFieldNames ? '' : 'verificationState',
        enumValues: VerificationState.values)
    ..aOM<$0.Timestamp>(3, _omitFieldNames ? '' : 'verifiedAt',
        subBuilder: $0.Timestamp.$_createMessage)
    ..aOM<$0.Timestamp>(4, _omitFieldNames ? '' : 'accessUntil',
        subBuilder: $0.Timestamp.$_createMessage)
    ..aI(5, _omitFieldNames ? '' : 'policyVersion')
    ..aOB(6, _omitFieldNames ? '' : 'purchasesAvailable')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetMySubscriptionResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetMySubscriptionResponse copyWith(
          void Function(GetMySubscriptionResponse) updates) =>
      super.copyWith((message) => updates(message as GetMySubscriptionResponse))
          as GetMySubscriptionResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use GetMySubscriptionResponse() / GetMySubscriptionResponse.new instead')
  static GetMySubscriptionResponse create() => GetMySubscriptionResponse._();
  static $pb.GeneratedMessage $_createMessage() =>
      GetMySubscriptionResponse._();
  @$core.override
  GetMySubscriptionResponse createEmptyInstance() =>
      GetMySubscriptionResponse._();
  @$core.pragma('dart2js:noInline')
  static GetMySubscriptionResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<GetMySubscriptionResponse>(
          GetMySubscriptionResponse.$_createMessage);
  static GetMySubscriptionResponse? _defaultInstance;

  @$pb.TagNumber(1)
  SubscriptionTier get tier => $_getN(0);
  @$pb.TagNumber(1)
  set tier(SubscriptionTier value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasTier() => $_has(0);
  @$pb.TagNumber(1)
  void clearTier() => $_clearField(1);

  @$pb.TagNumber(2)
  VerificationState get verificationState => $_getN(1);
  @$pb.TagNumber(2)
  set verificationState(VerificationState value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasVerificationState() => $_has(1);
  @$pb.TagNumber(2)
  void clearVerificationState() => $_clearField(2);

  @$pb.TagNumber(3)
  $0.Timestamp get verifiedAt => $_getN(2);
  @$pb.TagNumber(3)
  set verifiedAt($0.Timestamp value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasVerifiedAt() => $_has(2);
  @$pb.TagNumber(3)
  void clearVerifiedAt() => $_clearField(3);
  @$pb.TagNumber(3)
  $0.Timestamp ensureVerifiedAt() => $_ensure(2);

  @$pb.TagNumber(4)
  $0.Timestamp get accessUntil => $_getN(3);
  @$pb.TagNumber(4)
  set accessUntil($0.Timestamp value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasAccessUntil() => $_has(3);
  @$pb.TagNumber(4)
  void clearAccessUntil() => $_clearField(4);
  @$pb.TagNumber(4)
  $0.Timestamp ensureAccessUntil() => $_ensure(3);

  @$pb.TagNumber(5)
  $core.int get policyVersion => $_getIZ(4);
  @$pb.TagNumber(5)
  set policyVersion($core.int value) => $_setSignedInt32(4, value);
  @$pb.TagNumber(5)
  $core.bool hasPolicyVersion() => $_has(4);
  @$pb.TagNumber(5)
  void clearPolicyVersion() => $_clearField(5);

  @$pb.TagNumber(6)
  $core.bool get purchasesAvailable => $_getBF(5);
  @$pb.TagNumber(6)
  set purchasesAvailable($core.bool value) => $_setBool(5, value);
  @$pb.TagNumber(6)
  $core.bool hasPurchasesAvailable() => $_has(5);
  @$pb.TagNumber(6)
  void clearPurchasesAvailable() => $_clearField(6);
}

class GetAvailablePlansRequest extends $pb.GeneratedMessage {
  factory GetAvailablePlansRequest() => GetAvailablePlansRequest._();

  GetAvailablePlansRequest._();

  factory GetAvailablePlansRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetAvailablePlansRequest()..mergeFromBuffer(data, registry);
  factory GetAvailablePlansRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetAvailablePlansRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetAvailablePlansRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.billing.v1'),
      createEmptyInstance: GetAvailablePlansRequest.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetAvailablePlansRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetAvailablePlansRequest copyWith(
          void Function(GetAvailablePlansRequest) updates) =>
      super.copyWith((message) => updates(message as GetAvailablePlansRequest))
          as GetAvailablePlansRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use GetAvailablePlansRequest() / GetAvailablePlansRequest.new instead')
  static GetAvailablePlansRequest create() => GetAvailablePlansRequest._();
  static $pb.GeneratedMessage $_createMessage() => GetAvailablePlansRequest._();
  @$core.override
  GetAvailablePlansRequest createEmptyInstance() =>
      GetAvailablePlansRequest._();
  @$core.pragma('dart2js:noInline')
  static GetAvailablePlansRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<GetAvailablePlansRequest>(
          GetAvailablePlansRequest.$_createMessage);
  static GetAvailablePlansRequest? _defaultInstance;
}

class GetAvailablePlansResponse extends $pb.GeneratedMessage {
  factory GetAvailablePlansResponse({
    $core.Iterable<SubscriptionPlan>? plans,
  }) {
    final result = GetAvailablePlansResponse._();
    if (plans != null) result.plans.addAll(plans);
    return result;
  }

  GetAvailablePlansResponse._();

  factory GetAvailablePlansResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetAvailablePlansResponse()..mergeFromBuffer(data, registry);
  factory GetAvailablePlansResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetAvailablePlansResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetAvailablePlansResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.billing.v1'),
      createEmptyInstance: GetAvailablePlansResponse.$_createMessage)
    ..pPM<SubscriptionPlan>(1, _omitFieldNames ? '' : 'plans',
        subBuilder: SubscriptionPlan.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetAvailablePlansResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetAvailablePlansResponse copyWith(
          void Function(GetAvailablePlansResponse) updates) =>
      super.copyWith((message) => updates(message as GetAvailablePlansResponse))
          as GetAvailablePlansResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use GetAvailablePlansResponse() / GetAvailablePlansResponse.new instead')
  static GetAvailablePlansResponse create() => GetAvailablePlansResponse._();
  static $pb.GeneratedMessage $_createMessage() =>
      GetAvailablePlansResponse._();
  @$core.override
  GetAvailablePlansResponse createEmptyInstance() =>
      GetAvailablePlansResponse._();
  @$core.pragma('dart2js:noInline')
  static GetAvailablePlansResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<GetAvailablePlansResponse>(
          GetAvailablePlansResponse.$_createMessage);
  static GetAvailablePlansResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<SubscriptionPlan> get plans => $_getList(0);
}

class SubscriptionPlan extends $pb.GeneratedMessage {
  factory SubscriptionPlan({
    SubscriptionTier? tier,
    $core.String? entitlementId,
    $core.String? period,
    $core.bool? purchasable,
  }) {
    final result = SubscriptionPlan._();
    if (tier != null) result.tier = tier;
    if (entitlementId != null) result.entitlementId = entitlementId;
    if (period != null) result.period = period;
    if (purchasable != null) result.purchasable = purchasable;
    return result;
  }

  SubscriptionPlan._();

  factory SubscriptionPlan.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SubscriptionPlan()..mergeFromBuffer(data, registry);
  factory SubscriptionPlan.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SubscriptionPlan()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'SubscriptionPlan',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.billing.v1'),
      createEmptyInstance: SubscriptionPlan.$_createMessage)
    ..aE<SubscriptionTier>(1, _omitFieldNames ? '' : 'tier',
        enumValues: SubscriptionTier.values)
    ..aOS(2, _omitFieldNames ? '' : 'entitlementId')
    ..aOS(3, _omitFieldNames ? '' : 'period')
    ..aOB(4, _omitFieldNames ? '' : 'purchasable')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SubscriptionPlan clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SubscriptionPlan copyWith(void Function(SubscriptionPlan) updates) =>
      super.copyWith((message) => updates(message as SubscriptionPlan))
          as SubscriptionPlan;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use SubscriptionPlan() / SubscriptionPlan.new instead')
  static SubscriptionPlan create() => SubscriptionPlan._();
  static $pb.GeneratedMessage $_createMessage() => SubscriptionPlan._();
  @$core.override
  SubscriptionPlan createEmptyInstance() => SubscriptionPlan._();
  @$core.pragma('dart2js:noInline')
  static SubscriptionPlan getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<SubscriptionPlan>(
          SubscriptionPlan.$_createMessage);
  static SubscriptionPlan? _defaultInstance;

  @$pb.TagNumber(1)
  SubscriptionTier get tier => $_getN(0);
  @$pb.TagNumber(1)
  set tier(SubscriptionTier value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasTier() => $_has(0);
  @$pb.TagNumber(1)
  void clearTier() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get entitlementId => $_getSZ(1);
  @$pb.TagNumber(2)
  set entitlementId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasEntitlementId() => $_has(1);
  @$pb.TagNumber(2)
  void clearEntitlementId() => $_clearField(2);

  /// Informational logical period: "monthly". Annual is not offered yet.
  @$pb.TagNumber(3)
  $core.String get period => $_getSZ(2);
  @$pb.TagNumber(3)
  set period($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasPeriod() => $_has(2);
  @$pb.TagNumber(3)
  void clearPeriod() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.bool get purchasable => $_getBF(3);
  @$pb.TagNumber(4)
  set purchasable($core.bool value) => $_setBool(3, value);
  @$pb.TagNumber(4)
  $core.bool hasPurchasable() => $_has(3);
  @$pb.TagNumber(4)
  void clearPurchasable() => $_clearField(4);
}

class EnsureBillingIdentityRequest extends $pb.GeneratedMessage {
  factory EnsureBillingIdentityRequest({
    $core.String? idempotencyKey,
  }) {
    final result = EnsureBillingIdentityRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    return result;
  }

  EnsureBillingIdentityRequest._();

  factory EnsureBillingIdentityRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      EnsureBillingIdentityRequest()..mergeFromBuffer(data, registry);
  factory EnsureBillingIdentityRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      EnsureBillingIdentityRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'EnsureBillingIdentityRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.billing.v1'),
      createEmptyInstance: EnsureBillingIdentityRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  EnsureBillingIdentityRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  EnsureBillingIdentityRequest copyWith(
          void Function(EnsureBillingIdentityRequest) updates) =>
      super.copyWith(
              (message) => updates(message as EnsureBillingIdentityRequest))
          as EnsureBillingIdentityRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use EnsureBillingIdentityRequest() / EnsureBillingIdentityRequest.new instead')
  static EnsureBillingIdentityRequest create() =>
      EnsureBillingIdentityRequest._();
  static $pb.GeneratedMessage $_createMessage() =>
      EnsureBillingIdentityRequest._();
  @$core.override
  EnsureBillingIdentityRequest createEmptyInstance() =>
      EnsureBillingIdentityRequest._();
  @$core.pragma('dart2js:noInline')
  static EnsureBillingIdentityRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<EnsureBillingIdentityRequest>(
          EnsureBillingIdentityRequest.$_createMessage);
  static EnsureBillingIdentityRequest? _defaultInstance;

  /// Standard repository idempotency key: 16..64 [A-Za-z0-9_-]. The natural-key
  /// binding is reused across all keys, devices and retries for the same owner.
  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);
}

class EnsureBillingIdentityResponse extends $pb.GeneratedMessage {
  factory EnsureBillingIdentityResponse({
    $core.String? appUserId,
  }) {
    final result = EnsureBillingIdentityResponse._();
    if (appUserId != null) result.appUserId = appUserId;
    return result;
  }

  EnsureBillingIdentityResponse._();

  factory EnsureBillingIdentityResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      EnsureBillingIdentityResponse()..mergeFromBuffer(data, registry);
  factory EnsureBillingIdentityResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      EnsureBillingIdentityResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'EnsureBillingIdentityResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.billing.v1'),
      createEmptyInstance: EnsureBillingIdentityResponse.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'appUserId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  EnsureBillingIdentityResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  EnsureBillingIdentityResponse copyWith(
          void Function(EnsureBillingIdentityResponse) updates) =>
      super.copyWith(
              (message) => updates(message as EnsureBillingIdentityResponse))
          as EnsureBillingIdentityResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use EnsureBillingIdentityResponse() / EnsureBillingIdentityResponse.new instead')
  static EnsureBillingIdentityResponse create() =>
      EnsureBillingIdentityResponse._();
  static $pb.GeneratedMessage $_createMessage() =>
      EnsureBillingIdentityResponse._();
  @$core.override
  EnsureBillingIdentityResponse createEmptyInstance() =>
      EnsureBillingIdentityResponse._();
  @$core.pragma('dart2js:noInline')
  static EnsureBillingIdentityResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<EnsureBillingIdentityResponse>(
          EnsureBillingIdentityResponse.$_createMessage);
  static EnsureBillingIdentityResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get appUserId => $_getSZ(0);
  @$pb.TagNumber(1)
  set appUserId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasAppUserId() => $_has(0);
  @$pb.TagNumber(1)
  void clearAppUserId() => $_clearField(1);
}

class BillingServiceApi {
  final $pb.RpcClient _client;

  BillingServiceApi(this._client);

  /// A missing subscription is Free; unavailable verification is explicitly
  /// reported as unknown, never silently converted to a confirmed Free tier.
  $async.Future<GetMySubscriptionResponse> getMySubscription(
          $pb.ClientContext? ctx, GetMySubscriptionRequest request) =>
      _client.invoke<GetMySubscriptionResponse>(ctx, 'BillingService',
          'GetMySubscription', request, GetMySubscriptionResponse());

  /// Informational plan catalog. Localized provider/store data, not this message,
  /// is the purchase price authority. No plan is purchasable during foundation.
  $async.Future<GetAvailablePlansResponse> getAvailablePlans(
          $pb.ClientContext? ctx, GetAvailablePlansRequest request) =>
      _client.invoke<GetAvailablePlansResponse>(ctx, 'BillingService',
          'GetAvailablePlans', request, GetAvailablePlansResponse());

  /// Idempotent allocation/lookup for this authenticated active account only.
  /// The returned opaque ID is PRIVATE; never put it in profiles, logs, analytics
  /// or shared URLs. This RPC alone does not enable a purchase or grant access.
  $async.Future<EnsureBillingIdentityResponse> ensureBillingIdentity(
          $pb.ClientContext? ctx, EnsureBillingIdentityRequest request) =>
      _client.invoke<EnsureBillingIdentityResponse>(ctx, 'BillingService',
          'EnsureBillingIdentity', request, EnsureBillingIdentityResponse());
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
