// This is a generated file - do not edit.
//
// Generated from dzeroth/lists/v1/lists.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:async' as $async;
import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

import '../../common/v1/common.pb.dart' as $0;
import '../../graph/v1/graph.pb.dart' as $1;

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

/// One list as the caller may see it.
class ListInfo extends $pb.GeneratedMessage {
  factory ListInfo({
    $core.String? listId,
    $0.AuthorSnapshot? owner,
    $core.String? name,
    $core.String? description,
    $core.bool? isPrivate,
    $core.int? memberCount,
    $core.bool? pinnedByViewer,
  }) {
    final result = ListInfo._();
    if (listId != null) result.listId = listId;
    if (owner != null) result.owner = owner;
    if (name != null) result.name = name;
    if (description != null) result.description = description;
    if (isPrivate != null) result.isPrivate = isPrivate;
    if (memberCount != null) result.memberCount = memberCount;
    if (pinnedByViewer != null) result.pinnedByViewer = pinnedByViewer;
    return result;
  }

  ListInfo._();

  factory ListInfo.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListInfo()..mergeFromBuffer(data, registry);
  factory ListInfo.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListInfo()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListInfo',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.lists.v1'),
      createEmptyInstance: ListInfo.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'listId')
    ..aOM<$0.AuthorSnapshot>(2, _omitFieldNames ? '' : 'owner',
        subBuilder: $0.AuthorSnapshot.$_createMessage)
    ..aOS(3, _omitFieldNames ? '' : 'name')
    ..aOS(4, _omitFieldNames ? '' : 'description')
    ..aOB(5, _omitFieldNames ? '' : 'isPrivate')
    ..aI(6, _omitFieldNames ? '' : 'memberCount')
    ..aOB(7, _omitFieldNames ? '' : 'pinnedByViewer')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListInfo clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListInfo copyWith(void Function(ListInfo) updates) =>
      super.copyWith((message) => updates(message as ListInfo)) as ListInfo;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use ListInfo() / ListInfo.new instead')
  static ListInfo create() => ListInfo._();
  static $pb.GeneratedMessage $_createMessage() => ListInfo._();
  @$core.override
  ListInfo createEmptyInstance() => ListInfo._();
  @$core.pragma('dart2js:noInline')
  static ListInfo getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListInfo>(ListInfo.$_createMessage);
  static ListInfo? _defaultInstance;

  /// 19-digit Snowflake.
  @$pb.TagNumber(1)
  $core.String get listId => $_getSZ(0);
  @$pb.TagNumber(1)
  set listId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasListId() => $_has(0);
  @$pb.TagNumber(1)
  void clearListId() => $_clearField(1);

  /// Live row from identity.Directory (up to 60 s stale). is_private is set as on other live rows.
  @$pb.TagNumber(2)
  $0.AuthorSnapshot get owner => $_getN(1);
  @$pb.TagNumber(2)
  set owner($0.AuthorSnapshot value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasOwner() => $_has(1);
  @$pb.TagNumber(2)
  void clearOwner() => $_clearField(2);
  @$pb.TagNumber(2)
  $0.AuthorSnapshot ensureOwner() => $_ensure(1);

  @$pb.TagNumber(3)
  $core.String get name => $_getSZ(2);
  @$pb.TagNumber(3)
  set name($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasName() => $_has(2);
  @$pb.TagNumber(3)
  void clearName() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.String get description => $_getSZ(3);
  @$pb.TagNumber(4)
  set description($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasDescription() => $_has(3);
  @$pb.TagNumber(4)
  void clearDescription() => $_clearField(4);

  /// True for a private list (the default at creation, F3). Only the owner ever receives a private list.
  @$pb.TagNumber(5)
  $core.bool get isPrivate => $_getBF(4);
  @$pb.TagNumber(5)
  set isPrivate($core.bool value) => $_setBool(4, value);
  @$pb.TagNumber(5)
  $core.bool hasIsPrivate() => $_has(4);
  @$pb.TagNumber(5)
  void clearIsPrivate() => $_clearField(5);

  /// The stored member count (memberIds length), including members a given viewer does not see.
  @$pb.TagNumber(6)
  $core.int get memberCount => $_getIZ(5);
  @$pb.TagNumber(6)
  set memberCount($core.int value) => $_setSignedInt32(5, value);
  @$pb.TagNumber(6)
  $core.bool hasMemberCount() => $_has(5);
  @$pb.TagNumber(6)
  void clearMemberCount() => $_clearField(6);

  /// True when the caller has this list pinned as a Home tab (IdentityService.GetMe home_tabs).
  @$pb.TagNumber(7)
  $core.bool get pinnedByViewer => $_getBF(6);
  @$pb.TagNumber(7)
  set pinnedByViewer($core.bool value) => $_setBool(6, value);
  @$pb.TagNumber(7)
  $core.bool hasPinnedByViewer() => $_has(6);
  @$pb.TagNumber(7)
  void clearPinnedByViewer() => $_clearField(7);
}

class CreateListRequest extends $pb.GeneratedMessage {
  factory CreateListRequest({
    $core.String? idempotencyKey,
    $core.String? name,
    $core.String? description,
    $core.bool? isPrivate,
  }) {
    final result = CreateListRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (name != null) result.name = name;
    if (description != null) result.description = description;
    if (isPrivate != null) result.isPrivate = isPrivate;
    return result;
  }

  CreateListRequest._();

  factory CreateListRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CreateListRequest()..mergeFromBuffer(data, registry);
  factory CreateListRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CreateListRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CreateListRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.lists.v1'),
      createEmptyInstance: CreateListRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'name')
    ..aOS(3, _omitFieldNames ? '' : 'description')
    ..aOB(4, _omitFieldNames ? '' : 'isPrivate')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateListRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateListRequest copyWith(void Function(CreateListRequest) updates) =>
      super.copyWith((message) => updates(message as CreateListRequest))
          as CreateListRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use CreateListRequest() / CreateListRequest.new instead')
  static CreateListRequest create() => CreateListRequest._();
  static $pb.GeneratedMessage $_createMessage() => CreateListRequest._();
  @$core.override
  CreateListRequest createEmptyInstance() => CreateListRequest._();
  @$core.pragma('dart2js:noInline')
  static CreateListRequest getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<CreateListRequest>(
          CreateListRequest.$_createMessage);
  static CreateListRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  /// 1-25 code points after NFC and trim.
  @$pb.TagNumber(2)
  $core.String get name => $_getSZ(1);
  @$pb.TagNumber(2)
  set name($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasName() => $_has(1);
  @$pb.TagNumber(2)
  void clearName() => $_clearField(2);

  /// 0-100 code points after NFC and trim.
  @$pb.TagNumber(3)
  $core.String get description => $_getSZ(2);
  @$pb.TagNumber(3)
  set description($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasDescription() => $_has(2);
  @$pb.TagNumber(3)
  void clearDescription() => $_clearField(3);

  /// Absent => true: the list is private (F3). Send false to create a public list.
  @$pb.TagNumber(4)
  $core.bool get isPrivate => $_getBF(3);
  @$pb.TagNumber(4)
  set isPrivate($core.bool value) => $_setBool(3, value);
  @$pb.TagNumber(4)
  $core.bool hasIsPrivate() => $_has(3);
  @$pb.TagNumber(4)
  void clearIsPrivate() => $_clearField(4);
}

class CreateListResponse extends $pb.GeneratedMessage {
  factory CreateListResponse({
    ListInfo? list,
  }) {
    final result = CreateListResponse._();
    if (list != null) result.list = list;
    return result;
  }

  CreateListResponse._();

  factory CreateListResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CreateListResponse()..mergeFromBuffer(data, registry);
  factory CreateListResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CreateListResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CreateListResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.lists.v1'),
      createEmptyInstance: CreateListResponse.$_createMessage)
    ..aOM<ListInfo>(1, _omitFieldNames ? '' : 'list',
        subBuilder: ListInfo.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateListResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateListResponse copyWith(void Function(CreateListResponse) updates) =>
      super.copyWith((message) => updates(message as CreateListResponse))
          as CreateListResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use CreateListResponse() / CreateListResponse.new instead')
  static CreateListResponse create() => CreateListResponse._();
  static $pb.GeneratedMessage $_createMessage() => CreateListResponse._();
  @$core.override
  CreateListResponse createEmptyInstance() => CreateListResponse._();
  @$core.pragma('dart2js:noInline')
  static CreateListResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<CreateListResponse>(
          CreateListResponse.$_createMessage);
  static CreateListResponse? _defaultInstance;

  @$pb.TagNumber(1)
  ListInfo get list => $_getN(0);
  @$pb.TagNumber(1)
  set list(ListInfo value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasList() => $_has(0);
  @$pb.TagNumber(1)
  void clearList() => $_clearField(1);
  @$pb.TagNumber(1)
  ListInfo ensureList() => $_ensure(0);
}

class UpdateListRequest extends $pb.GeneratedMessage {
  factory UpdateListRequest({
    $core.String? idempotencyKey,
    $core.String? listId,
    $core.String? name,
    $core.String? description,
    $core.bool? isPrivate,
  }) {
    final result = UpdateListRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (listId != null) result.listId = listId;
    if (name != null) result.name = name;
    if (description != null) result.description = description;
    if (isPrivate != null) result.isPrivate = isPrivate;
    return result;
  }

  UpdateListRequest._();

  factory UpdateListRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UpdateListRequest()..mergeFromBuffer(data, registry);
  factory UpdateListRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UpdateListRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'UpdateListRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.lists.v1'),
      createEmptyInstance: UpdateListRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'listId')
    ..aOS(3, _omitFieldNames ? '' : 'name')
    ..aOS(4, _omitFieldNames ? '' : 'description')
    ..aOB(5, _omitFieldNames ? '' : 'isPrivate')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UpdateListRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UpdateListRequest copyWith(void Function(UpdateListRequest) updates) =>
      super.copyWith((message) => updates(message as UpdateListRequest))
          as UpdateListRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use UpdateListRequest() / UpdateListRequest.new instead')
  static UpdateListRequest create() => UpdateListRequest._();
  static $pb.GeneratedMessage $_createMessage() => UpdateListRequest._();
  @$core.override
  UpdateListRequest createEmptyInstance() => UpdateListRequest._();
  @$core.pragma('dart2js:noInline')
  static UpdateListRequest getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<UpdateListRequest>(
          UpdateListRequest.$_createMessage);
  static UpdateListRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get listId => $_getSZ(1);
  @$pb.TagNumber(2)
  set listId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasListId() => $_has(1);
  @$pb.TagNumber(2)
  void clearListId() => $_clearField(2);

  /// Only the fields that are set change. name cannot be cleared ("" => VALIDATION "name").
  @$pb.TagNumber(3)
  $core.String get name => $_getSZ(2);
  @$pb.TagNumber(3)
  set name($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasName() => $_has(2);
  @$pb.TagNumber(3)
  void clearName() => $_clearField(3);

  /// "" clears the description.
  @$pb.TagNumber(4)
  $core.String get description => $_getSZ(3);
  @$pb.TagNumber(4)
  set description($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasDescription() => $_has(3);
  @$pb.TagNumber(4)
  void clearDescription() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.bool get isPrivate => $_getBF(4);
  @$pb.TagNumber(5)
  set isPrivate($core.bool value) => $_setBool(4, value);
  @$pb.TagNumber(5)
  $core.bool hasIsPrivate() => $_has(4);
  @$pb.TagNumber(5)
  void clearIsPrivate() => $_clearField(5);
}

class UpdateListResponse extends $pb.GeneratedMessage {
  factory UpdateListResponse({
    ListInfo? list,
  }) {
    final result = UpdateListResponse._();
    if (list != null) result.list = list;
    return result;
  }

  UpdateListResponse._();

  factory UpdateListResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UpdateListResponse()..mergeFromBuffer(data, registry);
  factory UpdateListResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UpdateListResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'UpdateListResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.lists.v1'),
      createEmptyInstance: UpdateListResponse.$_createMessage)
    ..aOM<ListInfo>(1, _omitFieldNames ? '' : 'list',
        subBuilder: ListInfo.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UpdateListResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UpdateListResponse copyWith(void Function(UpdateListResponse) updates) =>
      super.copyWith((message) => updates(message as UpdateListResponse))
          as UpdateListResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use UpdateListResponse() / UpdateListResponse.new instead')
  static UpdateListResponse create() => UpdateListResponse._();
  static $pb.GeneratedMessage $_createMessage() => UpdateListResponse._();
  @$core.override
  UpdateListResponse createEmptyInstance() => UpdateListResponse._();
  @$core.pragma('dart2js:noInline')
  static UpdateListResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<UpdateListResponse>(
          UpdateListResponse.$_createMessage);
  static UpdateListResponse? _defaultInstance;

  @$pb.TagNumber(1)
  ListInfo get list => $_getN(0);
  @$pb.TagNumber(1)
  set list(ListInfo value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasList() => $_has(0);
  @$pb.TagNumber(1)
  void clearList() => $_clearField(1);
  @$pb.TagNumber(1)
  ListInfo ensureList() => $_ensure(0);
}

class DeleteListRequest extends $pb.GeneratedMessage {
  factory DeleteListRequest({
    $core.String? idempotencyKey,
    $core.String? listId,
  }) {
    final result = DeleteListRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (listId != null) result.listId = listId;
    return result;
  }

  DeleteListRequest._();

  factory DeleteListRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      DeleteListRequest()..mergeFromBuffer(data, registry);
  factory DeleteListRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      DeleteListRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'DeleteListRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.lists.v1'),
      createEmptyInstance: DeleteListRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'listId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DeleteListRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DeleteListRequest copyWith(void Function(DeleteListRequest) updates) =>
      super.copyWith((message) => updates(message as DeleteListRequest))
          as DeleteListRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use DeleteListRequest() / DeleteListRequest.new instead')
  static DeleteListRequest create() => DeleteListRequest._();
  static $pb.GeneratedMessage $_createMessage() => DeleteListRequest._();
  @$core.override
  DeleteListRequest createEmptyInstance() => DeleteListRequest._();
  @$core.pragma('dart2js:noInline')
  static DeleteListRequest getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<DeleteListRequest>(
          DeleteListRequest.$_createMessage);
  static DeleteListRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get listId => $_getSZ(1);
  @$pb.TagNumber(2)
  set listId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasListId() => $_has(1);
  @$pb.TagNumber(2)
  void clearListId() => $_clearField(2);
}

class DeleteListResponse extends $pb.GeneratedMessage {
  factory DeleteListResponse() => DeleteListResponse._();

  DeleteListResponse._();

  factory DeleteListResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      DeleteListResponse()..mergeFromBuffer(data, registry);
  factory DeleteListResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      DeleteListResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'DeleteListResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.lists.v1'),
      createEmptyInstance: DeleteListResponse.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DeleteListResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DeleteListResponse copyWith(void Function(DeleteListResponse) updates) =>
      super.copyWith((message) => updates(message as DeleteListResponse))
          as DeleteListResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use DeleteListResponse() / DeleteListResponse.new instead')
  static DeleteListResponse create() => DeleteListResponse._();
  static $pb.GeneratedMessage $_createMessage() => DeleteListResponse._();
  @$core.override
  DeleteListResponse createEmptyInstance() => DeleteListResponse._();
  @$core.pragma('dart2js:noInline')
  static DeleteListResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<DeleteListResponse>(
          DeleteListResponse.$_createMessage);
  static DeleteListResponse? _defaultInstance;
}

class GetListRequest extends $pb.GeneratedMessage {
  factory GetListRequest({
    $core.String? listId,
  }) {
    final result = GetListRequest._();
    if (listId != null) result.listId = listId;
    return result;
  }

  GetListRequest._();

  factory GetListRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetListRequest()..mergeFromBuffer(data, registry);
  factory GetListRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetListRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetListRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.lists.v1'),
      createEmptyInstance: GetListRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'listId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetListRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetListRequest copyWith(void Function(GetListRequest) updates) =>
      super.copyWith((message) => updates(message as GetListRequest))
          as GetListRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use GetListRequest() / GetListRequest.new instead')
  static GetListRequest create() => GetListRequest._();
  static $pb.GeneratedMessage $_createMessage() => GetListRequest._();
  @$core.override
  GetListRequest createEmptyInstance() => GetListRequest._();
  @$core.pragma('dart2js:noInline')
  static GetListRequest getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<GetListRequest>(
          GetListRequest.$_createMessage);
  static GetListRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get listId => $_getSZ(0);
  @$pb.TagNumber(1)
  set listId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasListId() => $_has(0);
  @$pb.TagNumber(1)
  void clearListId() => $_clearField(1);
}

class GetListResponse extends $pb.GeneratedMessage {
  factory GetListResponse({
    ListInfo? list,
  }) {
    final result = GetListResponse._();
    if (list != null) result.list = list;
    return result;
  }

  GetListResponse._();

  factory GetListResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetListResponse()..mergeFromBuffer(data, registry);
  factory GetListResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetListResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetListResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.lists.v1'),
      createEmptyInstance: GetListResponse.$_createMessage)
    ..aOM<ListInfo>(1, _omitFieldNames ? '' : 'list',
        subBuilder: ListInfo.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetListResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetListResponse copyWith(void Function(GetListResponse) updates) =>
      super.copyWith((message) => updates(message as GetListResponse))
          as GetListResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use GetListResponse() / GetListResponse.new instead')
  static GetListResponse create() => GetListResponse._();
  static $pb.GeneratedMessage $_createMessage() => GetListResponse._();
  @$core.override
  GetListResponse createEmptyInstance() => GetListResponse._();
  @$core.pragma('dart2js:noInline')
  static GetListResponse getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<GetListResponse>(
          GetListResponse.$_createMessage);
  static GetListResponse? _defaultInstance;

  @$pb.TagNumber(1)
  ListInfo get list => $_getN(0);
  @$pb.TagNumber(1)
  set list(ListInfo value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasList() => $_has(0);
  @$pb.TagNumber(1)
  void clearList() => $_clearField(1);
  @$pb.TagNumber(1)
  ListInfo ensureList() => $_ensure(0);
}

class ListUserListsRequest extends $pb.GeneratedMessage {
  factory ListUserListsRequest({
    $core.String? ownerId,
    $core.String? containsUserId,
    $core.int? pageSize,
    $core.String? pageToken,
  }) {
    final result = ListUserListsRequest._();
    if (ownerId != null) result.ownerId = ownerId;
    if (containsUserId != null) result.containsUserId = containsUserId;
    if (pageSize != null) result.pageSize = pageSize;
    if (pageToken != null) result.pageToken = pageToken;
    return result;
  }

  ListUserListsRequest._();

  factory ListUserListsRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListUserListsRequest()..mergeFromBuffer(data, registry);
  factory ListUserListsRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListUserListsRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListUserListsRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.lists.v1'),
      createEmptyInstance: ListUserListsRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'ownerId')
    ..aOS(2, _omitFieldNames ? '' : 'containsUserId')
    ..aI(3, _omitFieldNames ? '' : 'pageSize')
    ..aOS(4, _omitFieldNames ? '' : 'pageToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListUserListsRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListUserListsRequest copyWith(void Function(ListUserListsRequest) updates) =>
      super.copyWith((message) => updates(message as ListUserListsRequest))
          as ListUserListsRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ListUserListsRequest() / ListUserListsRequest.new instead')
  static ListUserListsRequest create() => ListUserListsRequest._();
  static $pb.GeneratedMessage $_createMessage() => ListUserListsRequest._();
  @$core.override
  ListUserListsRequest createEmptyInstance() => ListUserListsRequest._();
  @$core.pragma('dart2js:noInline')
  static ListUserListsRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListUserListsRequest>(
          ListUserListsRequest.$_createMessage);
  static ListUserListsRequest? _defaultInstance;

  /// "" => the caller.
  @$pb.TagNumber(1)
  $core.String get ownerId => $_getSZ(0);
  @$pb.TagNumber(1)
  set ownerId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasOwnerId() => $_has(0);
  @$pb.TagNumber(1)
  void clearOwnerId() => $_clearField(1);

  /// Optional; only with the caller's own lists (see ListUserLists).
  @$pb.TagNumber(2)
  $core.String get containsUserId => $_getSZ(1);
  @$pb.TagNumber(2)
  set containsUserId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasContainsUserId() => $_has(1);
  @$pb.TagNumber(2)
  void clearContainsUserId() => $_clearField(2);

  /// 0 => 20; max 50 (clamped).
  @$pb.TagNumber(3)
  $core.int get pageSize => $_getIZ(2);
  @$pb.TagNumber(3)
  set pageSize($core.int value) => $_setSignedInt32(2, value);
  @$pb.TagNumber(3)
  $core.bool hasPageSize() => $_has(2);
  @$pb.TagNumber(3)
  void clearPageSize() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.String get pageToken => $_getSZ(3);
  @$pb.TagNumber(4)
  set pageToken($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasPageToken() => $_has(3);
  @$pb.TagNumber(4)
  void clearPageToken() => $_clearField(4);
}

class ListUserListsResponse extends $pb.GeneratedMessage {
  factory ListUserListsResponse({
    $core.Iterable<ListInfo>? lists,
    $core.Iterable<$core.String>? containingListIds,
    $core.String? nextPageToken,
  }) {
    final result = ListUserListsResponse._();
    if (lists != null) result.lists.addAll(lists);
    if (containingListIds != null)
      result.containingListIds.addAll(containingListIds);
    if (nextPageToken != null) result.nextPageToken = nextPageToken;
    return result;
  }

  ListUserListsResponse._();

  factory ListUserListsResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListUserListsResponse()..mergeFromBuffer(data, registry);
  factory ListUserListsResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListUserListsResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListUserListsResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.lists.v1'),
      createEmptyInstance: ListUserListsResponse.$_createMessage)
    ..pPM<ListInfo>(1, _omitFieldNames ? '' : 'lists',
        subBuilder: ListInfo.$_createMessage)
    ..pPS(2, _omitFieldNames ? '' : 'containingListIds')
    ..aOS(3, _omitFieldNames ? '' : 'nextPageToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListUserListsResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListUserListsResponse copyWith(
          void Function(ListUserListsResponse) updates) =>
      super.copyWith((message) => updates(message as ListUserListsResponse))
          as ListUserListsResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ListUserListsResponse() / ListUserListsResponse.new instead')
  static ListUserListsResponse create() => ListUserListsResponse._();
  static $pb.GeneratedMessage $_createMessage() => ListUserListsResponse._();
  @$core.override
  ListUserListsResponse createEmptyInstance() => ListUserListsResponse._();
  @$core.pragma('dart2js:noInline')
  static ListUserListsResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListUserListsResponse>(
          ListUserListsResponse.$_createMessage);
  static ListUserListsResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<ListInfo> get lists => $_getList(0);

  /// Ids of the returned lists whose members include contains_user_id. Empty when contains_user_id is "".
  @$pb.TagNumber(2)
  $pb.PbList<$core.String> get containingListIds => $_getList(1);

  /// "" => no more (always "" while LISTS_MAX_PER_USER <= 20).
  @$pb.TagNumber(3)
  $core.String get nextPageToken => $_getSZ(2);
  @$pb.TagNumber(3)
  set nextPageToken($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasNextPageToken() => $_has(2);
  @$pb.TagNumber(3)
  void clearNextPageToken() => $_clearField(3);
}

class AddListMemberRequest extends $pb.GeneratedMessage {
  factory AddListMemberRequest({
    $core.String? idempotencyKey,
    $core.String? listId,
    $core.String? userId,
  }) {
    final result = AddListMemberRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (listId != null) result.listId = listId;
    if (userId != null) result.userId = userId;
    return result;
  }

  AddListMemberRequest._();

  factory AddListMemberRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      AddListMemberRequest()..mergeFromBuffer(data, registry);
  factory AddListMemberRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      AddListMemberRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'AddListMemberRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.lists.v1'),
      createEmptyInstance: AddListMemberRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'listId')
    ..aOS(3, _omitFieldNames ? '' : 'userId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AddListMemberRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AddListMemberRequest copyWith(void Function(AddListMemberRequest) updates) =>
      super.copyWith((message) => updates(message as AddListMemberRequest))
          as AddListMemberRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use AddListMemberRequest() / AddListMemberRequest.new instead')
  static AddListMemberRequest create() => AddListMemberRequest._();
  static $pb.GeneratedMessage $_createMessage() => AddListMemberRequest._();
  @$core.override
  AddListMemberRequest createEmptyInstance() => AddListMemberRequest._();
  @$core.pragma('dart2js:noInline')
  static AddListMemberRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<AddListMemberRequest>(
          AddListMemberRequest.$_createMessage);
  static AddListMemberRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get listId => $_getSZ(1);
  @$pb.TagNumber(2)
  set listId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasListId() => $_has(1);
  @$pb.TagNumber(2)
  void clearListId() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get userId => $_getSZ(2);
  @$pb.TagNumber(3)
  set userId($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasUserId() => $_has(2);
  @$pb.TagNumber(3)
  void clearUserId() => $_clearField(3);
}

class AddListMemberResponse extends $pb.GeneratedMessage {
  factory AddListMemberResponse({
    ListInfo? list,
  }) {
    final result = AddListMemberResponse._();
    if (list != null) result.list = list;
    return result;
  }

  AddListMemberResponse._();

  factory AddListMemberResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      AddListMemberResponse()..mergeFromBuffer(data, registry);
  factory AddListMemberResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      AddListMemberResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'AddListMemberResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.lists.v1'),
      createEmptyInstance: AddListMemberResponse.$_createMessage)
    ..aOM<ListInfo>(1, _omitFieldNames ? '' : 'list',
        subBuilder: ListInfo.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AddListMemberResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AddListMemberResponse copyWith(
          void Function(AddListMemberResponse) updates) =>
      super.copyWith((message) => updates(message as AddListMemberResponse))
          as AddListMemberResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use AddListMemberResponse() / AddListMemberResponse.new instead')
  static AddListMemberResponse create() => AddListMemberResponse._();
  static $pb.GeneratedMessage $_createMessage() => AddListMemberResponse._();
  @$core.override
  AddListMemberResponse createEmptyInstance() => AddListMemberResponse._();
  @$core.pragma('dart2js:noInline')
  static AddListMemberResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<AddListMemberResponse>(
          AddListMemberResponse.$_createMessage);
  static AddListMemberResponse? _defaultInstance;

  @$pb.TagNumber(1)
  ListInfo get list => $_getN(0);
  @$pb.TagNumber(1)
  set list(ListInfo value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasList() => $_has(0);
  @$pb.TagNumber(1)
  void clearList() => $_clearField(1);
  @$pb.TagNumber(1)
  ListInfo ensureList() => $_ensure(0);
}

class RemoveListMemberRequest extends $pb.GeneratedMessage {
  factory RemoveListMemberRequest({
    $core.String? idempotencyKey,
    $core.String? listId,
    $core.String? userId,
  }) {
    final result = RemoveListMemberRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (listId != null) result.listId = listId;
    if (userId != null) result.userId = userId;
    return result;
  }

  RemoveListMemberRequest._();

  factory RemoveListMemberRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RemoveListMemberRequest()..mergeFromBuffer(data, registry);
  factory RemoveListMemberRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RemoveListMemberRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RemoveListMemberRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.lists.v1'),
      createEmptyInstance: RemoveListMemberRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'listId')
    ..aOS(3, _omitFieldNames ? '' : 'userId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RemoveListMemberRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RemoveListMemberRequest copyWith(
          void Function(RemoveListMemberRequest) updates) =>
      super.copyWith((message) => updates(message as RemoveListMemberRequest))
          as RemoveListMemberRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use RemoveListMemberRequest() / RemoveListMemberRequest.new instead')
  static RemoveListMemberRequest create() => RemoveListMemberRequest._();
  static $pb.GeneratedMessage $_createMessage() => RemoveListMemberRequest._();
  @$core.override
  RemoveListMemberRequest createEmptyInstance() => RemoveListMemberRequest._();
  @$core.pragma('dart2js:noInline')
  static RemoveListMemberRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<RemoveListMemberRequest>(
          RemoveListMemberRequest.$_createMessage);
  static RemoveListMemberRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get listId => $_getSZ(1);
  @$pb.TagNumber(2)
  set listId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasListId() => $_has(1);
  @$pb.TagNumber(2)
  void clearListId() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get userId => $_getSZ(2);
  @$pb.TagNumber(3)
  set userId($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasUserId() => $_has(2);
  @$pb.TagNumber(3)
  void clearUserId() => $_clearField(3);
}

class RemoveListMemberResponse extends $pb.GeneratedMessage {
  factory RemoveListMemberResponse({
    ListInfo? list,
  }) {
    final result = RemoveListMemberResponse._();
    if (list != null) result.list = list;
    return result;
  }

  RemoveListMemberResponse._();

  factory RemoveListMemberResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RemoveListMemberResponse()..mergeFromBuffer(data, registry);
  factory RemoveListMemberResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RemoveListMemberResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RemoveListMemberResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.lists.v1'),
      createEmptyInstance: RemoveListMemberResponse.$_createMessage)
    ..aOM<ListInfo>(1, _omitFieldNames ? '' : 'list',
        subBuilder: ListInfo.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RemoveListMemberResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RemoveListMemberResponse copyWith(
          void Function(RemoveListMemberResponse) updates) =>
      super.copyWith((message) => updates(message as RemoveListMemberResponse))
          as RemoveListMemberResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use RemoveListMemberResponse() / RemoveListMemberResponse.new instead')
  static RemoveListMemberResponse create() => RemoveListMemberResponse._();
  static $pb.GeneratedMessage $_createMessage() => RemoveListMemberResponse._();
  @$core.override
  RemoveListMemberResponse createEmptyInstance() =>
      RemoveListMemberResponse._();
  @$core.pragma('dart2js:noInline')
  static RemoveListMemberResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<RemoveListMemberResponse>(
          RemoveListMemberResponse.$_createMessage);
  static RemoveListMemberResponse? _defaultInstance;

  @$pb.TagNumber(1)
  ListInfo get list => $_getN(0);
  @$pb.TagNumber(1)
  set list(ListInfo value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasList() => $_has(0);
  @$pb.TagNumber(1)
  void clearList() => $_clearField(1);
  @$pb.TagNumber(1)
  ListInfo ensureList() => $_ensure(0);
}

class ListListMembersRequest extends $pb.GeneratedMessage {
  factory ListListMembersRequest({
    $core.String? listId,
    $core.int? pageSize,
    $core.String? pageToken,
  }) {
    final result = ListListMembersRequest._();
    if (listId != null) result.listId = listId;
    if (pageSize != null) result.pageSize = pageSize;
    if (pageToken != null) result.pageToken = pageToken;
    return result;
  }

  ListListMembersRequest._();

  factory ListListMembersRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListListMembersRequest()..mergeFromBuffer(data, registry);
  factory ListListMembersRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListListMembersRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListListMembersRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.lists.v1'),
      createEmptyInstance: ListListMembersRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'listId')
    ..aI(2, _omitFieldNames ? '' : 'pageSize')
    ..aOS(3, _omitFieldNames ? '' : 'pageToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListListMembersRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListListMembersRequest copyWith(
          void Function(ListListMembersRequest) updates) =>
      super.copyWith((message) => updates(message as ListListMembersRequest))
          as ListListMembersRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ListListMembersRequest() / ListListMembersRequest.new instead')
  static ListListMembersRequest create() => ListListMembersRequest._();
  static $pb.GeneratedMessage $_createMessage() => ListListMembersRequest._();
  @$core.override
  ListListMembersRequest createEmptyInstance() => ListListMembersRequest._();
  @$core.pragma('dart2js:noInline')
  static ListListMembersRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListListMembersRequest>(
          ListListMembersRequest.$_createMessage);
  static ListListMembersRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get listId => $_getSZ(0);
  @$pb.TagNumber(1)
  set listId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasListId() => $_has(0);
  @$pb.TagNumber(1)
  void clearListId() => $_clearField(1);

  /// 0 => 20; max 50 (clamped).
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

class ListListMembersResponse extends $pb.GeneratedMessage {
  factory ListListMembersResponse({
    $core.Iterable<$1.UserListItem>? users,
    $core.String? nextPageToken,
  }) {
    final result = ListListMembersResponse._();
    if (users != null) result.users.addAll(users);
    if (nextPageToken != null) result.nextPageToken = nextPageToken;
    return result;
  }

  ListListMembersResponse._();

  factory ListListMembersResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListListMembersResponse()..mergeFromBuffer(data, registry);
  factory ListListMembersResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListListMembersResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListListMembersResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.lists.v1'),
      createEmptyInstance: ListListMembersResponse.$_createMessage)
    ..pPM<$1.UserListItem>(1, _omitFieldNames ? '' : 'users',
        subBuilder: $1.UserListItem.$_createMessage)
    ..aOS(2, _omitFieldNames ? '' : 'nextPageToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListListMembersResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListListMembersResponse copyWith(
          void Function(ListListMembersResponse) updates) =>
      super.copyWith((message) => updates(message as ListListMembersResponse))
          as ListListMembersResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ListListMembersResponse() / ListListMembersResponse.new instead')
  static ListListMembersResponse create() => ListListMembersResponse._();
  static $pb.GeneratedMessage $_createMessage() => ListListMembersResponse._();
  @$core.override
  ListListMembersResponse createEmptyInstance() => ListListMembersResponse._();
  @$core.pragma('dart2js:noInline')
  static ListListMembersResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListListMembersResponse>(
          ListListMembersResponse.$_createMessage);
  static ListListMembersResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<$1.UserListItem> get users => $_getList(0);

  /// "" => no more.
  @$pb.TagNumber(2)
  $core.String get nextPageToken => $_getSZ(1);
  @$pb.TagNumber(2)
  set nextPageToken($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasNextPageToken() => $_has(1);
  @$pb.TagNumber(2)
  void clearNextPageToken() => $_clearField(2);
}

class ListServiceApi {
  final $pb.RpcClient _client;

  ListServiceApi(this._client);

  /// Create a list owned by the caller. The new list is private unless is_private is sent as false (F3).
  /// name: 1-25 code points after NFC and trim; description: 0-100 code points; both single line, no control or bidi
  /// formatting characters (the bio rules, ADR-0010 D9); else VALIDATION "name" / "description", 0 reads.
  /// One transaction: idempotency doc, quotas/{uid} (list_creates), a count() of the caller's lists (ownerId == caller,
  /// 1 read per 1,000 matches, so the cap is exact), then Create lists/{id} with a fresh Snowflake id.
  /// At LISTS_MAX_PER_USER (20) => LIMIT_REACHED "lists"; over the daily quota => QUOTA_EXCEEDED "list_creates".
  /// Firestore: reads 4 cold (interceptor, idempotency, quotas, count()) / 3 warm; writes 3 (list, idempotency,
  /// quotas) + 1 TTL delete of the idempotency doc 24 h later; replay reads 2 / 1, writes 0; at the cap or quota 0
  /// writes.
  $async.Future<CreateListResponse> createList(
          $pb.ClientContext? ctx, CreateListRequest request) =>
      _client.invoke<CreateListResponse>(
          ctx, 'ListService', 'CreateList', request, CreateListResponse());

  /// Change a list's name, description or visibility. Owner only: any other caller, a missing list or a deleted one
  /// => NOT_FOUND. Only the fields that are set change; the field rules are CreateList's. Making a list private stops
  /// it serving non-owners at once on this instance and within 60 s on the others (the list instance cache).
  /// One transaction: idempotency doc, the list (fresh). A request that changes nothing writes only the idempotency doc.
  /// A rename of a list the caller has pinned also refreshes that tab's title (users/{uid}.homeTabs, through identity).
  /// Firestore: reads 3 cold / 2 warm (interceptor, idempotency, list), +1 when a pinned list is renamed; writes 2
  /// (list, idempotency), 1 when nothing changes, +1 when a pinned list is renamed, + 1 TTL delete later; replay reads
  /// 2, writes 0.
  $async.Future<UpdateListResponse> updateList(
          $pb.ClientContext? ctx, UpdateListRequest request) =>
      _client.invoke<UpdateListResponse>(
          ctx, 'ListService', 'UpdateList', request, UpdateListResponse());

  /// Delete one of the caller's lists. Owner only; any other caller or a missing list => success with no effect
  /// (NOT_FOUND is not returned, so a retry after a lost response succeeds). Other users who pinned the list keep a
  /// dangling Home tab: GetListTimeline answers NOT_FOUND and the client offers Unpin. The caller's own pin of the list
  /// is removed in the same call (a field-level update of users/{uid}.homeTabs through identity, only when pinned).
  /// Firestore: reads 3 cold (interceptor, idempotency, list) + 1 when the caller pinned it (users/{uid} fresh);
  /// writes 1 (idempotency) + 1 when pinned; deletes 1 (the list, Exists precondition) + 1 TTL later; replay reads 2,
  /// writes 0.
  $async.Future<DeleteListResponse> deleteList(
          $pb.ClientContext? ctx, DeleteListRequest request) =>
      _client.invoke<DeleteListResponse>(
          ctx, 'ListService', 'DeleteList', request, DeleteListResponse());

  /// One list's header. NOT_FOUND for every cause in the header comment. pinned_by_viewer comes from the caller's own
  /// users/{uid}.homeTabs, already read by the account-status interceptor (0 reads).
  /// Cached: the list doc 60 s per instance (CACHE_LISTS_ENTRIES), the owner's profile through identity.Directory, the
  /// owner's graph snapshot 60 s (read for a non-owner caller only: blockedBy overflow, F4).
  /// Firestore: reads 5 cold for a non-owner (interceptor, list, caller graph, owner profile, owner graph), 2 for the
  /// owner (interceptor, list) / 0-1 warm; writes 0.
  $async.Future<GetListResponse> getList(
          $pb.ClientContext? ctx, GetListRequest request) =>
      _client.invoke<GetListResponse>(
          ctx, 'ListService', 'GetList', request, GetListResponse());

  /// An owner's lists, in creation order (oldest first). owner_id "" means the caller.
  /// The caller's own lists: all of them, private ones included. Another owner's: public, not hidden lists only; an
  /// owner who is missing, not ACTIVE or blocks the caller => NOT_FOUND (byte-identical to GetProfile's missing-user
  /// error), and an owner whose blockedBy overflowed returns no lists.
  /// contains_user_id (the "Add to Lists" sheet) is accepted only with the caller's own lists (owner_id "" or the
  /// caller), else VALIDATION "contains_user_id", 0 reads beyond the interceptor: on another owner's lists it would be
  /// a membership oracle. containing_list_ids lists the returned lists whose members include that user (0 reads: the
  /// member ids are in the list docs already read).
  /// Paging: the caller's own lists page by page_size (0 => 20, max 50, clamped) with an opaque sealed next_page_token.
  /// Another owner's lists are never paged: every public list comes back in one response and next_page_token is "",
  /// whatever page_size is (a token or a short page would reveal the owner's private lists, ADR-0030 D3). The owner has at
  /// most LISTS_MAX_PER_USER (20) lists.
  /// Query: lists where ownerId == owner, Limit(page_size + 1) for the caller, Limit(LISTS_MAX_PER_USER) for another owner,
  /// the automatic single-field index (no composite index).
  /// Cached: the owner's list set 60 s per instance; a write by the owner updates this instance's copy.
  /// Firestore: another owner, reads 24 cold at 20 lists (interceptor, caller graph, owner profile, owner graph,
  /// <= 20 list docs), 5 when they have none (an empty query bills 1); the caller's own lists 21 cold (interceptor,
  /// <= 20 list docs) / 0-2 warm; writes 0.
  $async.Future<ListUserListsResponse> listUserLists(
          $pb.ClientContext? ctx, ListUserListsRequest request) =>
      _client.invoke<ListUserListsResponse>(ctx, 'ListService', 'ListUserLists',
          request, ListUserListsResponse());

  /// Add an account to one of the caller's lists. Owner only, else NOT_FOUND. user_id: [A-Za-z0-9-]{1,128}; self is
  /// allowed (your own posts in your own list). The target must be ACTIVE (identity.Directory, cached) and pass the
  /// member rules in the header comment (block either way => NOT_FOUND; a protected target the caller does not follow
  /// => PROTECTED_ACCOUNT); the caller's blockedBy overflow adds one read of the target's graph (fail closed).
  /// One transaction: idempotency doc, the list (fresh), quotas/{uid} (list_adds), then ArrayUnion into memberIds and
  /// updatedAt. The same write removes members who block the caller (F4 lazy drop, from the caller's graph snapshot).
  /// At LIST_MAX_MEMBERS (150) => LIMIT_REACHED "list_members"; over the quota => QUOTA_EXCEEDED "list_adds".
  /// Already a member => success, the idempotency doc only (1 write), no quota spent.
  /// Firestore: reads 6 cold (interceptor, caller graph, target profile, idempotency, list, quotas; +1 target graph on
  /// blockedBy overflow) / 3 warm; writes 3 (list, quotas, idempotency) + 1 TTL delete later; already a member 1 write;
  /// replay reads <= 4, writes 0; refused 0 writes.
  $async.Future<AddListMemberResponse> addListMember(
          $pb.ClientContext? ctx, AddListMemberRequest request) =>
      _client.invoke<AddListMemberResponse>(ctx, 'ListService', 'AddListMember',
          request, AddListMemberResponse());

  /// Remove an account from one of the caller's lists. Owner only, else NOT_FOUND. Not a member => success, the
  /// idempotency doc only. No quota. The same write removes members who block the caller (F4).
  /// Firestore: reads 3 cold / 2 warm (interceptor, idempotency, list); writes 2 (list, idempotency), 1 when not a
  /// member, + 1 TTL delete later; replay reads 2, writes 0.
  $async.Future<RemoveListMemberResponse> removeListMember(
          $pb.ClientContext? ctx, RemoveListMemberRequest request) =>
      _client.invoke<RemoveListMemberResponse>(ctx, 'ListService',
          'RemoveListMember', request, RemoveListMemberResponse());

  /// A list's members, most recently added first, as user rows with the caller's relationship to each (0 extra reads,
  /// from the caller's graph). NOT_FOUND for every cause in the header comment. Members who are not ACTIVE and the
  /// member drops in the header comment are left out, so a page may be short while next_page_token is set: keep
  /// following it. UserListItem.since is unset (memberIds carries no timestamps); user.is_private is set (live row).
  /// Paging: page_size 0 => 20, max 50 (clamped); page_token is sealed, bound to the caller and the list, and expires
  /// after 24 h (expired, foreign or tampered => VALIDATION "page_token", 0 reads).
  /// Firestore: reads 25 cold at page 20 / 55 at page 50 (interceptor, list, caller graph, and for a non-owner caller
  /// the owner's graph; identity.Directory GetMany of the page plus the owner's profile) / 2 + profile cache misses
  /// warm; writes 0.
  $async.Future<ListListMembersResponse> listListMembers(
          $pb.ClientContext? ctx, ListListMembersRequest request) =>
      _client.invoke<ListListMembersResponse>(ctx, 'ListService',
          'ListListMembers', request, ListListMembersResponse());
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
