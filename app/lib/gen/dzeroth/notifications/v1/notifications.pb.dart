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
    $core.String? beaconId,
  }) {
    final result = Notification._();
    if (id != null) result.id = id;
    if (type != null) result.type = type;
    if (actor != null) result.actor = actor;
    if (actorCount != null) result.actorCount = actorCount;
    if (postId != null) result.postId = postId;
    if (createdAt != null) result.createdAt = createdAt;
    if (beaconId != null) result.beaconId = beaconId;
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
    ..aOS(7, _omitFieldNames ? '' : 'beaconId')
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

  /// Subject post (empty for FOLLOW, FOLLOW_REQUEST and FOLLOW_ACCEPTED). Tapping opens /post/:id, or the actor's
  /// profile for FOLLOW and FOLLOW_ACCEPTED.
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

  /// Subject beacon (BEACON_REQUEST, BEACON_ACCEPTED, BEACON_CANCELLED and BEACON_UPDATED only; empty otherwise). Tapping opens the
  /// beacon (BeaconService.GetBeacon).
  @$pb.TagNumber(7)
  $core.String get beaconId => $_getSZ(6);
  @$pb.TagNumber(7)
  set beaconId($core.String value) => $_setString(6, value);
  @$pb.TagNumber(7)
  $core.bool hasBeaconId() => $_has(6);
  @$pb.TagNumber(7)
  void clearBeaconId() => $_clearField(7);
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

/// Push on or off per notification type group. true = the push is sent (the default for everyone).
class NotificationPrefs extends $pb.GeneratedMessage {
  factory NotificationPrefs({
    $core.bool? plansPush,
    $core.bool? mentionsRepliesPush,
    $core.bool? likesRepostsPush,
    $core.bool? followersPush,
    $core.bool? messagesPush,
  }) {
    final result = NotificationPrefs._();
    if (plansPush != null) result.plansPush = plansPush;
    if (mentionsRepliesPush != null)
      result.mentionsRepliesPush = mentionsRepliesPush;
    if (likesRepostsPush != null) result.likesRepostsPush = likesRepostsPush;
    if (followersPush != null) result.followersPush = followersPush;
    if (messagesPush != null) result.messagesPush = messagesPush;
    return result;
  }

  NotificationPrefs._();

  factory NotificationPrefs.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      NotificationPrefs()..mergeFromBuffer(data, registry);
  factory NotificationPrefs.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      NotificationPrefs()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'NotificationPrefs',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.notifications.v1'),
      createEmptyInstance: NotificationPrefs.$_createMessage)
    ..aOB(1, _omitFieldNames ? '' : 'plansPush')
    ..aOB(2, _omitFieldNames ? '' : 'mentionsRepliesPush')
    ..aOB(3, _omitFieldNames ? '' : 'likesRepostsPush')
    ..aOB(4, _omitFieldNames ? '' : 'followersPush')
    ..aOB(5, _omitFieldNames ? '' : 'messagesPush')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  NotificationPrefs clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  NotificationPrefs copyWith(void Function(NotificationPrefs) updates) =>
      super.copyWith((message) => updates(message as NotificationPrefs))
          as NotificationPrefs;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use NotificationPrefs() / NotificationPrefs.new instead')
  static NotificationPrefs create() => NotificationPrefs._();
  static $pb.GeneratedMessage $_createMessage() => NotificationPrefs._();
  @$core.override
  NotificationPrefs createEmptyInstance() => NotificationPrefs._();
  @$core.pragma('dart2js:noInline')
  static NotificationPrefs getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<NotificationPrefs>(
          NotificationPrefs.$_createMessage);
  static NotificationPrefs? _defaultInstance;

  /// Plans: a join request, an accepted request, a cancelled plan.
  @$pb.TagNumber(1)
  $core.bool get plansPush => $_getBF(0);
  @$pb.TagNumber(1)
  set plansPush($core.bool value) => $_setBool(0, value);
  @$pb.TagNumber(1)
  $core.bool hasPlansPush() => $_has(0);
  @$pb.TagNumber(1)
  void clearPlansPush() => $_clearField(1);

  /// Mentions and replies: MENTION, REPLY, QUOTE.
  @$pb.TagNumber(2)
  $core.bool get mentionsRepliesPush => $_getBF(1);
  @$pb.TagNumber(2)
  set mentionsRepliesPush($core.bool value) => $_setBool(1, value);
  @$pb.TagNumber(2)
  $core.bool hasMentionsRepliesPush() => $_has(1);
  @$pb.TagNumber(2)
  void clearMentionsRepliesPush() => $_clearField(2);

  /// Likes and reposts: LIKE, REPOST.
  @$pb.TagNumber(3)
  $core.bool get likesRepostsPush => $_getBF(2);
  @$pb.TagNumber(3)
  set likesRepostsPush($core.bool value) => $_setBool(2, value);
  @$pb.TagNumber(3)
  $core.bool hasLikesRepostsPush() => $_has(2);
  @$pb.TagNumber(3)
  void clearLikesRepostsPush() => $_clearField(3);

  /// Followers: FOLLOW, FOLLOW_REQUEST, FOLLOW_ACCEPTED.
  @$pb.TagNumber(4)
  $core.bool get followersPush => $_getBF(3);
  @$pb.TagNumber(4)
  set followersPush($core.bool value) => $_setBool(3, value);
  @$pb.TagNumber(4)
  $core.bool hasFollowersPush() => $_has(3);
  @$pb.TagNumber(4)
  void clearFollowersPush() => $_clearField(4);

  /// Messages: the direct-message push (which has no in-app row).
  @$pb.TagNumber(5)
  $core.bool get messagesPush => $_getBF(4);
  @$pb.TagNumber(5)
  set messagesPush($core.bool value) => $_setBool(4, value);
  @$pb.TagNumber(5)
  $core.bool hasMessagesPush() => $_has(4);
  @$pb.TagNumber(5)
  void clearMessagesPush() => $_clearField(5);
}

class GetNotificationPrefsRequest extends $pb.GeneratedMessage {
  factory GetNotificationPrefsRequest() => GetNotificationPrefsRequest._();

  GetNotificationPrefsRequest._();

  factory GetNotificationPrefsRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetNotificationPrefsRequest()..mergeFromBuffer(data, registry);
  factory GetNotificationPrefsRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetNotificationPrefsRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetNotificationPrefsRequest',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.notifications.v1'),
      createEmptyInstance: GetNotificationPrefsRequest.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetNotificationPrefsRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetNotificationPrefsRequest copyWith(
          void Function(GetNotificationPrefsRequest) updates) =>
      super.copyWith(
              (message) => updates(message as GetNotificationPrefsRequest))
          as GetNotificationPrefsRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use GetNotificationPrefsRequest() / GetNotificationPrefsRequest.new instead')
  static GetNotificationPrefsRequest create() =>
      GetNotificationPrefsRequest._();
  static $pb.GeneratedMessage $_createMessage() =>
      GetNotificationPrefsRequest._();
  @$core.override
  GetNotificationPrefsRequest createEmptyInstance() =>
      GetNotificationPrefsRequest._();
  @$core.pragma('dart2js:noInline')
  static GetNotificationPrefsRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<GetNotificationPrefsRequest>(
          GetNotificationPrefsRequest.$_createMessage);
  static GetNotificationPrefsRequest? _defaultInstance;
}

class GetNotificationPrefsResponse extends $pb.GeneratedMessage {
  factory GetNotificationPrefsResponse({
    NotificationPrefs? prefs,
  }) {
    final result = GetNotificationPrefsResponse._();
    if (prefs != null) result.prefs = prefs;
    return result;
  }

  GetNotificationPrefsResponse._();

  factory GetNotificationPrefsResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetNotificationPrefsResponse()..mergeFromBuffer(data, registry);
  factory GetNotificationPrefsResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetNotificationPrefsResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetNotificationPrefsResponse',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.notifications.v1'),
      createEmptyInstance: GetNotificationPrefsResponse.$_createMessage)
    ..aOM<NotificationPrefs>(1, _omitFieldNames ? '' : 'prefs',
        subBuilder: NotificationPrefs.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetNotificationPrefsResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetNotificationPrefsResponse copyWith(
          void Function(GetNotificationPrefsResponse) updates) =>
      super.copyWith(
              (message) => updates(message as GetNotificationPrefsResponse))
          as GetNotificationPrefsResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use GetNotificationPrefsResponse() / GetNotificationPrefsResponse.new instead')
  static GetNotificationPrefsResponse create() =>
      GetNotificationPrefsResponse._();
  static $pb.GeneratedMessage $_createMessage() =>
      GetNotificationPrefsResponse._();
  @$core.override
  GetNotificationPrefsResponse createEmptyInstance() =>
      GetNotificationPrefsResponse._();
  @$core.pragma('dart2js:noInline')
  static GetNotificationPrefsResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<GetNotificationPrefsResponse>(
          GetNotificationPrefsResponse.$_createMessage);
  static GetNotificationPrefsResponse? _defaultInstance;

  @$pb.TagNumber(1)
  NotificationPrefs get prefs => $_getN(0);
  @$pb.TagNumber(1)
  set prefs(NotificationPrefs value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasPrefs() => $_has(0);
  @$pb.TagNumber(1)
  void clearPrefs() => $_clearField(1);
  @$pb.TagNumber(1)
  NotificationPrefs ensurePrefs() => $_ensure(0);
}

class UpdateNotificationPrefsRequest extends $pb.GeneratedMessage {
  factory UpdateNotificationPrefsRequest({
    $core.String? idempotencyKey,
    NotificationPrefs? prefs,
  }) {
    final result = UpdateNotificationPrefsRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (prefs != null) result.prefs = prefs;
    return result;
  }

  UpdateNotificationPrefsRequest._();

  factory UpdateNotificationPrefsRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UpdateNotificationPrefsRequest()..mergeFromBuffer(data, registry);
  factory UpdateNotificationPrefsRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UpdateNotificationPrefsRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'UpdateNotificationPrefsRequest',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.notifications.v1'),
      createEmptyInstance: UpdateNotificationPrefsRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOM<NotificationPrefs>(2, _omitFieldNames ? '' : 'prefs',
        subBuilder: NotificationPrefs.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UpdateNotificationPrefsRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UpdateNotificationPrefsRequest copyWith(
          void Function(UpdateNotificationPrefsRequest) updates) =>
      super.copyWith(
              (message) => updates(message as UpdateNotificationPrefsRequest))
          as UpdateNotificationPrefsRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use UpdateNotificationPrefsRequest() / UpdateNotificationPrefsRequest.new instead')
  static UpdateNotificationPrefsRequest create() =>
      UpdateNotificationPrefsRequest._();
  static $pb.GeneratedMessage $_createMessage() =>
      UpdateNotificationPrefsRequest._();
  @$core.override
  UpdateNotificationPrefsRequest createEmptyInstance() =>
      UpdateNotificationPrefsRequest._();
  @$core.pragma('dart2js:noInline')
  static UpdateNotificationPrefsRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<UpdateNotificationPrefsRequest>(
          UpdateNotificationPrefsRequest.$_createMessage);
  static UpdateNotificationPrefsRequest? _defaultInstance;

  /// Format-validated (16-64 characters of [A-Za-z0-9_-]); the operation is a full replace, idempotent by state.
  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  /// Required: every group is sent, a missing one is off.
  @$pb.TagNumber(2)
  NotificationPrefs get prefs => $_getN(1);
  @$pb.TagNumber(2)
  set prefs(NotificationPrefs value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasPrefs() => $_has(1);
  @$pb.TagNumber(2)
  void clearPrefs() => $_clearField(2);
  @$pb.TagNumber(2)
  NotificationPrefs ensurePrefs() => $_ensure(1);
}

class UpdateNotificationPrefsResponse extends $pb.GeneratedMessage {
  factory UpdateNotificationPrefsResponse({
    NotificationPrefs? prefs,
  }) {
    final result = UpdateNotificationPrefsResponse._();
    if (prefs != null) result.prefs = prefs;
    return result;
  }

  UpdateNotificationPrefsResponse._();

  factory UpdateNotificationPrefsResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UpdateNotificationPrefsResponse()..mergeFromBuffer(data, registry);
  factory UpdateNotificationPrefsResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UpdateNotificationPrefsResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'UpdateNotificationPrefsResponse',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.notifications.v1'),
      createEmptyInstance: UpdateNotificationPrefsResponse.$_createMessage)
    ..aOM<NotificationPrefs>(1, _omitFieldNames ? '' : 'prefs',
        subBuilder: NotificationPrefs.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UpdateNotificationPrefsResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UpdateNotificationPrefsResponse copyWith(
          void Function(UpdateNotificationPrefsResponse) updates) =>
      super.copyWith(
              (message) => updates(message as UpdateNotificationPrefsResponse))
          as UpdateNotificationPrefsResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use UpdateNotificationPrefsResponse() / UpdateNotificationPrefsResponse.new instead')
  static UpdateNotificationPrefsResponse create() =>
      UpdateNotificationPrefsResponse._();
  static $pb.GeneratedMessage $_createMessage() =>
      UpdateNotificationPrefsResponse._();
  @$core.override
  UpdateNotificationPrefsResponse createEmptyInstance() =>
      UpdateNotificationPrefsResponse._();
  @$core.pragma('dart2js:noInline')
  static UpdateNotificationPrefsResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<UpdateNotificationPrefsResponse>(
          UpdateNotificationPrefsResponse.$_createMessage);
  static UpdateNotificationPrefsResponse? _defaultInstance;

  @$pb.TagNumber(1)
  NotificationPrefs get prefs => $_getN(0);
  @$pb.TagNumber(1)
  set prefs(NotificationPrefs value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasPrefs() => $_has(0);
  @$pb.TagNumber(1)
  void clearPrefs() => $_clearField(1);
  @$pb.TagNumber(1)
  NotificationPrefs ensurePrefs() => $_ensure(0);
}

class NotificationServiceApi {
  final $pb.RpcClient _client;

  NotificationServiceApi(this._client);

  /// Newest-first notifications for the caller. Every RPC checks FEATURE_NOTIFICATIONS (FAILED_PRECONDITION +
  /// FEATURE_DISABLED when off, before any lookup).
  /// Rows whose most recent actor the caller blocks or mutes, or who blocks the caller, are hidden at read time
  /// (collapsed rows lose such actors from actor_count). Filtering runs after the page query, so a page can be
  /// shorter than page_size, or empty, while more rows exist: keep paging while next_page_token (or
  /// gap_page_token) is set; never infer the end from a short page.
  /// The caller's graph snapshot is cached 60 s and skipped on an empty page; the seen_at profile is cached by the
  /// account-status interceptor. Writes nothing.
  /// Rate limit: default per-minute bucket.
  $async.Future<ListNotificationsResponse> listNotifications(
          $pb.ClientContext? ctx, ListNotificationsRequest request) =>
      _client.invoke<ListNotificationsResponse>(ctx, 'NotificationService',
          'ListNotifications', request, ListNotificationsResponse());

  /// Sets users/{uid}.notificationsSeenAt = now (the badge count drops to 0 within the 30 s GetMe cache; this
  /// instance's cache is evicted at once). Naturally idempotent: a replay just moves seen_at forward, and a call
  /// within 10 s of the previous mark returns that seen_at and writes nothing.
  /// Rate limit: default per-minute bucket; no daily cap.
  $async.Future<MarkNotificationsSeenResponse> markNotificationsSeen(
          $pb.ClientContext? ctx, MarkNotificationsSeenRequest request) =>
      _client.invoke<MarkNotificationsSeenResponse>(ctx, 'NotificationService',
          'MarkNotificationsSeen', request, MarkNotificationsSeenResponse());

  /// Registers (or refreshes) this installation's FCM token under users/{uid}/devices/{device_id}. A token that was
  /// registered by another account on the same device is removed from that account (privacy). At most 5 devices per
  /// user: registering a 6th evicts the least recently refreshed one. Call on sign-in, on token refresh and once per
  /// app start. Naturally idempotent by device_id.
  /// Rate limit: default per-minute bucket; no daily cap.
  /// Registering the same token again within 24 h writes nothing.
  $async.Future<RegisterDeviceResponse> registerDevice(
          $pb.ClientContext? ctx, RegisterDeviceRequest request) =>
      _client.invoke<RegisterDeviceResponse>(ctx, 'NotificationService',
          'RegisterDevice', request, RegisterDeviceResponse());

  /// Removes the device (call on sign-out, before the ID token is dropped). Unknown device_id is a no-op success.
  /// Rate limit: default per-minute bucket; no daily cap.
  /// Deletes the device doc and its token index.
  $async.Future<UnregisterDeviceResponse> unregisterDevice(
          $pb.ClientContext? ctx, UnregisterDeviceRequest request) =>
      _client.invoke<UnregisterDeviceResponse>(ctx, 'NotificationService',
          'UnregisterDevice', request, UnregisterDeviceResponse());

  /// The caller's push preferences: per type group, push on or off. Needs FEATURE_NOTIFICATIONS and
  /// FEATURE_NOTIFICATION_PREFS on for the caller (FAILED_PRECONDITION + FEATURE_DISABLED, metadata["feature"] =
  /// "notification_prefs" for the latter), before any lookup. A user who never saved anything has every group on (today's
  /// behaviour). Reads users/{caller}/settings/notifications (1 read). Rate limit: default per-minute bucket.
  $async.Future<GetNotificationPrefsResponse> getNotificationPrefs(
          $pb.ClientContext? ctx, GetNotificationPrefsRequest request) =>
      _client.invoke<GetNotificationPrefsResponse>(ctx, 'NotificationService',
          'GetNotificationPrefs', request, GetNotificationPrefsResponse());

  /// Replaces the caller's push preferences (every group is sent; false = push off for that group). Same flags as
  /// GetNotificationPrefs. The in-app list and the badge are never affected: a muted group still writes its row, only the
  /// FCM push is skipped. The fan-out reads the preference through a 60 s per-instance cache, so another instance can keep
  /// pushing for up to 60 s after the change. Idempotent by state (a full replace; an update equal to the stored value
  /// writes nothing); idempotency_key is format-validated (VALIDATION when malformed) but not stored. A caller without a
  /// profile => FAILED_PRECONDITION + PROFILE_REQUIRED. Rate limit: default per-minute bucket.
  $async.Future<UpdateNotificationPrefsResponse> updateNotificationPrefs(
          $pb.ClientContext? ctx, UpdateNotificationPrefsRequest request) =>
      _client.invoke<UpdateNotificationPrefsResponse>(
          ctx,
          'NotificationService',
          'UpdateNotificationPrefs',
          request,
          UpdateNotificationPrefsResponse());
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
