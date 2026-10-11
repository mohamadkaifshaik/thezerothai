// This is a generated file - do not edit.
//
// Generated from dzeroth/notifications/v1/notifications.proto.

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
    as $1;

import '../../common/v1/common.pb.dart' as $0;
import 'notifications.pbenum.dart';

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

export 'notifications.pbenum.dart';

class Notification extends $pb.GeneratedMessage {
  factory Notification({
    $core.String? id,
    NotificationType? type,
    $0.AuthorSnapshot? actor,
    $core.int? actorCount,
    $core.String? postId,
    $1.Timestamp? createdAt,
  }) {
    final result = Notification._();
    if (id != null) result.id = id;
    if (type != null) result.type = type;
    if (actor != null) result.actor = actor;
    if (actorCount != null) result.actorCount = actorCount;
    if (postId != null) result.postId = postId;
    if (createdAt != null) result.createdAt = createdAt;
    return result;
  }

  Notification._();

  factory Notification.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Notification()..mergeFromBuffer(data, registry);
  factory Notification.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Notification()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Notification',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.notifications.v1'),
      createEmptyInstance: Notification.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'id')
    ..aE<NotificationType>(2, _omitFieldNames ? '' : 'type',
        enumValues: NotificationType.values)
    ..aOM<$0.AuthorSnapshot>(3, _omitFieldNames ? '' : 'actor',
        subBuilder: $0.AuthorSnapshot.$_createMessage)
    ..aI(4, _omitFieldNames ? '' : 'actorCount')
    ..aOS(5, _omitFieldNames ? '' : 'postId')
    ..aOM<$1.Timestamp>(6, _omitFieldNames ? '' : 'createdAt',
        subBuilder: $1.Timestamp.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Notification clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Notification copyWith(void Function(Notification) updates) =>
      super.copyWith((message) => updates(message as Notification))
          as Notification;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Notification() / Notification.new instead')
  static Notification create() => Notification._();
  static $pb.GeneratedMessage $_createMessage() => Notification._();
  @$core.override
  Notification createEmptyInstance() => Notification._();
  @$core.pragma('dart2js:noInline')
  static Notification getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<Notification>(
          Notification.$_createMessage);
  static Notification? _defaultInstance;

  /// Stable per logical notification (rewritten in place when a LIKE row collapses another like).
  @$pb.TagNumber(1)
  $core.String get id => $_getSZ(0);
  @$pb.TagNumber(1)
  set id($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasId() => $_has(0);
  @$pb.TagNumber(1)
  void clearId() => $_clearField(1);

  @$pb.TagNumber(2)
  NotificationType get type => $_getN(1);
  @$pb.TagNumber(2)
  set type(NotificationType value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasType() => $_has(1);
  @$pb.TagNumber(2)
  void clearType() => $_clearField(2);

  /// The most recent actor, snapshotted when the notification was written (may be up to a profile refresh stale).
  @$pb.TagNumber(3)
  $0.AuthorSnapshot get actor => $_getN(2);
  @$pb.TagNumber(3)
  set actor($0.AuthorSnapshot value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasActor() => $_has(2);
  @$pb.TagNumber(3)
  void clearActor() => $_clearField(3);
  @$pb.TagNumber(3)
  $0.AuthorSnapshot ensureActor() => $_ensure(2);

  /// Distinct actors folded into this row (>= 1; only LIKE is > 1). Render "@actor and N-1 others".
  @$pb.TagNumber(4)
  $core.int get actorCount => $_getIZ(3);
  @$pb.TagNumber(4)
  set actorCount($core.int value) => $_setSignedInt32(3, value);
  @$pb.TagNumber(4)
  $core.bool hasActorCount() => $_has(3);
  @$pb.TagNumber(4)
  void clearActorCount() => $_clearField(4);

  /// Subject post (empty for FOLLOW). Tapping opens /post/:id, or the actor's profile for FOLLOW.
  @$pb.TagNumber(5)
  $core.String get postId => $_getSZ(4);
  @$pb.TagNumber(5)
  set postId($core.String value) => $_setString(4, value);
  @$pb.TagNumber(5)
  $core.bool hasPostId() => $_has(4);
  @$pb.TagNumber(5)
  void clearPostId() => $_clearField(5);

  /// Last activity; the sort key.
  @$pb.TagNumber(6)
  $1.Timestamp get createdAt => $_getN(5);
  @$pb.TagNumber(6)
  set createdAt($1.Timestamp value) => $_setField(6, value);
  @$pb.TagNumber(6)
  $core.bool hasCreatedAt() => $_has(5);
  @$pb.TagNumber(6)
  void clearCreatedAt() => $_clearField(6);
  @$pb.TagNumber(6)
  $1.Timestamp ensureCreatedAt() => $_ensure(5);
}

class ListNotificationsRequest extends $pb.GeneratedMessage {
  factory ListNotificationsRequest({
    $core.int? pageSize,
    $core.String? pageToken,
    $core.String? sinceToken,
  }) {
    final result = ListNotificationsRequest._();
    if (pageSize != null) result.pageSize = pageSize;
    if (pageToken != null) result.pageToken = pageToken;
    if (sinceToken != null) result.sinceToken = sinceToken;
    return result;
  }

  ListNotificationsRequest._();

  factory ListNotificationsRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListNotificationsRequest()..mergeFromBuffer(data, registry);
  factory ListNotificationsRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListNotificationsRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListNotificationsRequest',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.notifications.v1'),
      createEmptyInstance: ListNotificationsRequest.$_createMessage)
    ..aI(1, _omitFieldNames ? '' : 'pageSize')
    ..aOS(2, _omitFieldNames ? '' : 'pageToken')
    ..aOS(3, _omitFieldNames ? '' : 'sinceToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListNotificationsRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListNotificationsRequest copyWith(
          void Function(ListNotificationsRequest) updates) =>
      super.copyWith((message) => updates(message as ListNotificationsRequest))
          as ListNotificationsRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ListNotificationsRequest() / ListNotificationsRequest.new instead')
  static ListNotificationsRequest create() => ListNotificationsRequest._();
  static $pb.GeneratedMessage $_createMessage() => ListNotificationsRequest._();
  @$core.override
  ListNotificationsRequest createEmptyInstance() =>
      ListNotificationsRequest._();
  @$core.pragma('dart2js:noInline')
  static ListNotificationsRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListNotificationsRequest>(
          ListNotificationsRequest.$_createMessage);
  static ListNotificationsRequest? _defaultInstance;

  /// 0 => 20; max 50 (clamped).
  @$pb.TagNumber(1)
  $core.int get pageSize => $_getIZ(0);
  @$pb.TagNumber(1)
  set pageSize($core.int value) => $_setSignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasPageSize() => $_has(0);
  @$pb.TagNumber(1)
  void clearPageSize() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get pageToken => $_getSZ(1);
  @$pb.TagNumber(2)
  set pageToken($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasPageToken() => $_has(1);
  @$pb.TagNumber(2)
  void clearPageToken() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get sinceToken => $_getSZ(2);
  @$pb.TagNumber(3)
  set sinceToken($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasSinceToken() => $_has(2);
  @$pb.TagNumber(3)
  void clearSinceToken() => $_clearField(3);
}

class ListNotificationsResponse extends $pb.GeneratedMessage {
  factory ListNotificationsResponse({
    $core.Iterable<Notification>? notifications,
    $core.String? nextPageToken,
    $core.String? sinceToken,
    $core.String? gapPageToken,
    $1.Timestamp? seenAt,
  }) {
    final result = ListNotificationsResponse._();
    if (notifications != null) result.notifications.addAll(notifications);
    if (nextPageToken != null) result.nextPageToken = nextPageToken;
    if (sinceToken != null) result.sinceToken = sinceToken;
    if (gapPageToken != null) result.gapPageToken = gapPageToken;
    if (seenAt != null) result.seenAt = seenAt;
    return result;
  }

  ListNotificationsResponse._();

  factory ListNotificationsResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListNotificationsResponse()..mergeFromBuffer(data, registry);
  factory ListNotificationsResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListNotificationsResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListNotificationsResponse',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.notifications.v1'),
      createEmptyInstance: ListNotificationsResponse.$_createMessage)
    ..pPM<Notification>(1, _omitFieldNames ? '' : 'notifications',
        subBuilder: Notification.$_createMessage)
    ..aOS(2, _omitFieldNames ? '' : 'nextPageToken')
    ..aOS(3, _omitFieldNames ? '' : 'sinceToken')
    ..aOS(4, _omitFieldNames ? '' : 'gapPageToken')
    ..aOM<$1.Timestamp>(5, _omitFieldNames ? '' : 'seenAt',
        subBuilder: $1.Timestamp.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListNotificationsResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListNotificationsResponse copyWith(
          void Function(ListNotificationsResponse) updates) =>
      super.copyWith((message) => updates(message as ListNotificationsResponse))
          as ListNotificationsResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ListNotificationsResponse() / ListNotificationsResponse.new instead')
  static ListNotificationsResponse create() => ListNotificationsResponse._();
  static $pb.GeneratedMessage $_createMessage() =>
      ListNotificationsResponse._();
  @$core.override
  ListNotificationsResponse createEmptyInstance() =>
      ListNotificationsResponse._();
  @$core.pragma('dart2js:noInline')
  static ListNotificationsResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListNotificationsResponse>(
          ListNotificationsResponse.$_createMessage);
  static ListNotificationsResponse? _defaultInstance;

  /// Newest first.
  @$pb.TagNumber(1)
  $pb.PbList<Notification> get notifications => $_getList(0);

  /// "" => no older notifications.
  @$pb.TagNumber(2)
  $core.String get nextPageToken => $_getSZ(1);
  @$pb.TagNumber(2)
  set nextPageToken($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasNextPageToken() => $_has(1);
  @$pb.TagNumber(2)
  void clearNextPageToken() => $_clearField(2);

  /// Persist with the cached items; send on the next refresh.
  @$pb.TagNumber(3)
  $core.String get sinceToken => $_getSZ(2);
  @$pb.TagNumber(3)
  set sinceToken($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasSinceToken() => $_has(2);
  @$pb.TagNumber(3)
  void clearSinceToken() => $_clearField(3);

  /// Non-empty => a refresh gap exists below the returned items (see token contract).
  @$pb.TagNumber(4)
  $core.String get gapPageToken => $_getSZ(3);
  @$pb.TagNumber(4)
  set gapPageToken($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasGapPageToken() => $_has(3);
  @$pb.TagNumber(4)
  void clearGapPageToken() => $_clearField(4);

  /// The caller's notificationsSeenAt: rows with created_at > seen_at are unread. Unset when never marked seen.
  @$pb.TagNumber(5)
  $1.Timestamp get seenAt => $_getN(4);
  @$pb.TagNumber(5)
  set seenAt($1.Timestamp value) => $_setField(5, value);
  @$pb.TagNumber(5)
  $core.bool hasSeenAt() => $_has(4);
  @$pb.TagNumber(5)
  void clearSeenAt() => $_clearField(5);
  @$pb.TagNumber(5)
  $1.Timestamp ensureSeenAt() => $_ensure(4);
}

class MarkNotificationsSeenRequest extends $pb.GeneratedMessage {
  factory MarkNotificationsSeenRequest({
    $core.String? idempotencyKey,
  }) {
    final result = MarkNotificationsSeenRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    return result;
  }

  MarkNotificationsSeenRequest._();

  factory MarkNotificationsSeenRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      MarkNotificationsSeenRequest()..mergeFromBuffer(data, registry);
  factory MarkNotificationsSeenRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      MarkNotificationsSeenRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'MarkNotificationsSeenRequest',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.notifications.v1'),
      createEmptyInstance: MarkNotificationsSeenRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MarkNotificationsSeenRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MarkNotificationsSeenRequest copyWith(
          void Function(MarkNotificationsSeenRequest) updates) =>
      super.copyWith(
              (message) => updates(message as MarkNotificationsSeenRequest))
          as MarkNotificationsSeenRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use MarkNotificationsSeenRequest() / MarkNotificationsSeenRequest.new instead')
  static MarkNotificationsSeenRequest create() =>
      MarkNotificationsSeenRequest._();
  static $pb.GeneratedMessage $_createMessage() =>
      MarkNotificationsSeenRequest._();
  @$core.override
  MarkNotificationsSeenRequest createEmptyInstance() =>
      MarkNotificationsSeenRequest._();
  @$core.pragma('dart2js:noInline')
  static MarkNotificationsSeenRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<MarkNotificationsSeenRequest>(
          MarkNotificationsSeenRequest.$_createMessage);
  static MarkNotificationsSeenRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);
}

class MarkNotificationsSeenResponse extends $pb.GeneratedMessage {
  factory MarkNotificationsSeenResponse({
    $1.Timestamp? seenAt,
  }) {
    final result = MarkNotificationsSeenResponse._();
    if (seenAt != null) result.seenAt = seenAt;
    return result;
  }

  MarkNotificationsSeenResponse._();

  factory MarkNotificationsSeenResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      MarkNotificationsSeenResponse()..mergeFromBuffer(data, registry);
  factory MarkNotificationsSeenResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      MarkNotificationsSeenResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'MarkNotificationsSeenResponse',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.notifications.v1'),
      createEmptyInstance: MarkNotificationsSeenResponse.$_createMessage)
    ..aOM<$1.Timestamp>(1, _omitFieldNames ? '' : 'seenAt',
        subBuilder: $1.Timestamp.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MarkNotificationsSeenResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MarkNotificationsSeenResponse copyWith(
          void Function(MarkNotificationsSeenResponse) updates) =>
      super.copyWith(
              (message) => updates(message as MarkNotificationsSeenResponse))
          as MarkNotificationsSeenResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use MarkNotificationsSeenResponse() / MarkNotificationsSeenResponse.new instead')
  static MarkNotificationsSeenResponse create() =>
      MarkNotificationsSeenResponse._();
  static $pb.GeneratedMessage $_createMessage() =>
      MarkNotificationsSeenResponse._();
  @$core.override
  MarkNotificationsSeenResponse createEmptyInstance() =>
      MarkNotificationsSeenResponse._();
  @$core.pragma('dart2js:noInline')
  static MarkNotificationsSeenResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<MarkNotificationsSeenResponse>(
          MarkNotificationsSeenResponse.$_createMessage);
  static MarkNotificationsSeenResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $1.Timestamp get seenAt => $_getN(0);
  @$pb.TagNumber(1)
  set seenAt($1.Timestamp value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasSeenAt() => $_has(0);
  @$pb.TagNumber(1)
  void clearSeenAt() => $_clearField(1);
  @$pb.TagNumber(1)
  $1.Timestamp ensureSeenAt() => $_ensure(0);
}

class RegisterDeviceRequest extends $pb.GeneratedMessage {
  factory RegisterDeviceRequest({
    $core.String? idempotencyKey,
    $core.String? deviceId,
    $core.String? fcmToken,
    DevicePlatform? platform,
  }) {
    final result = RegisterDeviceRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (deviceId != null) result.deviceId = deviceId;
    if (fcmToken != null) result.fcmToken = fcmToken;
    if (platform != null) result.platform = platform;
    return result;
  }

  RegisterDeviceRequest._();

  factory RegisterDeviceRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RegisterDeviceRequest()..mergeFromBuffer(data, registry);
  factory RegisterDeviceRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RegisterDeviceRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RegisterDeviceRequest',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.notifications.v1'),
      createEmptyInstance: RegisterDeviceRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'deviceId')
    ..aOS(3, _omitFieldNames ? '' : 'fcmToken')
    ..aE<DevicePlatform>(4, _omitFieldNames ? '' : 'platform',
        enumValues: DevicePlatform.values)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RegisterDeviceRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RegisterDeviceRequest copyWith(
          void Function(RegisterDeviceRequest) updates) =>
      super.copyWith((message) => updates(message as RegisterDeviceRequest))
          as RegisterDeviceRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use RegisterDeviceRequest() / RegisterDeviceRequest.new instead')
  static RegisterDeviceRequest create() => RegisterDeviceRequest._();
  static $pb.GeneratedMessage $_createMessage() => RegisterDeviceRequest._();
  @$core.override
  RegisterDeviceRequest createEmptyInstance() => RegisterDeviceRequest._();
  @$core.pragma('dart2js:noInline')
  static RegisterDeviceRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<RegisterDeviceRequest>(
          RegisterDeviceRequest.$_createMessage);
  static RegisterDeviceRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  /// Client-generated installation id, 16-64 chars [A-Za-z0-9_-], stable for the installation.
  @$pb.TagNumber(2)
  $core.String get deviceId => $_getSZ(1);
  @$pb.TagNumber(2)
  set deviceId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasDeviceId() => $_has(1);
  @$pb.TagNumber(2)
  void clearDeviceId() => $_clearField(2);

  /// FCM registration token, 1-4096 bytes, no whitespace. Never logged.
  @$pb.TagNumber(3)
  $core.String get fcmToken => $_getSZ(2);
  @$pb.TagNumber(3)
  set fcmToken($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasFcmToken() => $_has(2);
  @$pb.TagNumber(3)
  void clearFcmToken() => $_clearField(3);

  @$pb.TagNumber(4)
  DevicePlatform get platform => $_getN(3);
  @$pb.TagNumber(4)
  set platform(DevicePlatform value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasPlatform() => $_has(3);
  @$pb.TagNumber(4)
  void clearPlatform() => $_clearField(4);
}

class RegisterDeviceResponse extends $pb.GeneratedMessage {
  factory RegisterDeviceResponse() => RegisterDeviceResponse._();

  RegisterDeviceResponse._();

  factory RegisterDeviceResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RegisterDeviceResponse()..mergeFromBuffer(data, registry);
  factory RegisterDeviceResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RegisterDeviceResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RegisterDeviceResponse',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.notifications.v1'),
      createEmptyInstance: RegisterDeviceResponse.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RegisterDeviceResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RegisterDeviceResponse copyWith(
          void Function(RegisterDeviceResponse) updates) =>
      super.copyWith((message) => updates(message as RegisterDeviceResponse))
          as RegisterDeviceResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use RegisterDeviceResponse() / RegisterDeviceResponse.new instead')
  static RegisterDeviceResponse create() => RegisterDeviceResponse._();
  static $pb.GeneratedMessage $_createMessage() => RegisterDeviceResponse._();
  @$core.override
  RegisterDeviceResponse createEmptyInstance() => RegisterDeviceResponse._();
  @$core.pragma('dart2js:noInline')
  static RegisterDeviceResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<RegisterDeviceResponse>(
          RegisterDeviceResponse.$_createMessage);
  static RegisterDeviceResponse? _defaultInstance;
}

class UnregisterDeviceRequest extends $pb.GeneratedMessage {
  factory UnregisterDeviceRequest({
    $core.String? idempotencyKey,
    $core.String? deviceId,
  }) {
    final result = UnregisterDeviceRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (deviceId != null) result.deviceId = deviceId;
    return result;
  }

  UnregisterDeviceRequest._();

  factory UnregisterDeviceRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UnregisterDeviceRequest()..mergeFromBuffer(data, registry);
  factory UnregisterDeviceRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UnregisterDeviceRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'UnregisterDeviceRequest',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.notifications.v1'),
      createEmptyInstance: UnregisterDeviceRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'deviceId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UnregisterDeviceRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UnregisterDeviceRequest copyWith(
          void Function(UnregisterDeviceRequest) updates) =>
      super.copyWith((message) => updates(message as UnregisterDeviceRequest))
          as UnregisterDeviceRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use UnregisterDeviceRequest() / UnregisterDeviceRequest.new instead')
  static UnregisterDeviceRequest create() => UnregisterDeviceRequest._();
  static $pb.GeneratedMessage $_createMessage() => UnregisterDeviceRequest._();
  @$core.override
  UnregisterDeviceRequest createEmptyInstance() => UnregisterDeviceRequest._();
  @$core.pragma('dart2js:noInline')
  static UnregisterDeviceRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<UnregisterDeviceRequest>(
          UnregisterDeviceRequest.$_createMessage);
  static UnregisterDeviceRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get deviceId => $_getSZ(1);
  @$pb.TagNumber(2)
  set deviceId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasDeviceId() => $_has(1);
  @$pb.TagNumber(2)
  void clearDeviceId() => $_clearField(2);
}

class UnregisterDeviceResponse extends $pb.GeneratedMessage {
  factory UnregisterDeviceResponse() => UnregisterDeviceResponse._();

  UnregisterDeviceResponse._();

  factory UnregisterDeviceResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UnregisterDeviceResponse()..mergeFromBuffer(data, registry);
  factory UnregisterDeviceResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UnregisterDeviceResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'UnregisterDeviceResponse',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.notifications.v1'),
      createEmptyInstance: UnregisterDeviceResponse.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UnregisterDeviceResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UnregisterDeviceResponse copyWith(
          void Function(UnregisterDeviceResponse) updates) =>
      super.copyWith((message) => updates(message as UnregisterDeviceResponse))
          as UnregisterDeviceResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use UnregisterDeviceResponse() / UnregisterDeviceResponse.new instead')
  static UnregisterDeviceResponse create() => UnregisterDeviceResponse._();
  static $pb.GeneratedMessage $_createMessage() => UnregisterDeviceResponse._();
  @$core.override
  UnregisterDeviceResponse createEmptyInstance() =>
      UnregisterDeviceResponse._();
  @$core.pragma('dart2js:noInline')
  static UnregisterDeviceResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<UnregisterDeviceResponse>(
          UnregisterDeviceResponse.$_createMessage);
  static UnregisterDeviceResponse? _defaultInstance;
}

class NotificationServiceApi {
  final $pb.RpcClient _client;

  NotificationServiceApi(this._client);

  /// Newest-first notifications for the caller. Every RPC checks FEATURE_NOTIFICATIONS (FAILED_PRECONDITION +
  /// FEATURE_DISABLED when off, 0 reads).
  /// Firestore: reads 1 + page_size worst (21 at the default page; the seen_at profile is cached by the
  /// account-status interceptor), refresh with 0 new items 1 read, planning 21 cold / 5 refresh; writes 0.
  /// Rate limit: default per-minute bucket. Counted against the per-uid daily read budget.
  $async.Future<ListNotificationsResponse> listNotifications(
          $pb.ClientContext? ctx, ListNotificationsRequest request) =>
      _client.invoke<ListNotificationsResponse>(ctx, 'NotificationService',
          'ListNotifications', request, ListNotificationsResponse());

  /// Sets users/{uid}.notificationsSeenAt = now (the badge count drops to 0 within the 30 s GetMe cache; this
  /// instance's cache is evicted at once). Naturally idempotent: a replay just moves seen_at forward.
  /// Firestore: reads 0, writes 1.
  $async.Future<MarkNotificationsSeenResponse> markNotificationsSeen(
          $pb.ClientContext? ctx, MarkNotificationsSeenRequest request) =>
      _client.invoke<MarkNotificationsSeenResponse>(ctx, 'NotificationService',
          'MarkNotificationsSeen', request, MarkNotificationsSeenResponse());

  /// Registers (or refreshes) this installation's FCM token under users/{uid}/devices/{device_id}. A token that was
  /// registered by another account on the same device is removed from that account (privacy). At most 5 devices per
  /// user: registering a 6th evicts the least recently refreshed one. Call on sign-in, on token refresh and once per
  /// app start. Naturally idempotent by device_id.
  /// Rate limit: 50 Register/Unregister calls per uid per day (limit_name "notification_devices_daily").
  /// Firestore: reads worst 8 (device doc, token index, previous owner's device, device list <= 6), typical 2;
  /// writes worst 5, typical 2.
  $async.Future<RegisterDeviceResponse> registerDevice(
          $pb.ClientContext? ctx, RegisterDeviceRequest request) =>
      _client.invoke<RegisterDeviceResponse>(ctx, 'NotificationService',
          'RegisterDevice', request, RegisterDeviceResponse());

  /// Removes the device (call on sign-out, before the ID token is dropped). Unknown device_id is a no-op success.
  /// Firestore: reads 1, writes 0 or 2 (device doc + token index).
  $async.Future<UnregisterDeviceResponse> unregisterDevice(
          $pb.ClientContext? ctx, UnregisterDeviceRequest request) =>
      _client.invoke<UnregisterDeviceResponse>(ctx, 'NotificationService',
          'UnregisterDevice', request, UnregisterDeviceResponse());
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
