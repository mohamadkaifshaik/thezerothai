// This is a generated file - do not edit.
//
// Generated from dzeroth/graph/v1/graph.proto.

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
import 'graph.pbenum.dart';

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

export 'graph.pbenum.dart';

class Relationship extends $pb.GeneratedMessage {
  factory Relationship({
    $core.String? userId,
    FollowState? followState,
    $core.bool? blocking,
    $core.bool? muting,
  }) {
    final result = Relationship._();
    if (userId != null) result.userId = userId;
    if (followState != null) result.followState = followState;
    if (blocking != null) result.blocking = blocking;
    if (muting != null) result.muting = muting;
    return result;
  }

  Relationship._();

  factory Relationship.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Relationship()..mergeFromBuffer(data, registry);
  factory Relationship.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Relationship()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Relationship',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.graph.v1'),
      createEmptyInstance: Relationship.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'userId')
    ..aE<FollowState>(2, _omitFieldNames ? '' : 'followState',
        enumValues: FollowState.values)
    ..aOB(3, _omitFieldNames ? '' : 'blocking')
    ..aOB(4, _omitFieldNames ? '' : 'muting')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Relationship clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Relationship copyWith(void Function(Relationship) updates) =>
      super.copyWith((message) => updates(message as Relationship))
          as Relationship;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Relationship() / Relationship.new instead')
  static Relationship create() => Relationship._();
  static $pb.GeneratedMessage $_createMessage() => Relationship._();
  @$core.override
  Relationship createEmptyInstance() => Relationship._();
  @$core.pragma('dart2js:noInline')
  static Relationship getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<Relationship>(
          Relationship.$_createMessage);
  static Relationship? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get userId => $_getSZ(0);
  @$pb.TagNumber(1)
  set userId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasUserId() => $_has(0);
  @$pb.TagNumber(1)
  void clearUserId() => $_clearField(1);

  @$pb.TagNumber(2)
  FollowState get followState => $_getN(1);
  @$pb.TagNumber(2)
  set followState(FollowState value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasFollowState() => $_has(1);
  @$pb.TagNumber(2)
  void clearFollowState() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.bool get blocking => $_getBF(2);
  @$pb.TagNumber(3)
  set blocking($core.bool value) => $_setBool(2, value);
  @$pb.TagNumber(3)
  $core.bool hasBlocking() => $_has(2);
  @$pb.TagNumber(3)
  void clearBlocking() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.bool get muting => $_getBF(3);
  @$pb.TagNumber(4)
  set muting($core.bool value) => $_setBool(3, value);
  @$pb.TagNumber(4)
  $core.bool hasMuting() => $_has(3);
  @$pb.TagNumber(4)
  void clearMuting() => $_clearField(4);
}

/// A user row in a list, with when the edge was created (unset for blocked/muted: stored as plain uid arrays).
class UserListItem extends $pb.GeneratedMessage {
  factory UserListItem({
    $0.AuthorSnapshot? user,
    $1.Timestamp? since,
    Relationship? relationship,
  }) {
    final result = UserListItem._();
    if (user != null) result.user = user;
    if (since != null) result.since = since;
    if (relationship != null) result.relationship = relationship;
    return result;
  }

  UserListItem._();

  factory UserListItem.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UserListItem()..mergeFromBuffer(data, registry);
  factory UserListItem.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UserListItem()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'UserListItem',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.graph.v1'),
      createEmptyInstance: UserListItem.$_createMessage)
    ..aOM<$0.AuthorSnapshot>(1, _omitFieldNames ? '' : 'user',
        subBuilder: $0.AuthorSnapshot.$_createMessage)
    ..aOM<$1.Timestamp>(2, _omitFieldNames ? '' : 'since',
        subBuilder: $1.Timestamp.$_createMessage)
    ..aOM<Relationship>(3, _omitFieldNames ? '' : 'relationship',
        subBuilder: Relationship.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UserListItem clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UserListItem copyWith(void Function(UserListItem) updates) =>
      super.copyWith((message) => updates(message as UserListItem))
          as UserListItem;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use UserListItem() / UserListItem.new instead')
  static UserListItem create() => UserListItem._();
  static $pb.GeneratedMessage $_createMessage() => UserListItem._();
  @$core.override
  UserListItem createEmptyInstance() => UserListItem._();
  @$core.pragma('dart2js:noInline')
  static UserListItem getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<UserListItem>(
          UserListItem.$_createMessage);
  static UserListItem? _defaultInstance;

  @$pb.TagNumber(1)
  $0.AuthorSnapshot get user => $_getN(0);
  @$pb.TagNumber(1)
  set user($0.AuthorSnapshot value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasUser() => $_has(0);
  @$pb.TagNumber(1)
  void clearUser() => $_clearField(1);
  @$pb.TagNumber(1)
  $0.AuthorSnapshot ensureUser() => $_ensure(0);

  @$pb.TagNumber(2)
  $1.Timestamp get since => $_getN(1);
  @$pb.TagNumber(2)
  set since($1.Timestamp value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasSince() => $_has(1);
  @$pb.TagNumber(2)
  void clearSince() => $_clearField(2);
  @$pb.TagNumber(2)
  $1.Timestamp ensureSince() => $_ensure(1);

  /// The caller's relationship to `user`, computed from the caller's own graph (0 extra reads), so clients can render
  /// follow buttons on list rows without calling GetRelationships.
  @$pb.TagNumber(3)
  Relationship get relationship => $_getN(2);
  @$pb.TagNumber(3)
  set relationship(Relationship value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasRelationship() => $_has(2);
  @$pb.TagNumber(3)
  void clearRelationship() => $_clearField(3);
  @$pb.TagNumber(3)
  Relationship ensureRelationship() => $_ensure(2);
}

class FollowRequest extends $pb.GeneratedMessage {
  factory FollowRequest({
    $core.String? idempotencyKey,
    $core.String? userId,
  }) {
    final result = FollowRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (userId != null) result.userId = userId;
    return result;
  }

  FollowRequest._();

  factory FollowRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      FollowRequest()..mergeFromBuffer(data, registry);
  factory FollowRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      FollowRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'FollowRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.graph.v1'),
      createEmptyInstance: FollowRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'userId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FollowRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FollowRequest copyWith(void Function(FollowRequest) updates) =>
      super.copyWith((message) => updates(message as FollowRequest))
          as FollowRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use FollowRequest() / FollowRequest.new instead')
  static FollowRequest create() => FollowRequest._();
  static $pb.GeneratedMessage $_createMessage() => FollowRequest._();
  @$core.override
  FollowRequest createEmptyInstance() => FollowRequest._();
  @$core.pragma('dart2js:noInline')
  static FollowRequest getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<FollowRequest>(
          FollowRequest.$_createMessage);
  static FollowRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  /// [A-Za-z0-9-]{1,128}. `_` is reserved (the follows doc-id separator, ADR-0008 A3); anything else => VALIDATION.
  /// The same charset applies to every user_id / user_ids field in this service.
  @$pb.TagNumber(2)
  $core.String get userId => $_getSZ(1);
  @$pb.TagNumber(2)
  set userId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasUserId() => $_has(1);
  @$pb.TagNumber(2)
  void clearUserId() => $_clearField(2);
}

class FollowResponse extends $pb.GeneratedMessage {
  factory FollowResponse({
    Relationship? relationship,
  }) {
    final result = FollowResponse._();
    if (relationship != null) result.relationship = relationship;
    return result;
  }

  FollowResponse._();

  factory FollowResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      FollowResponse()..mergeFromBuffer(data, registry);
  factory FollowResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      FollowResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'FollowResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.graph.v1'),
      createEmptyInstance: FollowResponse.$_createMessage)
    ..aOM<Relationship>(1, _omitFieldNames ? '' : 'relationship',
        subBuilder: Relationship.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FollowResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FollowResponse copyWith(void Function(FollowResponse) updates) =>
      super.copyWith((message) => updates(message as FollowResponse))
          as FollowResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use FollowResponse() / FollowResponse.new instead')
  static FollowResponse create() => FollowResponse._();
  static $pb.GeneratedMessage $_createMessage() => FollowResponse._();
  @$core.override
  FollowResponse createEmptyInstance() => FollowResponse._();
  @$core.pragma('dart2js:noInline')
  static FollowResponse getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<FollowResponse>(
          FollowResponse.$_createMessage);
  static FollowResponse? _defaultInstance;

  @$pb.TagNumber(1)
  Relationship get relationship => $_getN(0);
  @$pb.TagNumber(1)
  set relationship(Relationship value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasRelationship() => $_has(0);
  @$pb.TagNumber(1)
  void clearRelationship() => $_clearField(1);
  @$pb.TagNumber(1)
  Relationship ensureRelationship() => $_ensure(0);
}

class UnfollowRequest extends $pb.GeneratedMessage {
  factory UnfollowRequest({
    $core.String? idempotencyKey,
    $core.String? userId,
  }) {
    final result = UnfollowRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (userId != null) result.userId = userId;
    return result;
  }

  UnfollowRequest._();

  factory UnfollowRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UnfollowRequest()..mergeFromBuffer(data, registry);
  factory UnfollowRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UnfollowRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'UnfollowRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.graph.v1'),
      createEmptyInstance: UnfollowRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'userId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UnfollowRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UnfollowRequest copyWith(void Function(UnfollowRequest) updates) =>
      super.copyWith((message) => updates(message as UnfollowRequest))
          as UnfollowRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use UnfollowRequest() / UnfollowRequest.new instead')
  static UnfollowRequest create() => UnfollowRequest._();
  static $pb.GeneratedMessage $_createMessage() => UnfollowRequest._();
  @$core.override
  UnfollowRequest createEmptyInstance() => UnfollowRequest._();
  @$core.pragma('dart2js:noInline')
  static UnfollowRequest getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<UnfollowRequest>(
          UnfollowRequest.$_createMessage);
  static UnfollowRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get userId => $_getSZ(1);
  @$pb.TagNumber(2)
  set userId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasUserId() => $_has(1);
  @$pb.TagNumber(2)
  void clearUserId() => $_clearField(2);
}

class UnfollowResponse extends $pb.GeneratedMessage {
  factory UnfollowResponse({
    Relationship? relationship,
  }) {
    final result = UnfollowResponse._();
    if (relationship != null) result.relationship = relationship;
    return result;
  }

  UnfollowResponse._();

  factory UnfollowResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UnfollowResponse()..mergeFromBuffer(data, registry);
  factory UnfollowResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UnfollowResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'UnfollowResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.graph.v1'),
      createEmptyInstance: UnfollowResponse.$_createMessage)
    ..aOM<Relationship>(1, _omitFieldNames ? '' : 'relationship',
        subBuilder: Relationship.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UnfollowResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UnfollowResponse copyWith(void Function(UnfollowResponse) updates) =>
      super.copyWith((message) => updates(message as UnfollowResponse))
          as UnfollowResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use UnfollowResponse() / UnfollowResponse.new instead')
  static UnfollowResponse create() => UnfollowResponse._();
  static $pb.GeneratedMessage $_createMessage() => UnfollowResponse._();
  @$core.override
  UnfollowResponse createEmptyInstance() => UnfollowResponse._();
  @$core.pragma('dart2js:noInline')
  static UnfollowResponse getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<UnfollowResponse>(
          UnfollowResponse.$_createMessage);
  static UnfollowResponse? _defaultInstance;

  @$pb.TagNumber(1)
  Relationship get relationship => $_getN(0);
  @$pb.TagNumber(1)
  set relationship(Relationship value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasRelationship() => $_has(0);
  @$pb.TagNumber(1)
  void clearRelationship() => $_clearField(1);
  @$pb.TagNumber(1)
  Relationship ensureRelationship() => $_ensure(0);
}

class ListFollowRequestsRequest extends $pb.GeneratedMessage {
  factory ListFollowRequestsRequest({
    $core.int? pageSize,
    $core.String? pageToken,
  }) {
    final result = ListFollowRequestsRequest._();
    if (pageSize != null) result.pageSize = pageSize;
    if (pageToken != null) result.pageToken = pageToken;
    return result;
  }

  ListFollowRequestsRequest._();

  factory ListFollowRequestsRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListFollowRequestsRequest()..mergeFromBuffer(data, registry);
  factory ListFollowRequestsRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListFollowRequestsRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListFollowRequestsRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.graph.v1'),
      createEmptyInstance: ListFollowRequestsRequest.$_createMessage)
    ..aI(1, _omitFieldNames ? '' : 'pageSize')
    ..aOS(2, _omitFieldNames ? '' : 'pageToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListFollowRequestsRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListFollowRequestsRequest copyWith(
          void Function(ListFollowRequestsRequest) updates) =>
      super.copyWith((message) => updates(message as ListFollowRequestsRequest))
          as ListFollowRequestsRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ListFollowRequestsRequest() / ListFollowRequestsRequest.new instead')
  static ListFollowRequestsRequest create() => ListFollowRequestsRequest._();
  static $pb.GeneratedMessage $_createMessage() =>
      ListFollowRequestsRequest._();
  @$core.override
  ListFollowRequestsRequest createEmptyInstance() =>
      ListFollowRequestsRequest._();
  @$core.pragma('dart2js:noInline')
  static ListFollowRequestsRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListFollowRequestsRequest>(
          ListFollowRequestsRequest.$_createMessage);
  static ListFollowRequestsRequest? _defaultInstance;

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
}

class ListFollowRequestsResponse extends $pb.GeneratedMessage {
  factory ListFollowRequestsResponse({
    $core.Iterable<UserListItem>? requests,
    $core.String? nextPageToken,
  }) {
    final result = ListFollowRequestsResponse._();
    if (requests != null) result.requests.addAll(requests);
    if (nextPageToken != null) result.nextPageToken = nextPageToken;
    return result;
  }

  ListFollowRequestsResponse._();

  factory ListFollowRequestsResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListFollowRequestsResponse()..mergeFromBuffer(data, registry);
  factory ListFollowRequestsResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListFollowRequestsResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListFollowRequestsResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.graph.v1'),
      createEmptyInstance: ListFollowRequestsResponse.$_createMessage)
    ..pPM<UserListItem>(1, _omitFieldNames ? '' : 'requests',
        subBuilder: UserListItem.$_createMessage)
    ..aOS(2, _omitFieldNames ? '' : 'nextPageToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListFollowRequestsResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListFollowRequestsResponse copyWith(
          void Function(ListFollowRequestsResponse) updates) =>
      super.copyWith(
              (message) => updates(message as ListFollowRequestsResponse))
          as ListFollowRequestsResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ListFollowRequestsResponse() / ListFollowRequestsResponse.new instead')
  static ListFollowRequestsResponse create() => ListFollowRequestsResponse._();
  static $pb.GeneratedMessage $_createMessage() =>
      ListFollowRequestsResponse._();
  @$core.override
  ListFollowRequestsResponse createEmptyInstance() =>
      ListFollowRequestsResponse._();
  @$core.pragma('dart2js:noInline')
  static ListFollowRequestsResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListFollowRequestsResponse>(
          ListFollowRequestsResponse.$_createMessage);
  static ListFollowRequestsResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<UserListItem> get requests => $_getList(0);

  @$pb.TagNumber(2)
  $core.String get nextPageToken => $_getSZ(1);
  @$pb.TagNumber(2)
  set nextPageToken($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasNextPageToken() => $_has(1);
  @$pb.TagNumber(2)
  void clearNextPageToken() => $_clearField(2);
}

class RespondToFollowRequestRequest extends $pb.GeneratedMessage {
  factory RespondToFollowRequestRequest({
    $core.String? idempotencyKey,
    $core.String? requesterUserId,
    $core.bool? accept,
  }) {
    final result = RespondToFollowRequestRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (requesterUserId != null) result.requesterUserId = requesterUserId;
    if (accept != null) result.accept = accept;
    return result;
  }

  RespondToFollowRequestRequest._();

  factory RespondToFollowRequestRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RespondToFollowRequestRequest()..mergeFromBuffer(data, registry);
  factory RespondToFollowRequestRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RespondToFollowRequestRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RespondToFollowRequestRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.graph.v1'),
      createEmptyInstance: RespondToFollowRequestRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'requesterUserId')
    ..aOB(3, _omitFieldNames ? '' : 'accept')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RespondToFollowRequestRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RespondToFollowRequestRequest copyWith(
          void Function(RespondToFollowRequestRequest) updates) =>
      super.copyWith(
              (message) => updates(message as RespondToFollowRequestRequest))
          as RespondToFollowRequestRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use RespondToFollowRequestRequest() / RespondToFollowRequestRequest.new instead')
  static RespondToFollowRequestRequest create() =>
      RespondToFollowRequestRequest._();
  static $pb.GeneratedMessage $_createMessage() =>
      RespondToFollowRequestRequest._();
  @$core.override
  RespondToFollowRequestRequest createEmptyInstance() =>
      RespondToFollowRequestRequest._();
  @$core.pragma('dart2js:noInline')
  static RespondToFollowRequestRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<RespondToFollowRequestRequest>(
          RespondToFollowRequestRequest.$_createMessage);
  static RespondToFollowRequestRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get requesterUserId => $_getSZ(1);
  @$pb.TagNumber(2)
  set requesterUserId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasRequesterUserId() => $_has(1);
  @$pb.TagNumber(2)
  void clearRequesterUserId() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.bool get accept => $_getBF(2);
  @$pb.TagNumber(3)
  set accept($core.bool value) => $_setBool(2, value);
  @$pb.TagNumber(3)
  $core.bool hasAccept() => $_has(2);
  @$pb.TagNumber(3)
  void clearAccept() => $_clearField(3);
}

class RespondToFollowRequestResponse extends $pb.GeneratedMessage {
  factory RespondToFollowRequestResponse() =>
      RespondToFollowRequestResponse._();

  RespondToFollowRequestResponse._();

  factory RespondToFollowRequestResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RespondToFollowRequestResponse()..mergeFromBuffer(data, registry);
  factory RespondToFollowRequestResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RespondToFollowRequestResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RespondToFollowRequestResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.graph.v1'),
      createEmptyInstance: RespondToFollowRequestResponse.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RespondToFollowRequestResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RespondToFollowRequestResponse copyWith(
          void Function(RespondToFollowRequestResponse) updates) =>
      super.copyWith(
              (message) => updates(message as RespondToFollowRequestResponse))
          as RespondToFollowRequestResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use RespondToFollowRequestResponse() / RespondToFollowRequestResponse.new instead')
  static RespondToFollowRequestResponse create() =>
      RespondToFollowRequestResponse._();
  static $pb.GeneratedMessage $_createMessage() =>
      RespondToFollowRequestResponse._();
  @$core.override
  RespondToFollowRequestResponse createEmptyInstance() =>
      RespondToFollowRequestResponse._();
  @$core.pragma('dart2js:noInline')
  static RespondToFollowRequestResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<RespondToFollowRequestResponse>(
          RespondToFollowRequestResponse.$_createMessage);
  static RespondToFollowRequestResponse? _defaultInstance;
}

class BlockRequest extends $pb.GeneratedMessage {
  factory BlockRequest({
    $core.String? idempotencyKey,
    $core.String? userId,
  }) {
    final result = BlockRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (userId != null) result.userId = userId;
    return result;
  }

  BlockRequest._();

  factory BlockRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      BlockRequest()..mergeFromBuffer(data, registry);
  factory BlockRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      BlockRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'BlockRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.graph.v1'),
      createEmptyInstance: BlockRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'userId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BlockRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BlockRequest copyWith(void Function(BlockRequest) updates) =>
      super.copyWith((message) => updates(message as BlockRequest))
          as BlockRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use BlockRequest() / BlockRequest.new instead')
  static BlockRequest create() => BlockRequest._();
  static $pb.GeneratedMessage $_createMessage() => BlockRequest._();
  @$core.override
  BlockRequest createEmptyInstance() => BlockRequest._();
  @$core.pragma('dart2js:noInline')
  static BlockRequest getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<BlockRequest>(
          BlockRequest.$_createMessage);
  static BlockRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get userId => $_getSZ(1);
  @$pb.TagNumber(2)
  set userId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasUserId() => $_has(1);
  @$pb.TagNumber(2)
  void clearUserId() => $_clearField(2);
}

class BlockResponse extends $pb.GeneratedMessage {
  factory BlockResponse({
    Relationship? relationship,
  }) {
    final result = BlockResponse._();
    if (relationship != null) result.relationship = relationship;
    return result;
  }

  BlockResponse._();

  factory BlockResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      BlockResponse()..mergeFromBuffer(data, registry);
  factory BlockResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      BlockResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'BlockResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.graph.v1'),
      createEmptyInstance: BlockResponse.$_createMessage)
    ..aOM<Relationship>(1, _omitFieldNames ? '' : 'relationship',
        subBuilder: Relationship.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BlockResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BlockResponse copyWith(void Function(BlockResponse) updates) =>
      super.copyWith((message) => updates(message as BlockResponse))
          as BlockResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use BlockResponse() / BlockResponse.new instead')
  static BlockResponse create() => BlockResponse._();
  static $pb.GeneratedMessage $_createMessage() => BlockResponse._();
  @$core.override
  BlockResponse createEmptyInstance() => BlockResponse._();
  @$core.pragma('dart2js:noInline')
  static BlockResponse getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<BlockResponse>(
          BlockResponse.$_createMessage);
  static BlockResponse? _defaultInstance;

  @$pb.TagNumber(1)
  Relationship get relationship => $_getN(0);
  @$pb.TagNumber(1)
  set relationship(Relationship value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasRelationship() => $_has(0);
  @$pb.TagNumber(1)
  void clearRelationship() => $_clearField(1);
  @$pb.TagNumber(1)
  Relationship ensureRelationship() => $_ensure(0);
}

class UnblockRequest extends $pb.GeneratedMessage {
  factory UnblockRequest({
    $core.String? idempotencyKey,
    $core.String? userId,
  }) {
    final result = UnblockRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (userId != null) result.userId = userId;
    return result;
  }

  UnblockRequest._();

  factory UnblockRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UnblockRequest()..mergeFromBuffer(data, registry);
  factory UnblockRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UnblockRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'UnblockRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.graph.v1'),
      createEmptyInstance: UnblockRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'userId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UnblockRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UnblockRequest copyWith(void Function(UnblockRequest) updates) =>
      super.copyWith((message) => updates(message as UnblockRequest))
          as UnblockRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use UnblockRequest() / UnblockRequest.new instead')
  static UnblockRequest create() => UnblockRequest._();
  static $pb.GeneratedMessage $_createMessage() => UnblockRequest._();
  @$core.override
  UnblockRequest createEmptyInstance() => UnblockRequest._();
  @$core.pragma('dart2js:noInline')
  static UnblockRequest getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<UnblockRequest>(
          UnblockRequest.$_createMessage);
  static UnblockRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get userId => $_getSZ(1);
  @$pb.TagNumber(2)
  set userId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasUserId() => $_has(1);
  @$pb.TagNumber(2)
  void clearUserId() => $_clearField(2);
}

class UnblockResponse extends $pb.GeneratedMessage {
  factory UnblockResponse({
    Relationship? relationship,
  }) {
    final result = UnblockResponse._();
    if (relationship != null) result.relationship = relationship;
    return result;
  }

  UnblockResponse._();

  factory UnblockResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UnblockResponse()..mergeFromBuffer(data, registry);
  factory UnblockResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UnblockResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'UnblockResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.graph.v1'),
      createEmptyInstance: UnblockResponse.$_createMessage)
    ..aOM<Relationship>(1, _omitFieldNames ? '' : 'relationship',
        subBuilder: Relationship.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UnblockResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UnblockResponse copyWith(void Function(UnblockResponse) updates) =>
      super.copyWith((message) => updates(message as UnblockResponse))
          as UnblockResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use UnblockResponse() / UnblockResponse.new instead')
  static UnblockResponse create() => UnblockResponse._();
  static $pb.GeneratedMessage $_createMessage() => UnblockResponse._();
  @$core.override
  UnblockResponse createEmptyInstance() => UnblockResponse._();
  @$core.pragma('dart2js:noInline')
  static UnblockResponse getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<UnblockResponse>(
          UnblockResponse.$_createMessage);
  static UnblockResponse? _defaultInstance;

  @$pb.TagNumber(1)
  Relationship get relationship => $_getN(0);
  @$pb.TagNumber(1)
  set relationship(Relationship value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasRelationship() => $_has(0);
  @$pb.TagNumber(1)
  void clearRelationship() => $_clearField(1);
  @$pb.TagNumber(1)
  Relationship ensureRelationship() => $_ensure(0);
}

class MuteRequest extends $pb.GeneratedMessage {
  factory MuteRequest({
    $core.String? idempotencyKey,
    $core.String? userId,
  }) {
    final result = MuteRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (userId != null) result.userId = userId;
    return result;
  }

  MuteRequest._();

  factory MuteRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      MuteRequest()..mergeFromBuffer(data, registry);
  factory MuteRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      MuteRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'MuteRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.graph.v1'),
      createEmptyInstance: MuteRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'userId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MuteRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MuteRequest copyWith(void Function(MuteRequest) updates) =>
      super.copyWith((message) => updates(message as MuteRequest))
          as MuteRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use MuteRequest() / MuteRequest.new instead')
  static MuteRequest create() => MuteRequest._();
  static $pb.GeneratedMessage $_createMessage() => MuteRequest._();
  @$core.override
  MuteRequest createEmptyInstance() => MuteRequest._();
  @$core.pragma('dart2js:noInline')
  static MuteRequest getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<MuteRequest>(
          MuteRequest.$_createMessage);
  static MuteRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get userId => $_getSZ(1);
  @$pb.TagNumber(2)
  set userId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasUserId() => $_has(1);
  @$pb.TagNumber(2)
  void clearUserId() => $_clearField(2);
}

class MuteResponse extends $pb.GeneratedMessage {
  factory MuteResponse({
    Relationship? relationship,
  }) {
    final result = MuteResponse._();
    if (relationship != null) result.relationship = relationship;
    return result;
  }

  MuteResponse._();

  factory MuteResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      MuteResponse()..mergeFromBuffer(data, registry);
  factory MuteResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      MuteResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'MuteResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.graph.v1'),
      createEmptyInstance: MuteResponse.$_createMessage)
    ..aOM<Relationship>(1, _omitFieldNames ? '' : 'relationship',
        subBuilder: Relationship.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MuteResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MuteResponse copyWith(void Function(MuteResponse) updates) =>
      super.copyWith((message) => updates(message as MuteResponse))
          as MuteResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use MuteResponse() / MuteResponse.new instead')
  static MuteResponse create() => MuteResponse._();
  static $pb.GeneratedMessage $_createMessage() => MuteResponse._();
  @$core.override
  MuteResponse createEmptyInstance() => MuteResponse._();
  @$core.pragma('dart2js:noInline')
  static MuteResponse getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<MuteResponse>(
          MuteResponse.$_createMessage);
  static MuteResponse? _defaultInstance;

  @$pb.TagNumber(1)
  Relationship get relationship => $_getN(0);
  @$pb.TagNumber(1)
  set relationship(Relationship value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasRelationship() => $_has(0);
  @$pb.TagNumber(1)
  void clearRelationship() => $_clearField(1);
  @$pb.TagNumber(1)
  Relationship ensureRelationship() => $_ensure(0);
}

class UnmuteRequest extends $pb.GeneratedMessage {
  factory UnmuteRequest({
    $core.String? idempotencyKey,
    $core.String? userId,
  }) {
    final result = UnmuteRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (userId != null) result.userId = userId;
    return result;
  }

  UnmuteRequest._();

  factory UnmuteRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UnmuteRequest()..mergeFromBuffer(data, registry);
  factory UnmuteRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UnmuteRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'UnmuteRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.graph.v1'),
      createEmptyInstance: UnmuteRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'userId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UnmuteRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UnmuteRequest copyWith(void Function(UnmuteRequest) updates) =>
      super.copyWith((message) => updates(message as UnmuteRequest))
          as UnmuteRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use UnmuteRequest() / UnmuteRequest.new instead')
  static UnmuteRequest create() => UnmuteRequest._();
  static $pb.GeneratedMessage $_createMessage() => UnmuteRequest._();
  @$core.override
  UnmuteRequest createEmptyInstance() => UnmuteRequest._();
  @$core.pragma('dart2js:noInline')
  static UnmuteRequest getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<UnmuteRequest>(
          UnmuteRequest.$_createMessage);
  static UnmuteRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get userId => $_getSZ(1);
  @$pb.TagNumber(2)
  set userId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasUserId() => $_has(1);
  @$pb.TagNumber(2)
  void clearUserId() => $_clearField(2);
}

class UnmuteResponse extends $pb.GeneratedMessage {
  factory UnmuteResponse({
    Relationship? relationship,
  }) {
    final result = UnmuteResponse._();
    if (relationship != null) result.relationship = relationship;
    return result;
  }

  UnmuteResponse._();

  factory UnmuteResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UnmuteResponse()..mergeFromBuffer(data, registry);
  factory UnmuteResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UnmuteResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'UnmuteResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.graph.v1'),
      createEmptyInstance: UnmuteResponse.$_createMessage)
    ..aOM<Relationship>(1, _omitFieldNames ? '' : 'relationship',
        subBuilder: Relationship.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UnmuteResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UnmuteResponse copyWith(void Function(UnmuteResponse) updates) =>
      super.copyWith((message) => updates(message as UnmuteResponse))
          as UnmuteResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use UnmuteResponse() / UnmuteResponse.new instead')
  static UnmuteResponse create() => UnmuteResponse._();
  static $pb.GeneratedMessage $_createMessage() => UnmuteResponse._();
  @$core.override
  UnmuteResponse createEmptyInstance() => UnmuteResponse._();
  @$core.pragma('dart2js:noInline')
  static UnmuteResponse getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<UnmuteResponse>(
          UnmuteResponse.$_createMessage);
  static UnmuteResponse? _defaultInstance;

  @$pb.TagNumber(1)
  Relationship get relationship => $_getN(0);
  @$pb.TagNumber(1)
  set relationship(Relationship value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasRelationship() => $_has(0);
  @$pb.TagNumber(1)
  void clearRelationship() => $_clearField(1);
  @$pb.TagNumber(1)
  Relationship ensureRelationship() => $_ensure(0);
}

class GetRelationshipsRequest extends $pb.GeneratedMessage {
  factory GetRelationshipsRequest({
    $core.Iterable<$core.String>? userIds,
  }) {
    final result = GetRelationshipsRequest._();
    if (userIds != null) result.userIds.addAll(userIds);
    return result;
  }

  GetRelationshipsRequest._();

  factory GetRelationshipsRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetRelationshipsRequest()..mergeFromBuffer(data, registry);
  factory GetRelationshipsRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetRelationshipsRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetRelationshipsRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.graph.v1'),
      createEmptyInstance: GetRelationshipsRequest.$_createMessage)
    ..pPS(1, _omitFieldNames ? '' : 'userIds')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetRelationshipsRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetRelationshipsRequest copyWith(
          void Function(GetRelationshipsRequest) updates) =>
      super.copyWith((message) => updates(message as GetRelationshipsRequest))
          as GetRelationshipsRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use GetRelationshipsRequest() / GetRelationshipsRequest.new instead')
  static GetRelationshipsRequest create() => GetRelationshipsRequest._();
  static $pb.GeneratedMessage $_createMessage() => GetRelationshipsRequest._();
  @$core.override
  GetRelationshipsRequest createEmptyInstance() => GetRelationshipsRequest._();
  @$core.pragma('dart2js:noInline')
  static GetRelationshipsRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<GetRelationshipsRequest>(
          GetRelationshipsRequest.$_createMessage);
  static GetRelationshipsRequest? _defaultInstance;

  /// 1-50 user ids.
  @$pb.TagNumber(1)
  $pb.PbList<$core.String> get userIds => $_getList(0);
}

class GetRelationshipsResponse extends $pb.GeneratedMessage {
  factory GetRelationshipsResponse({
    $core.Iterable<Relationship>? relationships,
  }) {
    final result = GetRelationshipsResponse._();
    if (relationships != null) result.relationships.addAll(relationships);
    return result;
  }

  GetRelationshipsResponse._();

  factory GetRelationshipsResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetRelationshipsResponse()..mergeFromBuffer(data, registry);
  factory GetRelationshipsResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetRelationshipsResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetRelationshipsResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.graph.v1'),
      createEmptyInstance: GetRelationshipsResponse.$_createMessage)
    ..pPM<Relationship>(1, _omitFieldNames ? '' : 'relationships',
        subBuilder: Relationship.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetRelationshipsResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetRelationshipsResponse copyWith(
          void Function(GetRelationshipsResponse) updates) =>
      super.copyWith((message) => updates(message as GetRelationshipsResponse))
          as GetRelationshipsResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use GetRelationshipsResponse() / GetRelationshipsResponse.new instead')
  static GetRelationshipsResponse create() => GetRelationshipsResponse._();
  static $pb.GeneratedMessage $_createMessage() => GetRelationshipsResponse._();
  @$core.override
  GetRelationshipsResponse createEmptyInstance() =>
      GetRelationshipsResponse._();
  @$core.pragma('dart2js:noInline')
  static GetRelationshipsResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<GetRelationshipsResponse>(
          GetRelationshipsResponse.$_createMessage);
  static GetRelationshipsResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<Relationship> get relationships => $_getList(0);
}

class ListFollowersRequest extends $pb.GeneratedMessage {
  factory ListFollowersRequest({
    $core.String? userId,
    $core.int? pageSize,
    $core.String? pageToken,
  }) {
    final result = ListFollowersRequest._();
    if (userId != null) result.userId = userId;
    if (pageSize != null) result.pageSize = pageSize;
    if (pageToken != null) result.pageToken = pageToken;
    return result;
  }

  ListFollowersRequest._();

  factory ListFollowersRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListFollowersRequest()..mergeFromBuffer(data, registry);
  factory ListFollowersRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListFollowersRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListFollowersRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.graph.v1'),
      createEmptyInstance: ListFollowersRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'userId')
    ..aI(2, _omitFieldNames ? '' : 'pageSize')
    ..aOS(3, _omitFieldNames ? '' : 'pageToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListFollowersRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListFollowersRequest copyWith(void Function(ListFollowersRequest) updates) =>
      super.copyWith((message) => updates(message as ListFollowersRequest))
          as ListFollowersRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ListFollowersRequest() / ListFollowersRequest.new instead')
  static ListFollowersRequest create() => ListFollowersRequest._();
  static $pb.GeneratedMessage $_createMessage() => ListFollowersRequest._();
  @$core.override
  ListFollowersRequest createEmptyInstance() => ListFollowersRequest._();
  @$core.pragma('dart2js:noInline')
  static ListFollowersRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListFollowersRequest>(
          ListFollowersRequest.$_createMessage);
  static ListFollowersRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get userId => $_getSZ(0);
  @$pb.TagNumber(1)
  set userId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasUserId() => $_has(0);
  @$pb.TagNumber(1)
  void clearUserId() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.int get pageSize => $_getIZ(1);
  @$pb.TagNumber(2)
  set pageSize($core.int value) => $_setSignedInt32(1, value);
  @$pb.TagNumber(2)
  $core.bool hasPageSize() => $_has(1);
  @$pb.TagNumber(2)
  void clearPageSize() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get pageToken => $_getSZ(2);
  @$pb.TagNumber(3)
  set pageToken($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasPageToken() => $_has(2);
  @$pb.TagNumber(3)
  void clearPageToken() => $_clearField(3);
}

class ListFollowersResponse extends $pb.GeneratedMessage {
  factory ListFollowersResponse({
    $core.Iterable<UserListItem>? users,
    $core.String? nextPageToken,
  }) {
    final result = ListFollowersResponse._();
    if (users != null) result.users.addAll(users);
    if (nextPageToken != null) result.nextPageToken = nextPageToken;
    return result;
  }

  ListFollowersResponse._();

  factory ListFollowersResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListFollowersResponse()..mergeFromBuffer(data, registry);
  factory ListFollowersResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListFollowersResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListFollowersResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.graph.v1'),
      createEmptyInstance: ListFollowersResponse.$_createMessage)
    ..pPM<UserListItem>(1, _omitFieldNames ? '' : 'users',
        subBuilder: UserListItem.$_createMessage)
    ..aOS(2, _omitFieldNames ? '' : 'nextPageToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListFollowersResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListFollowersResponse copyWith(
          void Function(ListFollowersResponse) updates) =>
      super.copyWith((message) => updates(message as ListFollowersResponse))
          as ListFollowersResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ListFollowersResponse() / ListFollowersResponse.new instead')
  static ListFollowersResponse create() => ListFollowersResponse._();
  static $pb.GeneratedMessage $_createMessage() => ListFollowersResponse._();
  @$core.override
  ListFollowersResponse createEmptyInstance() => ListFollowersResponse._();
  @$core.pragma('dart2js:noInline')
  static ListFollowersResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListFollowersResponse>(
          ListFollowersResponse.$_createMessage);
  static ListFollowersResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<UserListItem> get users => $_getList(0);

  @$pb.TagNumber(2)
  $core.String get nextPageToken => $_getSZ(1);
  @$pb.TagNumber(2)
  set nextPageToken($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasNextPageToken() => $_has(1);
  @$pb.TagNumber(2)
  void clearNextPageToken() => $_clearField(2);
}

class ListFollowingRequest extends $pb.GeneratedMessage {
  factory ListFollowingRequest({
    $core.String? userId,
    $core.int? pageSize,
    $core.String? pageToken,
  }) {
    final result = ListFollowingRequest._();
    if (userId != null) result.userId = userId;
    if (pageSize != null) result.pageSize = pageSize;
    if (pageToken != null) result.pageToken = pageToken;
    return result;
  }

  ListFollowingRequest._();

  factory ListFollowingRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListFollowingRequest()..mergeFromBuffer(data, registry);
  factory ListFollowingRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListFollowingRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListFollowingRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.graph.v1'),
      createEmptyInstance: ListFollowingRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'userId')
    ..aI(2, _omitFieldNames ? '' : 'pageSize')
    ..aOS(3, _omitFieldNames ? '' : 'pageToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListFollowingRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListFollowingRequest copyWith(void Function(ListFollowingRequest) updates) =>
      super.copyWith((message) => updates(message as ListFollowingRequest))
          as ListFollowingRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ListFollowingRequest() / ListFollowingRequest.new instead')
  static ListFollowingRequest create() => ListFollowingRequest._();
  static $pb.GeneratedMessage $_createMessage() => ListFollowingRequest._();
  @$core.override
  ListFollowingRequest createEmptyInstance() => ListFollowingRequest._();
  @$core.pragma('dart2js:noInline')
  static ListFollowingRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListFollowingRequest>(
          ListFollowingRequest.$_createMessage);
  static ListFollowingRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get userId => $_getSZ(0);
  @$pb.TagNumber(1)
  set userId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasUserId() => $_has(0);
  @$pb.TagNumber(1)
  void clearUserId() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.int get pageSize => $_getIZ(1);
  @$pb.TagNumber(2)
  set pageSize($core.int value) => $_setSignedInt32(1, value);
  @$pb.TagNumber(2)
  $core.bool hasPageSize() => $_has(1);
  @$pb.TagNumber(2)
  void clearPageSize() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get pageToken => $_getSZ(2);
  @$pb.TagNumber(3)
  set pageToken($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasPageToken() => $_has(2);
  @$pb.TagNumber(3)
  void clearPageToken() => $_clearField(3);
}

class ListFollowingResponse extends $pb.GeneratedMessage {
  factory ListFollowingResponse({
    $core.Iterable<UserListItem>? users,
    $core.String? nextPageToken,
  }) {
    final result = ListFollowingResponse._();
    if (users != null) result.users.addAll(users);
    if (nextPageToken != null) result.nextPageToken = nextPageToken;
    return result;
  }

  ListFollowingResponse._();

  factory ListFollowingResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListFollowingResponse()..mergeFromBuffer(data, registry);
  factory ListFollowingResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListFollowingResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListFollowingResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.graph.v1'),
      createEmptyInstance: ListFollowingResponse.$_createMessage)
    ..pPM<UserListItem>(1, _omitFieldNames ? '' : 'users',
        subBuilder: UserListItem.$_createMessage)
    ..aOS(2, _omitFieldNames ? '' : 'nextPageToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListFollowingResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListFollowingResponse copyWith(
          void Function(ListFollowingResponse) updates) =>
      super.copyWith((message) => updates(message as ListFollowingResponse))
          as ListFollowingResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ListFollowingResponse() / ListFollowingResponse.new instead')
  static ListFollowingResponse create() => ListFollowingResponse._();
  static $pb.GeneratedMessage $_createMessage() => ListFollowingResponse._();
  @$core.override
  ListFollowingResponse createEmptyInstance() => ListFollowingResponse._();
  @$core.pragma('dart2js:noInline')
  static ListFollowingResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListFollowingResponse>(
          ListFollowingResponse.$_createMessage);
  static ListFollowingResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<UserListItem> get users => $_getList(0);

  @$pb.TagNumber(2)
  $core.String get nextPageToken => $_getSZ(1);
  @$pb.TagNumber(2)
  set nextPageToken($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasNextPageToken() => $_has(1);
  @$pb.TagNumber(2)
  void clearNextPageToken() => $_clearField(2);
}

class ListBlockedUsersRequest extends $pb.GeneratedMessage {
  factory ListBlockedUsersRequest({
    $core.int? pageSize,
    $core.String? pageToken,
  }) {
    final result = ListBlockedUsersRequest._();
    if (pageSize != null) result.pageSize = pageSize;
    if (pageToken != null) result.pageToken = pageToken;
    return result;
  }

  ListBlockedUsersRequest._();

  factory ListBlockedUsersRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListBlockedUsersRequest()..mergeFromBuffer(data, registry);
  factory ListBlockedUsersRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListBlockedUsersRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListBlockedUsersRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.graph.v1'),
      createEmptyInstance: ListBlockedUsersRequest.$_createMessage)
    ..aI(1, _omitFieldNames ? '' : 'pageSize')
    ..aOS(2, _omitFieldNames ? '' : 'pageToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListBlockedUsersRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListBlockedUsersRequest copyWith(
          void Function(ListBlockedUsersRequest) updates) =>
      super.copyWith((message) => updates(message as ListBlockedUsersRequest))
          as ListBlockedUsersRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ListBlockedUsersRequest() / ListBlockedUsersRequest.new instead')
  static ListBlockedUsersRequest create() => ListBlockedUsersRequest._();
  static $pb.GeneratedMessage $_createMessage() => ListBlockedUsersRequest._();
  @$core.override
  ListBlockedUsersRequest createEmptyInstance() => ListBlockedUsersRequest._();
  @$core.pragma('dart2js:noInline')
  static ListBlockedUsersRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListBlockedUsersRequest>(
          ListBlockedUsersRequest.$_createMessage);
  static ListBlockedUsersRequest? _defaultInstance;

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
}

class ListBlockedUsersResponse extends $pb.GeneratedMessage {
  factory ListBlockedUsersResponse({
    $core.Iterable<UserListItem>? users,
    $core.String? nextPageToken,
  }) {
    final result = ListBlockedUsersResponse._();
    if (users != null) result.users.addAll(users);
    if (nextPageToken != null) result.nextPageToken = nextPageToken;
    return result;
  }

  ListBlockedUsersResponse._();

  factory ListBlockedUsersResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListBlockedUsersResponse()..mergeFromBuffer(data, registry);
  factory ListBlockedUsersResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListBlockedUsersResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListBlockedUsersResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.graph.v1'),
      createEmptyInstance: ListBlockedUsersResponse.$_createMessage)
    ..pPM<UserListItem>(1, _omitFieldNames ? '' : 'users',
        subBuilder: UserListItem.$_createMessage)
    ..aOS(2, _omitFieldNames ? '' : 'nextPageToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListBlockedUsersResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListBlockedUsersResponse copyWith(
          void Function(ListBlockedUsersResponse) updates) =>
      super.copyWith((message) => updates(message as ListBlockedUsersResponse))
          as ListBlockedUsersResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ListBlockedUsersResponse() / ListBlockedUsersResponse.new instead')
  static ListBlockedUsersResponse create() => ListBlockedUsersResponse._();
  static $pb.GeneratedMessage $_createMessage() => ListBlockedUsersResponse._();
  @$core.override
  ListBlockedUsersResponse createEmptyInstance() =>
      ListBlockedUsersResponse._();
  @$core.pragma('dart2js:noInline')
  static ListBlockedUsersResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListBlockedUsersResponse>(
          ListBlockedUsersResponse.$_createMessage);
  static ListBlockedUsersResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<UserListItem> get users => $_getList(0);

  @$pb.TagNumber(2)
  $core.String get nextPageToken => $_getSZ(1);
  @$pb.TagNumber(2)
  set nextPageToken($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasNextPageToken() => $_has(1);
  @$pb.TagNumber(2)
  void clearNextPageToken() => $_clearField(2);
}

class ListMutedUsersRequest extends $pb.GeneratedMessage {
  factory ListMutedUsersRequest({
    $core.int? pageSize,
    $core.String? pageToken,
  }) {
    final result = ListMutedUsersRequest._();
    if (pageSize != null) result.pageSize = pageSize;
    if (pageToken != null) result.pageToken = pageToken;
    return result;
  }

  ListMutedUsersRequest._();

  factory ListMutedUsersRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListMutedUsersRequest()..mergeFromBuffer(data, registry);
  factory ListMutedUsersRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListMutedUsersRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListMutedUsersRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.graph.v1'),
      createEmptyInstance: ListMutedUsersRequest.$_createMessage)
    ..aI(1, _omitFieldNames ? '' : 'pageSize')
    ..aOS(2, _omitFieldNames ? '' : 'pageToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListMutedUsersRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListMutedUsersRequest copyWith(
          void Function(ListMutedUsersRequest) updates) =>
      super.copyWith((message) => updates(message as ListMutedUsersRequest))
          as ListMutedUsersRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ListMutedUsersRequest() / ListMutedUsersRequest.new instead')
  static ListMutedUsersRequest create() => ListMutedUsersRequest._();
  static $pb.GeneratedMessage $_createMessage() => ListMutedUsersRequest._();
  @$core.override
  ListMutedUsersRequest createEmptyInstance() => ListMutedUsersRequest._();
  @$core.pragma('dart2js:noInline')
  static ListMutedUsersRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListMutedUsersRequest>(
          ListMutedUsersRequest.$_createMessage);
  static ListMutedUsersRequest? _defaultInstance;

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
}

class ListMutedUsersResponse extends $pb.GeneratedMessage {
  factory ListMutedUsersResponse({
    $core.Iterable<UserListItem>? users,
    $core.String? nextPageToken,
  }) {
    final result = ListMutedUsersResponse._();
    if (users != null) result.users.addAll(users);
    if (nextPageToken != null) result.nextPageToken = nextPageToken;
    return result;
  }

  ListMutedUsersResponse._();

  factory ListMutedUsersResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListMutedUsersResponse()..mergeFromBuffer(data, registry);
  factory ListMutedUsersResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListMutedUsersResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListMutedUsersResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.graph.v1'),
      createEmptyInstance: ListMutedUsersResponse.$_createMessage)
    ..pPM<UserListItem>(1, _omitFieldNames ? '' : 'users',
        subBuilder: UserListItem.$_createMessage)
    ..aOS(2, _omitFieldNames ? '' : 'nextPageToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListMutedUsersResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListMutedUsersResponse copyWith(
          void Function(ListMutedUsersResponse) updates) =>
      super.copyWith((message) => updates(message as ListMutedUsersResponse))
          as ListMutedUsersResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ListMutedUsersResponse() / ListMutedUsersResponse.new instead')
  static ListMutedUsersResponse create() => ListMutedUsersResponse._();
  static $pb.GeneratedMessage $_createMessage() => ListMutedUsersResponse._();
  @$core.override
  ListMutedUsersResponse createEmptyInstance() => ListMutedUsersResponse._();
  @$core.pragma('dart2js:noInline')
  static ListMutedUsersResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListMutedUsersResponse>(
          ListMutedUsersResponse.$_createMessage);
  static ListMutedUsersResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<UserListItem> get users => $_getList(0);

  @$pb.TagNumber(2)
  $core.String get nextPageToken => $_getSZ(1);
  @$pb.TagNumber(2)
  set nextPageToken($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasNextPageToken() => $_has(1);
  @$pb.TagNumber(2)
  void clearNextPageToken() => $_clearField(2);
}

class GraphServiceApi {
  final $pb.RpcClient _client;

  GraphServiceApi(this._client);

  /// Follow a public user. Quota: 200 follows/day (50 for accounts < 24 h). Cap: 5,000 following (graph doc size).
  /// Transaction: caller graph + quotas/{uid} read fresh; target and caller users docs from the 60 s instance cache.
  /// Writes: follows doc, caller graph, caller users counter, target users counter, quotas.
  /// Errors: self => VALIDATION; target missing, not active, or blocked the caller => NOT_FOUND; caller blocks the
  /// target => FAILED_PRECONDITION + TARGET_BLOCKED; private target (legacy data) => FEATURE_DISABLED; at the cap =>
  /// LIMIT_REACHED; over quota => QUOTA_EXCEEDED. Replay (already following) => FOLLOWING, 0 writes.
  /// No notification write in this slice (the notifications plan adds its own budget).
  /// Firestore: reads 4 cold / 2 warm (+1 if the caller's blockedBy overflowed, ADR-0008 D2), writes 5; replay reads
  /// 4 cold / 2 warm, writes 0 (cold = the identity profile cache misses, which a preceding Follow's eviction makes
  /// the norm; ADR-0008 A2, planning value 4). user_id: [A-Za-z0-9-]{1,128}.
  $async.Future<FollowResponse> follow(
          $pb.ClientContext? ctx, FollowRequest request) =>
      _client.invoke<FollowResponse>(
          ctx, 'GraphService', 'Follow', request, FollowResponse());

  /// Unfollow. Blind batch: delete follows doc (Exists precondition) + caller graph following -= + 2 users counters.
  /// Not following => NONE with 0 writes (the precondition fails the whole batch).
  /// Firestore: the batch reads 0, writes 3 (0 on no-op), deletes 1; the request logs 1 read (the caller's profile
  /// read by the account-status check, cold after a preceding Follow; ADR-0008 Amendment 2026-09-30 (2)).
  /// user_id: [A-Za-z0-9-]{1,128}.
  $async.Future<UnfollowResponse> unfollow(
          $pb.ClientContext? ctx, UnfollowRequest request) =>
      _client.invoke<UnfollowResponse>(
          ctx, 'GraphService', 'Unfollow', request, UnfollowResponse());

  /// Incoming follow requests for the caller (private accounts).
  /// Until private accounts ship (ADR-0008 D1): always FAILED_PRECONDITION + ERROR_REASON_FEATURE_DISABLED.
  /// Firestore: reads 0/0, writes 0 (planned when enabled: reads 100/5, page + hydration, users cached 60 s).
  $async.Future<ListFollowRequestsResponse> listFollowRequests(
          $pb.ClientContext? ctx, ListFollowRequestsRequest request) =>
      _client.invoke<ListFollowRequestsResponse>(ctx, 'GraphService',
          'ListFollowRequests', request, ListFollowRequestsResponse());

  /// Accept or decline an incoming request. Replay: request doc already gone => returns current state.
  /// Until private accounts ship (ADR-0008 D1): always FAILED_PRECONDITION + ERROR_REASON_FEATURE_DISABLED.
  /// Planned: delete request, create follows, requester graph (following += , requested -=), 2 users counters.
  /// Firestore: reads 0/0, writes 0 (planned when enabled: reads 1/1, writes 4/4, deletes 1/1).
  $async.Future<RespondToFollowRequestResponse> respondToFollowRequest(
          $pb.ClientContext? ctx, RespondToFollowRequestRequest request) =>
      _client.invoke<RespondToFollowRequestResponse>(ctx, 'GraphService',
          'RespondToFollowRequest', request, RespondToFollowRequestResponse());

  /// Block: removes follows in both directions (Unblock does not restore them).
  /// Transaction reads both graphs + quotas/{uid}. Writes: caller graph (blocked +=, following -=), target graph
  /// (blockedBy +=, following -=), quotas (blocks) and, when edges existed, both users docs (counter decrements
  /// combined per doc) + follows deletes. Worst = mutual follow.
  /// Quota: 200 blocks+mutes/day (50 for accounts < 24 h). Cap: 2,000 blocked => LIMIT_REACHED.
  /// Self => VALIDATION; unknown user => NOT_FOUND. Replay (already blocking) => blocking=true, 0 writes.
  /// Firestore: reads 3/3, writes 5/3, deletes 2/0.
  $async.Future<BlockResponse> block(
          $pb.ClientContext? ctx, BlockRequest request) =>
      _client.invoke<BlockResponse>(
          ctx, 'GraphService', 'Block', request, BlockResponse());

  /// Removes the block on both sides (caller blocked -=, target blockedBy -=). Follows are not restored.
  /// Caller graph is read fresh; not blocking => 0 writes. Never quota-gated.
  /// Firestore: reads 1/1, writes 2/2 (0 on no-op).
  $async.Future<UnblockResponse> unblock(
          $pb.ClientContext? ctx, UnblockRequest request) =>
      _client.invoke<UnblockResponse>(
          ctx, 'GraphService', 'Unblock', request, UnblockResponse());

  /// Mute hides the target's posts from the caller's timelines and notifications only; never visible to the target.
  /// Transaction reads caller graph, then the target's graph doc (existence only; its content, including who blocked
  /// whom, is never inspected), then quotas/{uid}; writes caller graph (muted +=) + quotas (blocks).
  /// Quota: shared with Block. Cap: 2,000 muted => LIMIT_REACHED. Replay (already muting) => 0 writes.
  /// Target without an account => NOT_FOUND (same rule and response as Block; ADR-0008 A1), 0 writes, no quota used.
  /// Muting a user who blocked the caller succeeds exactly as for a stranger.
  /// Firestore: reads 3, writes 2 (0 on replay); NOT_FOUND reads 2. user_id: [A-Za-z0-9-]{1,128}.
  $async.Future<MuteResponse> mute(
          $pb.ClientContext? ctx, MuteRequest request) =>
      _client.invoke<MuteResponse>(
          ctx, 'GraphService', 'Mute', request, MuteResponse());

  /// Caller graph is read fresh; not muting => 0 writes. Never quota-gated.
  /// Firestore: reads 1/1, writes 1/1 (0 on no-op).
  $async.Future<UnmuteResponse> unmute(
          $pb.ClientContext? ctx, UnmuteRequest request) =>
      _client.invoke<UnmuteResponse>(
          ctx, 'GraphService', 'Unmute', request, UnmuteResponse());

  /// Caller's relationship to up to 50 users, computed from the caller's graph doc only (1 read, cached 60 s).
  /// Does not report whether the target follows the caller (that would cost 1 read per user).
  /// Never reflects blocks against the caller: a user who blocked the caller looks like a stranger (only the
  /// caller's own blocking/muting bits are reported). The caller's own id => NONE.
  /// Firestore: reads 1/0.5 (graph cached 60 s), writes 0.
  $async.Future<GetRelationshipsResponse> getRelationships(
          $pb.ClientContext? ctx, GetRelationshipsRequest request) =>
      _client.invoke<GetRelationshipsResponse>(ctx, 'GraphService',
          'GetRelationships', request, GetRelationshipsResponse());

  /// Followers of a user, newest first. NOT_FOUND if the target is missing, not active, or blocked the caller.
  /// Rows for users the caller blocks or who blocked the caller are dropped (pages may be short; follow
  /// next_page_token). Each row carries the caller's relationship to that user (0 extra reads).
  /// Reads: target user + caller graph (both cached 60 s) + follows page (Limit page_size) + GetAll users hydration.
  /// Firestore: reads 102/30, writes 0.
  $async.Future<ListFollowersResponse> listFollowers(
          $pb.ClientContext? ctx, ListFollowersRequest request) =>
      _client.invoke<ListFollowersResponse>(ctx, 'GraphService',
          'ListFollowers', request, ListFollowersResponse());

  /// Accounts a user follows, newest first. Same visibility, row filtering and cost shape as ListFollowers.
  /// Firestore: reads 102/30, writes 0.
  $async.Future<ListFollowingResponse> listFollowing(
          $pb.ClientContext? ctx, ListFollowingRequest request) =>
      _client.invoke<ListFollowingResponse>(ctx, 'GraphService',
          'ListFollowing', request, ListFollowingResponse());

  /// Caller's blocked accounts (from graph doc, newest first) hydrated with GetAll users (cached 60 s).
  /// Users who blocked the caller, and missing or inactive users, are omitted (ADR-0008 D9).
  /// Firestore: reads 51/10, writes 0, plus at most +1 write (one ArrayRemove of at most 50 ids, T27) on a page
  /// that finds a uid with no users doc, once per stale entry.
  $async.Future<ListBlockedUsersResponse> listBlockedUsers(
          $pb.ClientContext? ctx, ListBlockedUsersRequest request) =>
      _client.invoke<ListBlockedUsersResponse>(ctx, 'GraphService',
          'ListBlockedUsers', request, ListBlockedUsersResponse());

  /// Caller's muted accounts (from graph doc, newest first) hydrated with GetAll users (cached 60 s).
  /// Users who blocked the caller, and missing or inactive users, are omitted (ADR-0008 D9).
  /// Firestore: reads 51/10, writes 0, plus at most +1 write (one ArrayRemove of at most 50 ids, T27) on a page
  /// that finds a uid with no users doc, once per stale entry.
  $async.Future<ListMutedUsersResponse> listMutedUsers(
          $pb.ClientContext? ctx, ListMutedUsersRequest request) =>
      _client.invoke<ListMutedUsersResponse>(ctx, 'GraphService',
          'ListMutedUsers', request, ListMutedUsersResponse());
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
