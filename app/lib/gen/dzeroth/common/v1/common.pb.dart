// This is a generated file - do not edit.
//
// Generated from dzeroth/common/v1/common.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;
import 'package:protobuf/well_known_types/google/protobuf/duration.pb.dart'
    as $0;

import 'common.pbenum.dart';

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

export 'common.pbenum.dart';

/// Denormalized author data stored inside every post (ADR-0003). May be up to one refresh cycle stale.
class AuthorSnapshot extends $pb.GeneratedMessage {
  factory AuthorSnapshot({
    $core.String? userId,
    $core.String? handle,
    $core.String? displayName,
    $core.String? avatarUrl,
    $core.bool? verified,
  }) {
    final result = AuthorSnapshot._();
    if (userId != null) result.userId = userId;
    if (handle != null) result.handle = handle;
    if (displayName != null) result.displayName = displayName;
    if (avatarUrl != null) result.avatarUrl = avatarUrl;
    if (verified != null) result.verified = verified;
    return result;
  }

  AuthorSnapshot._();

  factory AuthorSnapshot.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      AuthorSnapshot()..mergeFromBuffer(data, registry);
  factory AuthorSnapshot.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      AuthorSnapshot()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'AuthorSnapshot',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.common.v1'),
      createEmptyInstance: AuthorSnapshot.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'userId')
    ..aOS(2, _omitFieldNames ? '' : 'handle')
    ..aOS(3, _omitFieldNames ? '' : 'displayName')
    ..aOS(4, _omitFieldNames ? '' : 'avatarUrl')
    ..aOB(5, _omitFieldNames ? '' : 'verified')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AuthorSnapshot clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AuthorSnapshot copyWith(void Function(AuthorSnapshot) updates) =>
      super.copyWith((message) => updates(message as AuthorSnapshot))
          as AuthorSnapshot;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use AuthorSnapshot() / AuthorSnapshot.new instead')
  static AuthorSnapshot create() => AuthorSnapshot._();
  static $pb.GeneratedMessage $_createMessage() => AuthorSnapshot._();
  @$core.override
  AuthorSnapshot createEmptyInstance() => AuthorSnapshot._();
  @$core.pragma('dart2js:noInline')
  static AuthorSnapshot getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<AuthorSnapshot>(
          AuthorSnapshot.$_createMessage);
  static AuthorSnapshot? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get userId => $_getSZ(0);
  @$pb.TagNumber(1)
  set userId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasUserId() => $_has(0);
  @$pb.TagNumber(1)
  void clearUserId() => $_clearField(1);

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

  /// Public avatar thumbnail URL (96 px). Empty when the user has no avatar.
  @$pb.TagNumber(4)
  $core.String get avatarUrl => $_getSZ(3);
  @$pb.TagNumber(4)
  set avatarUrl($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasAvatarUrl() => $_has(3);
  @$pb.TagNumber(4)
  void clearAvatarUrl() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.bool get verified => $_getBF(4);
  @$pb.TagNumber(5)
  set verified($core.bool value) => $_setBool(4, value);
  @$pb.TagNumber(5)
  $core.bool hasVerified() => $_has(4);
  @$pb.TagNumber(5)
  void clearVerified() => $_clearField(5);
}

/// A moderated, publicly readable image (ADR-0005). URLs are immutable and cacheable forever.
class MediaRef extends $pb.GeneratedMessage {
  factory MediaRef({
    $core.String? mediaId,
    $core.String? url,
    $core.String? thumbUrl,
    $core.int? width,
    $core.int? height,
    $core.String? blurhash,
    $core.String? altText,
  }) {
    final result = MediaRef._();
    if (mediaId != null) result.mediaId = mediaId;
    if (url != null) result.url = url;
    if (thumbUrl != null) result.thumbUrl = thumbUrl;
    if (width != null) result.width = width;
    if (height != null) result.height = height;
    if (blurhash != null) result.blurhash = blurhash;
    if (altText != null) result.altText = altText;
    return result;
  }

  MediaRef._();

  factory MediaRef.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      MediaRef()..mergeFromBuffer(data, registry);
  factory MediaRef.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      MediaRef()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'MediaRef',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.common.v1'),
      createEmptyInstance: MediaRef.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'mediaId')
    ..aOS(2, _omitFieldNames ? '' : 'url')
    ..aOS(3, _omitFieldNames ? '' : 'thumbUrl')
    ..aI(4, _omitFieldNames ? '' : 'width')
    ..aI(5, _omitFieldNames ? '' : 'height')
    ..aOS(6, _omitFieldNames ? '' : 'blurhash')
    ..aOS(7, _omitFieldNames ? '' : 'altText')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MediaRef clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MediaRef copyWith(void Function(MediaRef) updates) =>
      super.copyWith((message) => updates(message as MediaRef)) as MediaRef;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use MediaRef() / MediaRef.new instead')
  static MediaRef create() => MediaRef._();
  static $pb.GeneratedMessage $_createMessage() => MediaRef._();
  @$core.override
  MediaRef createEmptyInstance() => MediaRef._();
  @$core.pragma('dart2js:noInline')
  static MediaRef getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<MediaRef>(MediaRef.$_createMessage);
  static MediaRef? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get mediaId => $_getSZ(0);
  @$pb.TagNumber(1)
  set mediaId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasMediaId() => $_has(0);
  @$pb.TagNumber(1)
  void clearMediaId() => $_clearField(1);

  /// Full image, <= 1600 px on the long edge.
  @$pb.TagNumber(2)
  $core.String get url => $_getSZ(1);
  @$pb.TagNumber(2)
  set url($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasUrl() => $_has(1);
  @$pb.TagNumber(2)
  void clearUrl() => $_clearField(2);

  /// Thumbnail, 400 px on the long edge. Lists and timelines must use this.
  @$pb.TagNumber(3)
  $core.String get thumbUrl => $_getSZ(2);
  @$pb.TagNumber(3)
  set thumbUrl($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasThumbUrl() => $_has(2);
  @$pb.TagNumber(3)
  void clearThumbUrl() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.int get width => $_getIZ(3);
  @$pb.TagNumber(4)
  set width($core.int value) => $_setSignedInt32(3, value);
  @$pb.TagNumber(4)
  $core.bool hasWidth() => $_has(3);
  @$pb.TagNumber(4)
  void clearWidth() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.int get height => $_getIZ(4);
  @$pb.TagNumber(5)
  set height($core.int value) => $_setSignedInt32(4, value);
  @$pb.TagNumber(5)
  $core.bool hasHeight() => $_has(4);
  @$pb.TagNumber(5)
  void clearHeight() => $_clearField(5);

  /// BlurHash placeholder computed on device, <= 64 chars.
  @$pb.TagNumber(6)
  $core.String get blurhash => $_getSZ(5);
  @$pb.TagNumber(6)
  set blurhash($core.String value) => $_setString(5, value);
  @$pb.TagNumber(6)
  $core.bool hasBlurhash() => $_has(5);
  @$pb.TagNumber(6)
  void clearBlurhash() => $_clearField(6);

  @$pb.TagNumber(7)
  $core.String get altText => $_getSZ(6);
  @$pb.TagNumber(7)
  set altText($core.String value) => $_setString(6, value);
  @$pb.TagNumber(7)
  $core.bool hasAltText() => $_has(6);
  @$pb.TagNumber(7)
  void clearAltText() => $_clearField(7);
}

/// Why a request failed, attached to Connect errors as an error detail.
/// Clients branch on `reason`, never on the message text.
class ErrorDetail extends $pb.GeneratedMessage {
  factory ErrorDetail({
    ErrorReason? reason,
    $core.String? message,
    $0.Duration? retryAfter,
    $core.Iterable<$core.MapEntry<$core.String, $core.String>>? metadata,
  }) {
    final result = ErrorDetail._();
    if (reason != null) result.reason = reason;
    if (message != null) result.message = message;
    if (retryAfter != null) result.retryAfter = retryAfter;
    if (metadata != null) result.metadata.addEntries(metadata);
    return result;
  }

  ErrorDetail._();

  factory ErrorDetail.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ErrorDetail()..mergeFromBuffer(data, registry);
  factory ErrorDetail.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ErrorDetail()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ErrorDetail',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.common.v1'),
      createEmptyInstance: ErrorDetail.$_createMessage)
    ..aE<ErrorReason>(1, _omitFieldNames ? '' : 'reason',
        enumValues: ErrorReason.values)
    ..aOS(2, _omitFieldNames ? '' : 'message')
    ..aOM<$0.Duration>(3, _omitFieldNames ? '' : 'retryAfter',
        subBuilder: $0.Duration.$_createMessage)
    ..m<$core.String, $core.String>(4, _omitFieldNames ? '' : 'metadata',
        entryClassName: 'ErrorDetail.MetadataEntry',
        keyFieldType: $pb.PbFieldType.OS,
        valueFieldType: $pb.PbFieldType.OS,
        packageName: const $pb.PackageName('dzeroth.common.v1'))
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ErrorDetail clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ErrorDetail copyWith(void Function(ErrorDetail) updates) =>
      super.copyWith((message) => updates(message as ErrorDetail))
          as ErrorDetail;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use ErrorDetail() / ErrorDetail.new instead')
  static ErrorDetail create() => ErrorDetail._();
  static $pb.GeneratedMessage $_createMessage() => ErrorDetail._();
  @$core.override
  ErrorDetail createEmptyInstance() => ErrorDetail._();
  @$core.pragma('dart2js:noInline')
  static ErrorDetail getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<ErrorDetail>(
          ErrorDetail.$_createMessage);
  static ErrorDetail? _defaultInstance;

  @$pb.TagNumber(1)
  ErrorReason get reason => $_getN(0);
  @$pb.TagNumber(1)
  set reason(ErrorReason value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasReason() => $_has(0);
  @$pb.TagNumber(1)
  void clearReason() => $_clearField(1);

  /// Safe to show to the user.
  @$pb.TagNumber(2)
  $core.String get message => $_getSZ(1);
  @$pb.TagNumber(2)
  set message($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasMessage() => $_has(1);
  @$pb.TagNumber(2)
  void clearMessage() => $_clearField(2);

  /// Set for RATE_LIMITED / QUOTA_EXCEEDED / DEGRADED_MODE. Clients must not retry before it elapses.
  @$pb.TagNumber(3)
  $0.Duration get retryAfter => $_getN(2);
  @$pb.TagNumber(3)
  set retryAfter($0.Duration value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasRetryAfter() => $_has(2);
  @$pb.TagNumber(3)
  void clearRetryAfter() => $_clearField(3);
  @$pb.TagNumber(3)
  $0.Duration ensureRetryAfter() => $_ensure(2);

  /// Field name for VALIDATION errors, limit name for quota errors, etc.
  @$pb.TagNumber(4)
  $pb.PbMap<$core.String, $core.String> get metadata => $_getMap(3);
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
