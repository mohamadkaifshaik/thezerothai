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

import 'package:fixnum/fixnum.dart' as $fixnum;
import 'package:protobuf/protobuf.dart' as $pb;
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart'
    as $0;

import 'identity.pbenum.dart';

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

export 'identity.pbenum.dart';

class Profile extends $pb.GeneratedMessage {
  factory Profile({
    $core.String? userId,
    $core.String? handle,
    $core.String? displayName,
    $core.String? bio,
    $core.String? avatarUrl,
    $core.String? avatarThumbUrl,
    $core.bool? isPrivate,
    $core.bool? verified,
    $fixnum.Int64? followersCount,
    $fixnum.Int64? followingCount,
    $fixnum.Int64? postsCount,
    $0.Timestamp? createdAt,
  }) {
    final result = Profile._();
    if (userId != null) result.userId = userId;
    if (handle != null) result.handle = handle;
    if (displayName != null) result.displayName = displayName;
    if (bio != null) result.bio = bio;
    if (avatarUrl != null) result.avatarUrl = avatarUrl;
    if (avatarThumbUrl != null) result.avatarThumbUrl = avatarThumbUrl;
    if (isPrivate != null) result.isPrivate = isPrivate;
    if (verified != null) result.verified = verified;
    if (followersCount != null) result.followersCount = followersCount;
    if (followingCount != null) result.followingCount = followingCount;
    if (postsCount != null) result.postsCount = postsCount;
    if (createdAt != null) result.createdAt = createdAt;
    return result;
  }

  Profile._();

  factory Profile.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Profile()..mergeFromBuffer(data, registry);
  factory Profile.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Profile()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Profile',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.identity.v1'),
      createEmptyInstance: Profile.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'userId')
    ..aOS(2, _omitFieldNames ? '' : 'handle')
    ..aOS(3, _omitFieldNames ? '' : 'displayName')
    ..aOS(4, _omitFieldNames ? '' : 'bio')
    ..aOS(5, _omitFieldNames ? '' : 'avatarUrl')
    ..aOS(6, _omitFieldNames ? '' : 'avatarThumbUrl')
    ..aOB(7, _omitFieldNames ? '' : 'isPrivate')
    ..aOB(8, _omitFieldNames ? '' : 'verified')
    ..aInt64(9, _omitFieldNames ? '' : 'followersCount')
    ..aInt64(10, _omitFieldNames ? '' : 'followingCount')
    ..aInt64(11, _omitFieldNames ? '' : 'postsCount')
    ..aOM<$0.Timestamp>(12, _omitFieldNames ? '' : 'createdAt',
        subBuilder: $0.Timestamp.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Profile clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Profile copyWith(void Function(Profile) updates) =>
      super.copyWith((message) => updates(message as Profile)) as Profile;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Profile() / Profile.new instead')
  static Profile create() => Profile._();
  static $pb.GeneratedMessage $_createMessage() => Profile._();
  @$core.override
  Profile createEmptyInstance() => Profile._();
  @$core.pragma('dart2js:noInline')
  static Profile getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Profile>(Profile.$_createMessage);
  static Profile? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get userId => $_getSZ(0);
  @$pb.TagNumber(1)
  set userId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasUserId() => $_has(0);
  @$pb.TagNumber(1)
  void clearUserId() => $_clearField(1);

  /// Display form; uniqueness is on the lower-cased form. 3-15 chars, [A-Za-z0-9_].
  @$pb.TagNumber(2)
  $core.String get handle => $_getSZ(1);
  @$pb.TagNumber(2)
  set handle($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasHandle() => $_has(1);
  @$pb.TagNumber(2)
  void clearHandle() => $_clearField(2);

  /// 1-50 chars after NFC normalization.
  @$pb.TagNumber(3)
  $core.String get displayName => $_getSZ(2);
  @$pb.TagNumber(3)
  set displayName($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasDisplayName() => $_has(2);
  @$pb.TagNumber(3)
  void clearDisplayName() => $_clearField(3);

  /// <= 160 chars.
  @$pb.TagNumber(4)
  $core.String get bio => $_getSZ(3);
  @$pb.TagNumber(4)
  set bio($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasBio() => $_has(3);
  @$pb.TagNumber(4)
  void clearBio() => $_clearField(4);

  /// 400 px avatar; empty if none.
  @$pb.TagNumber(5)
  $core.String get avatarUrl => $_getSZ(4);
  @$pb.TagNumber(5)
  set avatarUrl($core.String value) => $_setString(4, value);
  @$pb.TagNumber(5)
  $core.bool hasAvatarUrl() => $_has(4);
  @$pb.TagNumber(5)
  void clearAvatarUrl() => $_clearField(5);

  /// 96 px avatar for lists; empty if none.
  @$pb.TagNumber(6)
  $core.String get avatarThumbUrl => $_getSZ(5);
  @$pb.TagNumber(6)
  set avatarThumbUrl($core.String value) => $_setString(5, value);
  @$pb.TagNumber(6)
  $core.bool hasAvatarThumbUrl() => $_has(5);
  @$pb.TagNumber(6)
  void clearAvatarThumbUrl() => $_clearField(6);

  /// Always false until private accounts ship (ADR-0008 D1).
  @$pb.TagNumber(7)
  $core.bool get isPrivate => $_getBF(6);
  @$pb.TagNumber(7)
  set isPrivate($core.bool value) => $_setBool(6, value);
  @$pb.TagNumber(7)
  $core.bool hasIsPrivate() => $_has(6);
  @$pb.TagNumber(7)
  void clearIsPrivate() => $_clearField(7);

  @$pb.TagNumber(8)
  $core.bool get verified => $_getBF(7);
  @$pb.TagNumber(8)
  set verified($core.bool value) => $_setBool(7, value);
  @$pb.TagNumber(8)
  $core.bool hasVerified() => $_has(7);
  @$pb.TagNumber(8)
  void clearVerified() => $_clearField(8);

  @$pb.TagNumber(9)
  $fixnum.Int64 get followersCount => $_getI64(8);
  @$pb.TagNumber(9)
  set followersCount($fixnum.Int64 value) => $_setInt64(8, value);
  @$pb.TagNumber(9)
  $core.bool hasFollowersCount() => $_has(8);
  @$pb.TagNumber(9)
  void clearFollowersCount() => $_clearField(9);

  @$pb.TagNumber(10)
  $fixnum.Int64 get followingCount => $_getI64(9);
  @$pb.TagNumber(10)
  set followingCount($fixnum.Int64 value) => $_setInt64(9, value);
  @$pb.TagNumber(10)
  $core.bool hasFollowingCount() => $_has(9);
  @$pb.TagNumber(10)
  void clearFollowingCount() => $_clearField(10);

  @$pb.TagNumber(11)
  $fixnum.Int64 get postsCount => $_getI64(10);
  @$pb.TagNumber(11)
  set postsCount($fixnum.Int64 value) => $_setInt64(10, value);
  @$pb.TagNumber(11)
  $core.bool hasPostsCount() => $_has(10);
  @$pb.TagNumber(11)
  void clearPostsCount() => $_clearField(11);

  @$pb.TagNumber(12)
  $0.Timestamp get createdAt => $_getN(11);
  @$pb.TagNumber(12)
  set createdAt($0.Timestamp value) => $_setField(12, value);
  @$pb.TagNumber(12)
  $core.bool hasCreatedAt() => $_has(11);
  @$pb.TagNumber(12)
  void clearCreatedAt() => $_clearField(12);
  @$pb.TagNumber(12)
  $0.Timestamp ensureCreatedAt() => $_ensure(11);
}

class CreateProfileRequest extends $pb.GeneratedMessage {
  factory CreateProfileRequest({
    $core.String? idempotencyKey,
    $core.String? handle,
    $core.String? displayName,
  }) {
    final result = CreateProfileRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (handle != null) result.handle = handle;
    if (displayName != null) result.displayName = displayName;
    return result;
  }

  CreateProfileRequest._();

  factory CreateProfileRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CreateProfileRequest()..mergeFromBuffer(data, registry);
  factory CreateProfileRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CreateProfileRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CreateProfileRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.identity.v1'),
      createEmptyInstance: CreateProfileRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'handle')
    ..aOS(3, _omitFieldNames ? '' : 'displayName')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateProfileRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateProfileRequest copyWith(void Function(CreateProfileRequest) updates) =>
      super.copyWith((message) => updates(message as CreateProfileRequest))
          as CreateProfileRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use CreateProfileRequest() / CreateProfileRequest.new instead')
  static CreateProfileRequest create() => CreateProfileRequest._();
  static $pb.GeneratedMessage $_createMessage() => CreateProfileRequest._();
  @$core.override
  CreateProfileRequest createEmptyInstance() => CreateProfileRequest._();
  @$core.pragma('dart2js:noInline')
  static CreateProfileRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<CreateProfileRequest>(
          CreateProfileRequest.$_createMessage);
  static CreateProfileRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get handle => $_getSZ(1);
  @$pb.TagNumber(2)
  set handle($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasHandle() => $_has(1);
  @$pb.TagNumber(2)
  void clearHandle() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get displayName => $_getSZ(2);
  @$pb.TagNumber(3)
  set displayName($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasDisplayName() => $_has(2);
  @$pb.TagNumber(3)
  void clearDisplayName() => $_clearField(3);
}

class CreateProfileResponse extends $pb.GeneratedMessage {
  factory CreateProfileResponse({
    Profile? profile,
  }) {
    final result = CreateProfileResponse._();
    if (profile != null) result.profile = profile;
    return result;
  }

  CreateProfileResponse._();

  factory CreateProfileResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CreateProfileResponse()..mergeFromBuffer(data, registry);
  factory CreateProfileResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CreateProfileResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CreateProfileResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.identity.v1'),
      createEmptyInstance: CreateProfileResponse.$_createMessage)
    ..aOM<Profile>(1, _omitFieldNames ? '' : 'profile',
        subBuilder: Profile.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateProfileResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateProfileResponse copyWith(
          void Function(CreateProfileResponse) updates) =>
      super.copyWith((message) => updates(message as CreateProfileResponse))
          as CreateProfileResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use CreateProfileResponse() / CreateProfileResponse.new instead')
  static CreateProfileResponse create() => CreateProfileResponse._();
  static $pb.GeneratedMessage $_createMessage() => CreateProfileResponse._();
  @$core.override
  CreateProfileResponse createEmptyInstance() => CreateProfileResponse._();
  @$core.pragma('dart2js:noInline')
  static CreateProfileResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<CreateProfileResponse>(
          CreateProfileResponse.$_createMessage);
  static CreateProfileResponse? _defaultInstance;

  @$pb.TagNumber(1)
  Profile get profile => $_getN(0);
  @$pb.TagNumber(1)
  set profile(Profile value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasProfile() => $_has(0);
  @$pb.TagNumber(1)
  void clearProfile() => $_clearField(1);
  @$pb.TagNumber(1)
  Profile ensureProfile() => $_ensure(0);
}

class CheckHandleAvailabilityRequest extends $pb.GeneratedMessage {
  factory CheckHandleAvailabilityRequest({
    $core.String? handle,
  }) {
    final result = CheckHandleAvailabilityRequest._();
    if (handle != null) result.handle = handle;
    return result;
  }

  CheckHandleAvailabilityRequest._();

  factory CheckHandleAvailabilityRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CheckHandleAvailabilityRequest()..mergeFromBuffer(data, registry);
  factory CheckHandleAvailabilityRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CheckHandleAvailabilityRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CheckHandleAvailabilityRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.identity.v1'),
      createEmptyInstance: CheckHandleAvailabilityRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'handle')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CheckHandleAvailabilityRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CheckHandleAvailabilityRequest copyWith(
          void Function(CheckHandleAvailabilityRequest) updates) =>
      super.copyWith(
              (message) => updates(message as CheckHandleAvailabilityRequest))
          as CheckHandleAvailabilityRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use CheckHandleAvailabilityRequest() / CheckHandleAvailabilityRequest.new instead')
  static CheckHandleAvailabilityRequest create() =>
      CheckHandleAvailabilityRequest._();
  static $pb.GeneratedMessage $_createMessage() =>
      CheckHandleAvailabilityRequest._();
  @$core.override
  CheckHandleAvailabilityRequest createEmptyInstance() =>
      CheckHandleAvailabilityRequest._();
  @$core.pragma('dart2js:noInline')
  static CheckHandleAvailabilityRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<CheckHandleAvailabilityRequest>(
          CheckHandleAvailabilityRequest.$_createMessage);
  static CheckHandleAvailabilityRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get handle => $_getSZ(0);
  @$pb.TagNumber(1)
  set handle($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasHandle() => $_has(0);
  @$pb.TagNumber(1)
  void clearHandle() => $_clearField(1);
}

class CheckHandleAvailabilityResponse extends $pb.GeneratedMessage {
  factory CheckHandleAvailabilityResponse({
    $core.bool? available,
    $core.String? reason,
  }) {
    final result = CheckHandleAvailabilityResponse._();
    if (available != null) result.available = available;
    if (reason != null) result.reason = reason;
    return result;
  }

  CheckHandleAvailabilityResponse._();

  factory CheckHandleAvailabilityResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CheckHandleAvailabilityResponse()..mergeFromBuffer(data, registry);
  factory CheckHandleAvailabilityResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CheckHandleAvailabilityResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CheckHandleAvailabilityResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.identity.v1'),
      createEmptyInstance: CheckHandleAvailabilityResponse.$_createMessage)
    ..aOB(1, _omitFieldNames ? '' : 'available')
    ..aOS(2, _omitFieldNames ? '' : 'reason')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CheckHandleAvailabilityResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CheckHandleAvailabilityResponse copyWith(
          void Function(CheckHandleAvailabilityResponse) updates) =>
      super.copyWith(
              (message) => updates(message as CheckHandleAvailabilityResponse))
          as CheckHandleAvailabilityResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use CheckHandleAvailabilityResponse() / CheckHandleAvailabilityResponse.new instead')
  static CheckHandleAvailabilityResponse create() =>
      CheckHandleAvailabilityResponse._();
  static $pb.GeneratedMessage $_createMessage() =>
      CheckHandleAvailabilityResponse._();
  @$core.override
  CheckHandleAvailabilityResponse createEmptyInstance() =>
      CheckHandleAvailabilityResponse._();
  @$core.pragma('dart2js:noInline')
  static CheckHandleAvailabilityResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<CheckHandleAvailabilityResponse>(
          CheckHandleAvailabilityResponse.$_createMessage);
  static CheckHandleAvailabilityResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $core.bool get available => $_getBF(0);
  @$pb.TagNumber(1)
  set available($core.bool value) => $_setBool(0, value);
  @$pb.TagNumber(1)
  $core.bool hasAvailable() => $_has(0);
  @$pb.TagNumber(1)
  void clearAvailable() => $_clearField(1);

  /// Set when the handle is syntactically invalid or reserved; empty otherwise.
  @$pb.TagNumber(2)
  $core.String get reason => $_getSZ(1);
  @$pb.TagNumber(2)
  set reason($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasReason() => $_has(1);
  @$pb.TagNumber(2)
  void clearReason() => $_clearField(2);
}

class GetMeRequest extends $pb.GeneratedMessage {
  factory GetMeRequest() => GetMeRequest._();

  GetMeRequest._();

  factory GetMeRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetMeRequest()..mergeFromBuffer(data, registry);
  factory GetMeRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetMeRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetMeRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.identity.v1'),
      createEmptyInstance: GetMeRequest.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetMeRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetMeRequest copyWith(void Function(GetMeRequest) updates) =>
      super.copyWith((message) => updates(message as GetMeRequest))
          as GetMeRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use GetMeRequest() / GetMeRequest.new instead')
  static GetMeRequest create() => GetMeRequest._();
  static $pb.GeneratedMessage $_createMessage() => GetMeRequest._();
  @$core.override
  GetMeRequest createEmptyInstance() => GetMeRequest._();
  @$core.pragma('dart2js:noInline')
  static GetMeRequest getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<GetMeRequest>(
          GetMeRequest.$_createMessage);
  static GetMeRequest? _defaultInstance;
}

class GetMeResponse extends $pb.GeneratedMessage {
  factory GetMeResponse({
    Profile? profile,
    AccountStatus? status,
    $core.bool? emailVerified,
    $fixnum.Int64? unreadNotificationCount,
    $core.Iterable<$core.String>? enabledFeatures,
  }) {
    final result = GetMeResponse._();
    if (profile != null) result.profile = profile;
    if (status != null) result.status = status;
    if (emailVerified != null) result.emailVerified = emailVerified;
    if (unreadNotificationCount != null)
      result.unreadNotificationCount = unreadNotificationCount;
    if (enabledFeatures != null) result.enabledFeatures.addAll(enabledFeatures);
    return result;
  }

  GetMeResponse._();

  factory GetMeResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetMeResponse()..mergeFromBuffer(data, registry);
  factory GetMeResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetMeResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetMeResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.identity.v1'),
      createEmptyInstance: GetMeResponse.$_createMessage)
    ..aOM<Profile>(1, _omitFieldNames ? '' : 'profile',
        subBuilder: Profile.$_createMessage)
    ..aE<AccountStatus>(2, _omitFieldNames ? '' : 'status',
        enumValues: AccountStatus.values)
    ..aOB(3, _omitFieldNames ? '' : 'emailVerified')
    ..aInt64(4, _omitFieldNames ? '' : 'unreadNotificationCount')
    ..pPS(5, _omitFieldNames ? '' : 'enabledFeatures')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetMeResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetMeResponse copyWith(void Function(GetMeResponse) updates) =>
      super.copyWith((message) => updates(message as GetMeResponse))
          as GetMeResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use GetMeResponse() / GetMeResponse.new instead')
  static GetMeResponse create() => GetMeResponse._();
  static $pb.GeneratedMessage $_createMessage() => GetMeResponse._();
  @$core.override
  GetMeResponse createEmptyInstance() => GetMeResponse._();
  @$core.pragma('dart2js:noInline')
  static GetMeResponse getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<GetMeResponse>(
          GetMeResponse.$_createMessage);
  static GetMeResponse? _defaultInstance;

  @$pb.TagNumber(1)
  Profile get profile => $_getN(0);
  @$pb.TagNumber(1)
  set profile(Profile value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasProfile() => $_has(0);
  @$pb.TagNumber(1)
  void clearProfile() => $_clearField(1);
  @$pb.TagNumber(1)
  Profile ensureProfile() => $_ensure(0);

  @$pb.TagNumber(2)
  AccountStatus get status => $_getN(1);
  @$pb.TagNumber(2)
  set status(AccountStatus value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasStatus() => $_has(1);
  @$pb.TagNumber(2)
  void clearStatus() => $_clearField(2);

  /// From the ID token claim (no Firestore read). Posting requires true or a Google/Apple provider.
  @$pb.TagNumber(3)
  $core.bool get emailVerified => $_getBF(2);
  @$pb.TagNumber(3)
  set emailVerified($core.bool value) => $_setBool(2, value);
  @$pb.TagNumber(3)
  $core.bool hasEmailVerified() => $_has(2);
  @$pb.TagNumber(3)
  void clearEmailVerified() => $_clearField(3);

  @$pb.TagNumber(4)
  $fixnum.Int64 get unreadNotificationCount => $_getI64(3);
  @$pb.TagNumber(4)
  set unreadNotificationCount($fixnum.Int64 value) => $_setInt64(3, value);
  @$pb.TagNumber(4)
  $core.bool hasUnreadNotificationCount() => $_has(3);
  @$pb.TagNumber(4)
  void clearUnreadNotificationCount() => $_clearField(4);

  /// Server feature flags enabled for this caller (ADR-0008 D6), lower snake case, e.g. "graph". A missing name means
  /// off; clients ignore names they don't know. The server stays authoritative: a disabled feature's RPCs return
  /// FAILED_PRECONDITION + ERROR_REASON_FEATURE_DISABLED.
  @$pb.TagNumber(5)
  $pb.PbList<$core.String> get enabledFeatures => $_getList(4);
}

enum GetProfileRequest_Target { userId, handle, notSet }

class GetProfileRequest extends $pb.GeneratedMessage {
  factory GetProfileRequest({
    $core.String? userId,
    $core.String? handle,
  }) {
    final result = GetProfileRequest._();
    if (userId != null) result.userId = userId;
    if (handle != null) result.handle = handle;
    return result;
  }

  GetProfileRequest._();

  factory GetProfileRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetProfileRequest()..mergeFromBuffer(data, registry);
  factory GetProfileRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetProfileRequest()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, GetProfileRequest_Target>
      _GetProfileRequest_TargetByTag = {
    1: GetProfileRequest_Target.userId,
    2: GetProfileRequest_Target.handle,
    0: GetProfileRequest_Target.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetProfileRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.identity.v1'),
      createEmptyInstance: GetProfileRequest.$_createMessage)
    ..oo(0, [1, 2])
    ..aOS(1, _omitFieldNames ? '' : 'userId')
    ..aOS(2, _omitFieldNames ? '' : 'handle')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetProfileRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetProfileRequest copyWith(void Function(GetProfileRequest) updates) =>
      super.copyWith((message) => updates(message as GetProfileRequest))
          as GetProfileRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use GetProfileRequest() / GetProfileRequest.new instead')
  static GetProfileRequest create() => GetProfileRequest._();
  static $pb.GeneratedMessage $_createMessage() => GetProfileRequest._();
  @$core.override
  GetProfileRequest createEmptyInstance() => GetProfileRequest._();
  @$core.pragma('dart2js:noInline')
  static GetProfileRequest getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<GetProfileRequest>(
          GetProfileRequest.$_createMessage);
  static GetProfileRequest? _defaultInstance;

  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  GetProfileRequest_Target whichTarget() =>
      _GetProfileRequest_TargetByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  void clearTarget() => $_clearField($_whichOneof(0));

  @$pb.TagNumber(1)
  $core.String get userId => $_getSZ(0);
  @$pb.TagNumber(1)
  set userId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasUserId() => $_has(0);
  @$pb.TagNumber(1)
  void clearUserId() => $_clearField(1);

  /// Case-insensitive.
  @$pb.TagNumber(2)
  $core.String get handle => $_getSZ(1);
  @$pb.TagNumber(2)
  set handle($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasHandle() => $_has(1);
  @$pb.TagNumber(2)
  void clearHandle() => $_clearField(2);
}

class GetProfileResponse extends $pb.GeneratedMessage {
  factory GetProfileResponse({
    Profile? profile,
  }) {
    final result = GetProfileResponse._();
    if (profile != null) result.profile = profile;
    return result;
  }

  GetProfileResponse._();

  factory GetProfileResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetProfileResponse()..mergeFromBuffer(data, registry);
  factory GetProfileResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetProfileResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetProfileResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.identity.v1'),
      createEmptyInstance: GetProfileResponse.$_createMessage)
    ..aOM<Profile>(1, _omitFieldNames ? '' : 'profile',
        subBuilder: Profile.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetProfileResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetProfileResponse copyWith(void Function(GetProfileResponse) updates) =>
      super.copyWith((message) => updates(message as GetProfileResponse))
          as GetProfileResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use GetProfileResponse() / GetProfileResponse.new instead')
  static GetProfileResponse create() => GetProfileResponse._();
  static $pb.GeneratedMessage $_createMessage() => GetProfileResponse._();
  @$core.override
  GetProfileResponse createEmptyInstance() => GetProfileResponse._();
  @$core.pragma('dart2js:noInline')
  static GetProfileResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<GetProfileResponse>(
          GetProfileResponse.$_createMessage);
  static GetProfileResponse? _defaultInstance;

  @$pb.TagNumber(1)
  Profile get profile => $_getN(0);
  @$pb.TagNumber(1)
  set profile(Profile value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasProfile() => $_has(0);
  @$pb.TagNumber(1)
  void clearProfile() => $_clearField(1);
  @$pb.TagNumber(1)
  Profile ensureProfile() => $_ensure(0);
}

class UpdateProfileRequest extends $pb.GeneratedMessage {
  factory UpdateProfileRequest({
    $core.String? idempotencyKey,
    $core.String? displayName,
    $core.String? bio,
    $core.String? avatarMediaId,
    $core.bool? isPrivate,
  }) {
    final result = UpdateProfileRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (displayName != null) result.displayName = displayName;
    if (bio != null) result.bio = bio;
    if (avatarMediaId != null) result.avatarMediaId = avatarMediaId;
    if (isPrivate != null) result.isPrivate = isPrivate;
    return result;
  }

  UpdateProfileRequest._();

  factory UpdateProfileRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UpdateProfileRequest()..mergeFromBuffer(data, registry);
  factory UpdateProfileRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UpdateProfileRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'UpdateProfileRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.identity.v1'),
      createEmptyInstance: UpdateProfileRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'displayName')
    ..aOS(3, _omitFieldNames ? '' : 'bio')
    ..aOS(4, _omitFieldNames ? '' : 'avatarMediaId')
    ..aOB(5, _omitFieldNames ? '' : 'isPrivate')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UpdateProfileRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UpdateProfileRequest copyWith(void Function(UpdateProfileRequest) updates) =>
      super.copyWith((message) => updates(message as UpdateProfileRequest))
          as UpdateProfileRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use UpdateProfileRequest() / UpdateProfileRequest.new instead')
  static UpdateProfileRequest create() => UpdateProfileRequest._();
  static $pb.GeneratedMessage $_createMessage() => UpdateProfileRequest._();
  @$core.override
  UpdateProfileRequest createEmptyInstance() => UpdateProfileRequest._();
  @$core.pragma('dart2js:noInline')
  static UpdateProfileRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<UpdateProfileRequest>(
          UpdateProfileRequest.$_createMessage);
  static UpdateProfileRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get displayName => $_getSZ(1);
  @$pb.TagNumber(2)
  set displayName($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasDisplayName() => $_has(1);
  @$pb.TagNumber(2)
  void clearDisplayName() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get bio => $_getSZ(2);
  @$pb.TagNumber(3)
  set bio($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasBio() => $_has(2);
  @$pb.TagNumber(3)
  void clearBio() => $_clearField(3);

  /// A READY media id with purpose AVATAR owned by the caller; "" removes the avatar.
  @$pb.TagNumber(4)
  $core.String get avatarMediaId => $_getSZ(3);
  @$pb.TagNumber(4)
  set avatarMediaId($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasAvatarMediaId() => $_has(3);
  @$pb.TagNumber(4)
  void clearAvatarMediaId() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.bool get isPrivate => $_getBF(4);
  @$pb.TagNumber(5)
  set isPrivate($core.bool value) => $_setBool(4, value);
  @$pb.TagNumber(5)
  $core.bool hasIsPrivate() => $_has(4);
  @$pb.TagNumber(5)
  void clearIsPrivate() => $_clearField(5);
}

class UpdateProfileResponse extends $pb.GeneratedMessage {
  factory UpdateProfileResponse({
    Profile? profile,
  }) {
    final result = UpdateProfileResponse._();
    if (profile != null) result.profile = profile;
    return result;
  }

  UpdateProfileResponse._();

  factory UpdateProfileResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UpdateProfileResponse()..mergeFromBuffer(data, registry);
  factory UpdateProfileResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UpdateProfileResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'UpdateProfileResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.identity.v1'),
      createEmptyInstance: UpdateProfileResponse.$_createMessage)
    ..aOM<Profile>(1, _omitFieldNames ? '' : 'profile',
        subBuilder: Profile.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UpdateProfileResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UpdateProfileResponse copyWith(
          void Function(UpdateProfileResponse) updates) =>
      super.copyWith((message) => updates(message as UpdateProfileResponse))
          as UpdateProfileResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use UpdateProfileResponse() / UpdateProfileResponse.new instead')
  static UpdateProfileResponse create() => UpdateProfileResponse._();
  static $pb.GeneratedMessage $_createMessage() => UpdateProfileResponse._();
  @$core.override
  UpdateProfileResponse createEmptyInstance() => UpdateProfileResponse._();
  @$core.pragma('dart2js:noInline')
  static UpdateProfileResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<UpdateProfileResponse>(
          UpdateProfileResponse.$_createMessage);
  static UpdateProfileResponse? _defaultInstance;

  @$pb.TagNumber(1)
  Profile get profile => $_getN(0);
  @$pb.TagNumber(1)
  set profile(Profile value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasProfile() => $_has(0);
  @$pb.TagNumber(1)
  void clearProfile() => $_clearField(1);
  @$pb.TagNumber(1)
  Profile ensureProfile() => $_ensure(0);
}

class ChangeHandleRequest extends $pb.GeneratedMessage {
  factory ChangeHandleRequest({
    $core.String? idempotencyKey,
    $core.String? newHandle,
  }) {
    final result = ChangeHandleRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (newHandle != null) result.newHandle = newHandle;
    return result;
  }

  ChangeHandleRequest._();

  factory ChangeHandleRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ChangeHandleRequest()..mergeFromBuffer(data, registry);
  factory ChangeHandleRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ChangeHandleRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ChangeHandleRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.identity.v1'),
      createEmptyInstance: ChangeHandleRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'newHandle')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ChangeHandleRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ChangeHandleRequest copyWith(void Function(ChangeHandleRequest) updates) =>
      super.copyWith((message) => updates(message as ChangeHandleRequest))
          as ChangeHandleRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core
      .Deprecated('Use ChangeHandleRequest() / ChangeHandleRequest.new instead')
  static ChangeHandleRequest create() => ChangeHandleRequest._();
  static $pb.GeneratedMessage $_createMessage() => ChangeHandleRequest._();
  @$core.override
  ChangeHandleRequest createEmptyInstance() => ChangeHandleRequest._();
  @$core.pragma('dart2js:noInline')
  static ChangeHandleRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ChangeHandleRequest>(
          ChangeHandleRequest.$_createMessage);
  static ChangeHandleRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get newHandle => $_getSZ(1);
  @$pb.TagNumber(2)
  set newHandle($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasNewHandle() => $_has(1);
  @$pb.TagNumber(2)
  void clearNewHandle() => $_clearField(2);
}

class ChangeHandleResponse extends $pb.GeneratedMessage {
  factory ChangeHandleResponse({
    Profile? profile,
  }) {
    final result = ChangeHandleResponse._();
    if (profile != null) result.profile = profile;
    return result;
  }

  ChangeHandleResponse._();

  factory ChangeHandleResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ChangeHandleResponse()..mergeFromBuffer(data, registry);
  factory ChangeHandleResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ChangeHandleResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ChangeHandleResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.identity.v1'),
      createEmptyInstance: ChangeHandleResponse.$_createMessage)
    ..aOM<Profile>(1, _omitFieldNames ? '' : 'profile',
        subBuilder: Profile.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ChangeHandleResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ChangeHandleResponse copyWith(void Function(ChangeHandleResponse) updates) =>
      super.copyWith((message) => updates(message as ChangeHandleResponse))
          as ChangeHandleResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ChangeHandleResponse() / ChangeHandleResponse.new instead')
  static ChangeHandleResponse create() => ChangeHandleResponse._();
  static $pb.GeneratedMessage $_createMessage() => ChangeHandleResponse._();
  @$core.override
  ChangeHandleResponse createEmptyInstance() => ChangeHandleResponse._();
  @$core.pragma('dart2js:noInline')
  static ChangeHandleResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ChangeHandleResponse>(
          ChangeHandleResponse.$_createMessage);
  static ChangeHandleResponse? _defaultInstance;

  @$pb.TagNumber(1)
  Profile get profile => $_getN(0);
  @$pb.TagNumber(1)
  set profile(Profile value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasProfile() => $_has(0);
  @$pb.TagNumber(1)
  void clearProfile() => $_clearField(1);
  @$pb.TagNumber(1)
  Profile ensureProfile() => $_ensure(0);
}

class DeleteAccountRequest extends $pb.GeneratedMessage {
  factory DeleteAccountRequest({
    $core.String? idempotencyKey,
  }) {
    final result = DeleteAccountRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    return result;
  }

  DeleteAccountRequest._();

  factory DeleteAccountRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      DeleteAccountRequest()..mergeFromBuffer(data, registry);
  factory DeleteAccountRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      DeleteAccountRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'DeleteAccountRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.identity.v1'),
      createEmptyInstance: DeleteAccountRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DeleteAccountRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DeleteAccountRequest copyWith(void Function(DeleteAccountRequest) updates) =>
      super.copyWith((message) => updates(message as DeleteAccountRequest))
          as DeleteAccountRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use DeleteAccountRequest() / DeleteAccountRequest.new instead')
  static DeleteAccountRequest create() => DeleteAccountRequest._();
  static $pb.GeneratedMessage $_createMessage() => DeleteAccountRequest._();
  @$core.override
  DeleteAccountRequest createEmptyInstance() => DeleteAccountRequest._();
  @$core.pragma('dart2js:noInline')
  static DeleteAccountRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<DeleteAccountRequest>(
          DeleteAccountRequest.$_createMessage);
  static DeleteAccountRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);
}

class DeleteAccountResponse extends $pb.GeneratedMessage {
  factory DeleteAccountResponse({
    $0.Timestamp? deletionRequestedAt,
  }) {
    final result = DeleteAccountResponse._();
    if (deletionRequestedAt != null)
      result.deletionRequestedAt = deletionRequestedAt;
    return result;
  }

  DeleteAccountResponse._();

  factory DeleteAccountResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      DeleteAccountResponse()..mergeFromBuffer(data, registry);
  factory DeleteAccountResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      DeleteAccountResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'DeleteAccountResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.identity.v1'),
      createEmptyInstance: DeleteAccountResponse.$_createMessage)
    ..aOM<$0.Timestamp>(1, _omitFieldNames ? '' : 'deletionRequestedAt',
        subBuilder: $0.Timestamp.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DeleteAccountResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DeleteAccountResponse copyWith(
          void Function(DeleteAccountResponse) updates) =>
      super.copyWith((message) => updates(message as DeleteAccountResponse))
          as DeleteAccountResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use DeleteAccountResponse() / DeleteAccountResponse.new instead')
  static DeleteAccountResponse create() => DeleteAccountResponse._();
  static $pb.GeneratedMessage $_createMessage() => DeleteAccountResponse._();
  @$core.override
  DeleteAccountResponse createEmptyInstance() => DeleteAccountResponse._();
  @$core.pragma('dart2js:noInline')
  static DeleteAccountResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<DeleteAccountResponse>(
          DeleteAccountResponse.$_createMessage);
  static DeleteAccountResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $0.Timestamp get deletionRequestedAt => $_getN(0);
  @$pb.TagNumber(1)
  set deletionRequestedAt($0.Timestamp value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasDeletionRequestedAt() => $_has(0);
  @$pb.TagNumber(1)
  void clearDeletionRequestedAt() => $_clearField(1);
  @$pb.TagNumber(1)
  $0.Timestamp ensureDeletionRequestedAt() => $_ensure(0);
}

class RequestAccountExportRequest extends $pb.GeneratedMessage {
  factory RequestAccountExportRequest({
    $core.String? idempotencyKey,
  }) {
    final result = RequestAccountExportRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    return result;
  }

  RequestAccountExportRequest._();

  factory RequestAccountExportRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RequestAccountExportRequest()..mergeFromBuffer(data, registry);
  factory RequestAccountExportRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RequestAccountExportRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RequestAccountExportRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.identity.v1'),
      createEmptyInstance: RequestAccountExportRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RequestAccountExportRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RequestAccountExportRequest copyWith(
          void Function(RequestAccountExportRequest) updates) =>
      super.copyWith(
              (message) => updates(message as RequestAccountExportRequest))
          as RequestAccountExportRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use RequestAccountExportRequest() / RequestAccountExportRequest.new instead')
  static RequestAccountExportRequest create() =>
      RequestAccountExportRequest._();
  static $pb.GeneratedMessage $_createMessage() =>
      RequestAccountExportRequest._();
  @$core.override
  RequestAccountExportRequest createEmptyInstance() =>
      RequestAccountExportRequest._();
  @$core.pragma('dart2js:noInline')
  static RequestAccountExportRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<RequestAccountExportRequest>(
          RequestAccountExportRequest.$_createMessage);
  static RequestAccountExportRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);
}

class RequestAccountExportResponse extends $pb.GeneratedMessage {
  factory RequestAccountExportResponse({
    $core.String? exportId,
    ExportStatus? status,
  }) {
    final result = RequestAccountExportResponse._();
    if (exportId != null) result.exportId = exportId;
    if (status != null) result.status = status;
    return result;
  }

  RequestAccountExportResponse._();

  factory RequestAccountExportResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RequestAccountExportResponse()..mergeFromBuffer(data, registry);
  factory RequestAccountExportResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RequestAccountExportResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RequestAccountExportResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.identity.v1'),
      createEmptyInstance: RequestAccountExportResponse.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'exportId')
    ..aE<ExportStatus>(2, _omitFieldNames ? '' : 'status',
        enumValues: ExportStatus.values)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RequestAccountExportResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RequestAccountExportResponse copyWith(
          void Function(RequestAccountExportResponse) updates) =>
      super.copyWith(
              (message) => updates(message as RequestAccountExportResponse))
          as RequestAccountExportResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use RequestAccountExportResponse() / RequestAccountExportResponse.new instead')
  static RequestAccountExportResponse create() =>
      RequestAccountExportResponse._();
  static $pb.GeneratedMessage $_createMessage() =>
      RequestAccountExportResponse._();
  @$core.override
  RequestAccountExportResponse createEmptyInstance() =>
      RequestAccountExportResponse._();
  @$core.pragma('dart2js:noInline')
  static RequestAccountExportResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<RequestAccountExportResponse>(
          RequestAccountExportResponse.$_createMessage);
  static RequestAccountExportResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get exportId => $_getSZ(0);
  @$pb.TagNumber(1)
  set exportId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasExportId() => $_has(0);
  @$pb.TagNumber(1)
  void clearExportId() => $_clearField(1);

  @$pb.TagNumber(2)
  ExportStatus get status => $_getN(1);
  @$pb.TagNumber(2)
  set status(ExportStatus value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasStatus() => $_has(1);
  @$pb.TagNumber(2)
  void clearStatus() => $_clearField(2);
}

class GetAccountExportRequest extends $pb.GeneratedMessage {
  factory GetAccountExportRequest({
    $core.String? exportId,
  }) {
    final result = GetAccountExportRequest._();
    if (exportId != null) result.exportId = exportId;
    return result;
  }

  GetAccountExportRequest._();

  factory GetAccountExportRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetAccountExportRequest()..mergeFromBuffer(data, registry);
  factory GetAccountExportRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetAccountExportRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetAccountExportRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.identity.v1'),
      createEmptyInstance: GetAccountExportRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'exportId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetAccountExportRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetAccountExportRequest copyWith(
          void Function(GetAccountExportRequest) updates) =>
      super.copyWith((message) => updates(message as GetAccountExportRequest))
          as GetAccountExportRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use GetAccountExportRequest() / GetAccountExportRequest.new instead')
  static GetAccountExportRequest create() => GetAccountExportRequest._();
  static $pb.GeneratedMessage $_createMessage() => GetAccountExportRequest._();
  @$core.override
  GetAccountExportRequest createEmptyInstance() => GetAccountExportRequest._();
  @$core.pragma('dart2js:noInline')
  static GetAccountExportRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<GetAccountExportRequest>(
          GetAccountExportRequest.$_createMessage);
  static GetAccountExportRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get exportId => $_getSZ(0);
  @$pb.TagNumber(1)
  set exportId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasExportId() => $_has(0);
  @$pb.TagNumber(1)
  void clearExportId() => $_clearField(1);
}

class GetAccountExportResponse extends $pb.GeneratedMessage {
  factory GetAccountExportResponse({
    $core.String? exportId,
    ExportStatus? status,
    $core.String? downloadUrl,
    $0.Timestamp? downloadUrlExpiresAt,
    $0.Timestamp? expiresAt,
  }) {
    final result = GetAccountExportResponse._();
    if (exportId != null) result.exportId = exportId;
    if (status != null) result.status = status;
    if (downloadUrl != null) result.downloadUrl = downloadUrl;
    if (downloadUrlExpiresAt != null)
      result.downloadUrlExpiresAt = downloadUrlExpiresAt;
    if (expiresAt != null) result.expiresAt = expiresAt;
    return result;
  }

  GetAccountExportResponse._();

  factory GetAccountExportResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetAccountExportResponse()..mergeFromBuffer(data, registry);
  factory GetAccountExportResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetAccountExportResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetAccountExportResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.identity.v1'),
      createEmptyInstance: GetAccountExportResponse.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'exportId')
    ..aE<ExportStatus>(2, _omitFieldNames ? '' : 'status',
        enumValues: ExportStatus.values)
    ..aOS(3, _omitFieldNames ? '' : 'downloadUrl')
    ..aOM<$0.Timestamp>(4, _omitFieldNames ? '' : 'downloadUrlExpiresAt',
        subBuilder: $0.Timestamp.$_createMessage)
    ..aOM<$0.Timestamp>(5, _omitFieldNames ? '' : 'expiresAt',
        subBuilder: $0.Timestamp.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetAccountExportResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetAccountExportResponse copyWith(
          void Function(GetAccountExportResponse) updates) =>
      super.copyWith((message) => updates(message as GetAccountExportResponse))
          as GetAccountExportResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use GetAccountExportResponse() / GetAccountExportResponse.new instead')
  static GetAccountExportResponse create() => GetAccountExportResponse._();
  static $pb.GeneratedMessage $_createMessage() => GetAccountExportResponse._();
  @$core.override
  GetAccountExportResponse createEmptyInstance() =>
      GetAccountExportResponse._();
  @$core.pragma('dart2js:noInline')
  static GetAccountExportResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<GetAccountExportResponse>(
          GetAccountExportResponse.$_createMessage);
  static GetAccountExportResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get exportId => $_getSZ(0);
  @$pb.TagNumber(1)
  set exportId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasExportId() => $_has(0);
  @$pb.TagNumber(1)
  void clearExportId() => $_clearField(1);

  @$pb.TagNumber(2)
  ExportStatus get status => $_getN(1);
  @$pb.TagNumber(2)
  set status(ExportStatus value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasStatus() => $_has(1);
  @$pb.TagNumber(2)
  void clearStatus() => $_clearField(2);

  /// Only when READY. 15-minute signed GET URL for a private JSON object.
  @$pb.TagNumber(3)
  $core.String get downloadUrl => $_getSZ(2);
  @$pb.TagNumber(3)
  set downloadUrl($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasDownloadUrl() => $_has(2);
  @$pb.TagNumber(3)
  void clearDownloadUrl() => $_clearField(3);

  @$pb.TagNumber(4)
  $0.Timestamp get downloadUrlExpiresAt => $_getN(3);
  @$pb.TagNumber(4)
  set downloadUrlExpiresAt($0.Timestamp value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasDownloadUrlExpiresAt() => $_has(3);
  @$pb.TagNumber(4)
  void clearDownloadUrlExpiresAt() => $_clearField(4);
  @$pb.TagNumber(4)
  $0.Timestamp ensureDownloadUrlExpiresAt() => $_ensure(3);

  /// created_at + 7 days. The JSON object in the private `<project>-exports` bucket (age = 7 lifecycle) and the
  /// exports doc (Firestore TTL) are deleted after it; both delete late, so the server returns NOT_FOUND from this
  /// time on (ADR-0011 D-B, Q6). Deleting the account deletes its exports at once.
  @$pb.TagNumber(5)
  $0.Timestamp get expiresAt => $_getN(4);
  @$pb.TagNumber(5)
  set expiresAt($0.Timestamp value) => $_setField(5, value);
  @$pb.TagNumber(5)
  $core.bool hasExpiresAt() => $_has(4);
  @$pb.TagNumber(5)
  void clearExpiresAt() => $_clearField(5);
  @$pb.TagNumber(5)
  $0.Timestamp ensureExpiresAt() => $_ensure(4);
}

class IdentityServiceApi {
  final $pb.RpcClient _client;

  IdentityServiceApi(this._client);

  /// Creates the caller's profile after Firebase sign-up. Idempotent by uid: a replay returns the existing profile.
  /// Transaction: read users/{uid} + handles/{h}; create users, handles, graph.
  /// Firestore: reads 2/2, writes 3/3.
  /// Needs a verified identity (Google, Apple or a password account with a verified email; ADR-0010 D5 A2, A10),
  /// else FAILED_PRECONDITION + EMAIL_NOT_VERIFIED at 0 reads. Its reads are charged to the caller IP's key but never
  /// rejected by it (charge-only, ADR-0010 D5 A8).
  $async.Future<CreateProfileResponse> createProfile(
          $pb.ClientContext? ctx, CreateProfileRequest request) =>
      _client.invoke<CreateProfileResponse>(ctx, 'IdentityService',
          'CreateProfile', request, CreateProfileResponse());

  /// Handle availability check for the sign-up form. In-memory rate limited (20/min/uid, ADR-0008 D7) and capped
  /// at 100 calls/uid/IST day per instance (RATE_LIMITED, metadata["limit"] = "check_handle_daily").
  /// Profile-exempt, so its reads are charged to the uid's daily Firestore read budget (over it => RATE_LIMITED,
  /// metadata["limit"] = "read_budget_daily", retry_after = time to IST midnight) and metered on the caller IP's
  /// (IPv6: /64) key, which is NEVER a reason to reject (ADR-0010 D5 A8): one address behind a carrier-grade NAT
  /// cannot block sign-ups for others. Only the per-minute bucket and check_handle_daily can still reject.
  /// Needs a verified identity: a password account whose email is unverified, and any sign-in other than Google,
  /// Apple or verified password (ADR-0010 D5 A10), gets FAILED_PRECONDITION + EMAIL_NOT_VERIFIED at 0 reads
  /// (before any rate limiter). The client shows the "verify your email" banner and refreshes the ID token.
  /// "Taken" is reported even when the handle's owner blocked the caller (accepted residual, ADR-0008 D9).
  /// Free handles are negatively cached 10 s per instance (a just-freed handle may read "taken" for <= 60 s).
  /// Firestore: reads 1/0-1, writes 0.
  $async.Future<CheckHandleAvailabilityResponse> checkHandleAvailability(
          $pb.ClientContext? ctx, CheckHandleAvailabilityRequest request) =>
      _client.invoke<CheckHandleAvailabilityResponse>(
          ctx,
          'IdentityService',
          'CheckHandleAvailability',
          request,
          CheckHandleAvailabilityResponse());

  /// The caller's own profile + account state. users/{uid} instance-cached 60 s (updated in place on own writes);
  /// unread count = count() aggregation on notifications with createdAt > users.notificationsSeenAt (1 read per
  /// 1,000 matches, cached 30 s). enabled_features comes from server env config (ADR-0008 D6): 0 reads.
  /// Firestore: reads 2/1, writes 0.
  $async.Future<GetMeResponse> getMe(
          $pb.ClientContext? ctx, GetMeRequest request) =>
      _client.invoke<GetMeResponse>(
          ctx, 'IdentityService', 'GetMe', request, GetMeResponse());

  /// Public profile by id or handle. Returns NOT_FOUND if the target blocked the caller, byte-identical to the
  /// error for a missing user (no existence leak). The check uses the caller's own graph (blockedBy, ADR-0008 D2).
  /// A caller who blocks the target still gets the profile (so they can unblock).
  /// Reads: handles (if by handle) + users + caller graph; all instance-cached 60 s; a handle that doesn't exist is
  /// negatively cached 10 s (ADR-0010 D5).
  /// Charged, like every RPC, to the per-uid daily Firestore read budget (2,000 reads/uid/IST day per instance,
  /// ADR-0010 D5); over it => RATE_LIMITED, metadata["limit"] = "read_budget_daily", retry_after = time to IST
  /// midnight, 0 reads.
  /// Firestore: reads 3/0-1 (+1 if the caller's blockedBy overflowed, ADR-0008 D2), writes 0.
  $async.Future<GetProfileResponse> getProfile(
          $pb.ClientContext? ctx, GetProfileRequest request) =>
      _client.invoke<GetProfileResponse>(
          ctx, 'IdentityService', 'GetProfile', request, GetProfileResponse());

  /// Partial update; only fields that are set are changed. Naturally idempotent (sets values).
  /// A change to display_name or avatar enqueues the author-snapshot refresh job (ADR-0003):
  /// async <= 100 post writes, limited to 5 snapshot-affecting edits/user/day.
  /// is_private=true is rejected with INVALID_ARGUMENT + VALIDATION (field "is_private") until private accounts ship
  /// (ADR-0008 D1); is_private=false is accepted. Once enabled, a change to is_private enqueues the visibility job
  /// (writes = author's post count; limited to 1 toggle/day).
  /// Firestore: reads 2/1 (users + avatar media), writes 1/1 (+ async jobs above).
  $async.Future<UpdateProfileResponse> updateProfile(
          $pb.ClientContext? ctx, UpdateProfileRequest request) =>
      _client.invoke<UpdateProfileResponse>(ctx, 'IdentityService',
          'UpdateProfile', request, UpdateProfileResponse());

  /// Rename. Transaction: read users + handles/{new}; create handles/{new}, delete handles/{old}, update users.
  /// Cooldown 7 days (config HANDLE_CHANGE_COOLDOWN). Enqueues the author-snapshot refresh job.
  /// Firestore: reads 2/2, writes 2/2 + deletes 1/1 (+ async snapshot job).
  $async.Future<ChangeHandleResponse> changeHandle(
          $pb.ClientContext? ctx, ChangeHandleRequest request) =>
      _client.invoke<ChangeHandleResponse>(ctx, 'IdentityService',
          'ChangeHandle', request, ChangeHandleResponse());

  /// Irreversible account deletion of the caller's own account (ADR-0011). The uid always comes from the ID token; the
  /// request has no uid field and must never get one. Requires a recent sign-in: ID token auth_time older than
  /// ACCOUNT_DELETE_REAUTH_MAX_AGE (5 min) or missing => FAILED_PRECONDITION + ERROR_REASON_REAUTH_REQUIRED, 0 writes.
  /// ACTIVE and SUSPENDED callers may both delete (ADR-0011 Q3): this is the only RPC the account-status interceptor
  /// lets a SUSPENDED or DELETING caller through to.
  /// Sync part: one transaction reads users/{uid} fresh and sets status = DELETING, updatedAt, deletionRequestedAt and
  /// deletionJob{seq: 0} (no job doc); after the commit it publishes {kind: account_delete, uid, seq: 0} to the
  /// `jobs` Pub/Sub topic. A failed publish still returns success: a replay or the daily backstop re-publishes.
  /// Replay: a caller already DELETING (same or new idempotency_key) gets the stored deletion_requested_at, 0 writes,
  /// and the current job seq is re-published (deduped by the job).
  /// The job (`/internal/pubsub/jobs`, self-chaining, <= 20 s of work per delivery) disables the Firebase Auth user and
  /// revokes refresh tokens on its first delivery, waits until 120 s after deletionRequestedAt (ADR-0008 D10), then
  /// deletes posts, the social graph, later-slice data, exports, handle and quotas in batches of <= 500, then the
  /// Firebase Auth user, and users/{uid} last. Reference account (300 posts, 100 following, 100 followers) completes in
  /// about 3-5 minutes. Existing ID tokens stay valid up to 1 h but are rejected by the interceptor.
  /// Firestore (sync part): reads 2/1 (interceptor + users), writes 1/1; replay reads 2/1, writes 0.
  /// Never rejected by the read budget (charge-only, CLAUDE.md rule 10); bounded instead by account_ops_daily:
  /// 20 calls/uid/IST day per instance shared with RequestAccountExport and GetAccountExport (RATE_LIMITED,
  /// metadata["limit"] = "account_ops_daily"; ADR-0010 D5 A6). DEGRADED_MODE=readonly rejects it (ADR-0011 Q8); a
  /// started deletion still finishes.
  $async.Future<DeleteAccountResponse> deleteAccount(
          $pb.ClientContext? ctx, DeleteAccountRequest request) =>
      _client.invoke<DeleteAccountResponse>(ctx, 'IdentityService',
          'DeleteAccount', request, DeleteAccountResponse());

  /// Starts a data export of the caller's own account (1/day/user, quota "exports"; over it => RESOURCE_EXHAUSTED +
  /// QUOTA_EXCEEDED, metadata["quota"] = "exports"). Doc id = hash(uid, idempotency_key), so a replay with the same key
  /// returns the same export and status. After the commit it publishes {kind: account_export, export_id} to the `jobs`
  /// topic; one delivery writes a single JSON file (account, profile, graph, posts; never who blocked you) to the
  /// private `<project>-exports` bucket and sets READY, usually within a minute (ADR-0011 D-B, D-D).
  /// Firestore: reads 2/1 (interceptor + quotas), writes 2/2 (exports doc + quotas); replay reads 3/2, writes 0.
  /// Never rejected by the read budget; bounded by account_ops_daily (see DeleteAccount). DEGRADED_MODE=readonly
  /// rejects it.
  $async.Future<RequestAccountExportResponse> requestAccountExport(
          $pb.ClientContext? ctx, RequestAccountExportRequest request) =>
      _client.invoke<RequestAccountExportResponse>(ctx, 'IdentityService',
          'RequestAccountExport', request, RequestAccountExportResponse());

  /// Export status; when READY returns a fresh 15-minute signed GET URL (signed per call, never stored or logged).
  /// NOT_FOUND, byte-identical in every case, when the export doesn't exist, belongs to another user, or is past
  /// expires_at (even if the TTL or bucket lifecycle has not deleted it yet; ADR-0011 Q6).
  /// Firestore: reads 2/1 (interceptor + exports, read fresh), writes 0.
  /// Never rejected by the read budget; bounded by account_ops_daily (see DeleteAccount).
  $async.Future<GetAccountExportResponse> getAccountExport(
          $pb.ClientContext? ctx, GetAccountExportRequest request) =>
      _client.invoke<GetAccountExportResponse>(ctx, 'IdentityService',
          'GetAccountExport', request, GetAccountExportResponse());
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
