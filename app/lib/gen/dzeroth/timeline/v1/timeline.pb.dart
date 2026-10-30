// This is a generated file - do not edit.
//
// Generated from dzeroth/timeline/v1/timeline.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:async' as $async;
import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

import '../../common/v1/common.pb.dart' as $2;
import '../../lists/v1/lists.pb.dart' as $1;
import '../../posts/v1/posts.pb.dart' as $0;
import 'timeline.pbenum.dart';

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

export 'timeline.pbenum.dart';

class GetHomeTimelineRequest extends $pb.GeneratedMessage {
  factory GetHomeTimelineRequest({
    $core.int? pageSize,
    $core.String? pageToken,
    $core.String? sinceToken,
  }) {
    final result = GetHomeTimelineRequest._();
    if (pageSize != null) result.pageSize = pageSize;
    if (pageToken != null) result.pageToken = pageToken;
    if (sinceToken != null) result.sinceToken = sinceToken;
    return result;
  }

  GetHomeTimelineRequest._();

  factory GetHomeTimelineRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetHomeTimelineRequest()..mergeFromBuffer(data, registry);
  factory GetHomeTimelineRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetHomeTimelineRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetHomeTimelineRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.timeline.v1'),
      createEmptyInstance: GetHomeTimelineRequest.$_createMessage)
    ..aI(1, _omitFieldNames ? '' : 'pageSize')
    ..aOS(2, _omitFieldNames ? '' : 'pageToken')
    ..aOS(3, _omitFieldNames ? '' : 'sinceToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetHomeTimelineRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetHomeTimelineRequest copyWith(
          void Function(GetHomeTimelineRequest) updates) =>
      super.copyWith((message) => updates(message as GetHomeTimelineRequest))
          as GetHomeTimelineRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use GetHomeTimelineRequest() / GetHomeTimelineRequest.new instead')
  static GetHomeTimelineRequest create() => GetHomeTimelineRequest._();
  static $pb.GeneratedMessage $_createMessage() => GetHomeTimelineRequest._();
  @$core.override
  GetHomeTimelineRequest createEmptyInstance() => GetHomeTimelineRequest._();
  @$core.pragma('dart2js:noInline')
  static GetHomeTimelineRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<GetHomeTimelineRequest>(
          GetHomeTimelineRequest.$_createMessage);
  static GetHomeTimelineRequest? _defaultInstance;

  /// 0 => 20; max 50 (clamped).
  @$pb.TagNumber(1)
  $core.int get pageSize => $_getIZ(0);
  @$pb.TagNumber(1)
  set pageSize($core.int value) => $_setSignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasPageSize() => $_has(0);
  @$pb.TagNumber(1)
  void clearPageSize() => $_clearField(1);

  /// Older page (infinite scroll or gap fill).
  @$pb.TagNumber(2)
  $core.String get pageToken => $_getSZ(1);
  @$pb.TagNumber(2)
  set pageToken($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasPageToken() => $_has(1);
  @$pb.TagNumber(2)
  void clearPageToken() => $_clearField(2);

  /// Newer-than refresh.
  @$pb.TagNumber(3)
  $core.String get sinceToken => $_getSZ(2);
  @$pb.TagNumber(3)
  set sinceToken($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasSinceToken() => $_has(2);
  @$pb.TagNumber(3)
  void clearSinceToken() => $_clearField(3);
}

class GetHomeTimelineResponse extends $pb.GeneratedMessage {
  factory GetHomeTimelineResponse({
    $core.Iterable<$0.PostView>? posts,
    $core.String? nextPageToken,
    $core.String? sinceToken,
    $core.String? gapPageToken,
    $core.Iterable<$core.String>? removedIds,
  }) {
    final result = GetHomeTimelineResponse._();
    if (posts != null) result.posts.addAll(posts);
    if (nextPageToken != null) result.nextPageToken = nextPageToken;
    if (sinceToken != null) result.sinceToken = sinceToken;
    if (gapPageToken != null) result.gapPageToken = gapPageToken;
    if (removedIds != null) result.removedIds.addAll(removedIds);
    return result;
  }

  GetHomeTimelineResponse._();

  factory GetHomeTimelineResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetHomeTimelineResponse()..mergeFromBuffer(data, registry);
  factory GetHomeTimelineResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetHomeTimelineResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetHomeTimelineResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.timeline.v1'),
      createEmptyInstance: GetHomeTimelineResponse.$_createMessage)
    ..pPM<$0.PostView>(1, _omitFieldNames ? '' : 'posts',
        subBuilder: $0.PostView.$_createMessage)
    ..aOS(2, _omitFieldNames ? '' : 'nextPageToken')
    ..aOS(3, _omitFieldNames ? '' : 'sinceToken')
    ..aOS(4, _omitFieldNames ? '' : 'gapPageToken')
    ..pPS(5, _omitFieldNames ? '' : 'removedIds')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetHomeTimelineResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetHomeTimelineResponse copyWith(
          void Function(GetHomeTimelineResponse) updates) =>
      super.copyWith((message) => updates(message as GetHomeTimelineResponse))
          as GetHomeTimelineResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use GetHomeTimelineResponse() / GetHomeTimelineResponse.new instead')
  static GetHomeTimelineResponse create() => GetHomeTimelineResponse._();
  static $pb.GeneratedMessage $_createMessage() => GetHomeTimelineResponse._();
  @$core.override
  GetHomeTimelineResponse createEmptyInstance() => GetHomeTimelineResponse._();
  @$core.pragma('dart2js:noInline')
  static GetHomeTimelineResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<GetHomeTimelineResponse>(
          GetHomeTimelineResponse.$_createMessage);
  static GetHomeTimelineResponse? _defaultInstance;

  /// Newest first.
  @$pb.TagNumber(1)
  $pb.PbList<$0.PostView> get posts => $_getList(0);

  /// "" => no older posts.
  @$pb.TagNumber(2)
  $core.String get nextPageToken => $_getSZ(1);
  @$pb.TagNumber(2)
  set nextPageToken($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasNextPageToken() => $_has(1);
  @$pb.TagNumber(2)
  void clearNextPageToken() => $_clearField(2);

  /// Persist; send on the next refresh.
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

  /// Refresh only (see the token contract): ids of posts removed by a moderator since the since_token was issued.
  /// At most 50, newest removal first. The client deletes these from its cache. Empty on every other mode.
  @$pb.TagNumber(5)
  $pb.PbList<$core.String> get removedIds => $_getList(4);
}

class GetUserTimelineRequest extends $pb.GeneratedMessage {
  factory GetUserTimelineRequest({
    $core.String? userId,
    $core.bool? includeReplies,
    $core.int? pageSize,
    $core.String? pageToken,
    $core.String? sinceToken,
    UserTimelineTab? tab,
  }) {
    final result = GetUserTimelineRequest._();
    if (userId != null) result.userId = userId;
    if (includeReplies != null) result.includeReplies = includeReplies;
    if (pageSize != null) result.pageSize = pageSize;
    if (pageToken != null) result.pageToken = pageToken;
    if (sinceToken != null) result.sinceToken = sinceToken;
    if (tab != null) result.tab = tab;
    return result;
  }

  GetUserTimelineRequest._();

  factory GetUserTimelineRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetUserTimelineRequest()..mergeFromBuffer(data, registry);
  factory GetUserTimelineRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetUserTimelineRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetUserTimelineRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.timeline.v1'),
      createEmptyInstance: GetUserTimelineRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'userId')
    ..aOB(2, _omitFieldNames ? '' : 'includeReplies')
    ..aI(3, _omitFieldNames ? '' : 'pageSize')
    ..aOS(4, _omitFieldNames ? '' : 'pageToken')
    ..aOS(5, _omitFieldNames ? '' : 'sinceToken')
    ..aE<UserTimelineTab>(6, _omitFieldNames ? '' : 'tab',
        enumValues: UserTimelineTab.values)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetUserTimelineRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetUserTimelineRequest copyWith(
          void Function(GetUserTimelineRequest) updates) =>
      super.copyWith((message) => updates(message as GetUserTimelineRequest))
          as GetUserTimelineRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use GetUserTimelineRequest() / GetUserTimelineRequest.new instead')
  static GetUserTimelineRequest create() => GetUserTimelineRequest._();
  static $pb.GeneratedMessage $_createMessage() => GetUserTimelineRequest._();
  @$core.override
  GetUserTimelineRequest createEmptyInstance() => GetUserTimelineRequest._();
  @$core.pragma('dart2js:noInline')
  static GetUserTimelineRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<GetUserTimelineRequest>(
          GetUserTimelineRequest.$_createMessage);
  static GetUserTimelineRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get userId => $_getSZ(0);
  @$pb.TagNumber(1)
  set userId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasUserId() => $_has(0);
  @$pb.TagNumber(1)
  void clearUserId() => $_clearField(1);

  /// Read only while tab is UNSPECIFIED; ignored (no error) when tab is set.
  @$pb.TagNumber(2)
  $core.bool get includeReplies => $_getBF(1);
  @$pb.TagNumber(2)
  set includeReplies($core.bool value) => $_setBool(1, value);
  @$pb.TagNumber(2)
  $core.bool hasIncludeReplies() => $_has(1);
  @$pb.TagNumber(2)
  void clearIncludeReplies() => $_clearField(2);

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

  @$pb.TagNumber(5)
  $core.String get sinceToken => $_getSZ(4);
  @$pb.TagNumber(5)
  set sinceToken($core.String value) => $_setString(4, value);
  @$pb.TagNumber(5)
  $core.bool hasSinceToken() => $_has(4);
  @$pb.TagNumber(5)
  void clearSinceToken() => $_clearField(5);

  /// UNSPECIFIED => include_replies decides. Any other value wins over include_replies. Tokens are bound to the
  /// effective tab (see the token contract).
  @$pb.TagNumber(6)
  UserTimelineTab get tab => $_getN(5);
  @$pb.TagNumber(6)
  set tab(UserTimelineTab value) => $_setField(6, value);
  @$pb.TagNumber(6)
  $core.bool hasTab() => $_has(5);
  @$pb.TagNumber(6)
  void clearTab() => $_clearField(6);
}

class GetUserTimelineResponse extends $pb.GeneratedMessage {
  factory GetUserTimelineResponse({
    $core.Iterable<$0.PostView>? posts,
    $core.String? nextPageToken,
    $core.String? sinceToken,
    $core.String? gapPageToken,
    $core.Iterable<$core.String>? removedIds,
    $core.bool? authorProtected,
  }) {
    final result = GetUserTimelineResponse._();
    if (posts != null) result.posts.addAll(posts);
    if (nextPageToken != null) result.nextPageToken = nextPageToken;
    if (sinceToken != null) result.sinceToken = sinceToken;
    if (gapPageToken != null) result.gapPageToken = gapPageToken;
    if (removedIds != null) result.removedIds.addAll(removedIds);
    if (authorProtected != null) result.authorProtected = authorProtected;
    return result;
  }

  GetUserTimelineResponse._();

  factory GetUserTimelineResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetUserTimelineResponse()..mergeFromBuffer(data, registry);
  factory GetUserTimelineResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetUserTimelineResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetUserTimelineResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.timeline.v1'),
      createEmptyInstance: GetUserTimelineResponse.$_createMessage)
    ..pPM<$0.PostView>(1, _omitFieldNames ? '' : 'posts',
        subBuilder: $0.PostView.$_createMessage)
    ..aOS(2, _omitFieldNames ? '' : 'nextPageToken')
    ..aOS(3, _omitFieldNames ? '' : 'sinceToken')
    ..aOS(4, _omitFieldNames ? '' : 'gapPageToken')
    ..pPS(5, _omitFieldNames ? '' : 'removedIds')
    ..aOB(6, _omitFieldNames ? '' : 'authorProtected')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetUserTimelineResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetUserTimelineResponse copyWith(
          void Function(GetUserTimelineResponse) updates) =>
      super.copyWith((message) => updates(message as GetUserTimelineResponse))
          as GetUserTimelineResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use GetUserTimelineResponse() / GetUserTimelineResponse.new instead')
  static GetUserTimelineResponse create() => GetUserTimelineResponse._();
  static $pb.GeneratedMessage $_createMessage() => GetUserTimelineResponse._();
  @$core.override
  GetUserTimelineResponse createEmptyInstance() => GetUserTimelineResponse._();
  @$core.pragma('dart2js:noInline')
  static GetUserTimelineResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<GetUserTimelineResponse>(
          GetUserTimelineResponse.$_createMessage);
  static GetUserTimelineResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<$0.PostView> get posts => $_getList(0);

  @$pb.TagNumber(2)
  $core.String get nextPageToken => $_getSZ(1);
  @$pb.TagNumber(2)
  set nextPageToken($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasNextPageToken() => $_has(1);
  @$pb.TagNumber(2)
  void clearNextPageToken() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get sinceToken => $_getSZ(2);
  @$pb.TagNumber(3)
  set sinceToken($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasSinceToken() => $_has(2);
  @$pb.TagNumber(3)
  void clearSinceToken() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.String get gapPageToken => $_getSZ(3);
  @$pb.TagNumber(4)
  set gapPageToken($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasGapPageToken() => $_has(3);
  @$pb.TagNumber(4)
  void clearGapPageToken() => $_clearField(4);

  /// Refresh only (see the token contract): ids of posts removed by a moderator since the since_token was issued.
  /// At most 50, newest removal first. The client deletes these from its cache. Empty on every other mode.
  @$pb.TagNumber(5)
  $pb.PbList<$core.String> get removedIds => $_getList(4);

  /// True when the author is protected and the caller is neither the author nor a follower (ADR-0025 D4): posts is
  /// empty and no token is set. Show the protected view and REPLACE any cached feed for this author (do not merge). A
  /// client that does not know this field sees an empty list, which fails closed.
  @$pb.TagNumber(6)
  $core.bool get authorProtected => $_getBF(5);
  @$pb.TagNumber(6)
  set authorProtected($core.bool value) => $_setBool(5, value);
  @$pb.TagNumber(6)
  $core.bool hasAuthorProtected() => $_has(5);
  @$pb.TagNumber(6)
  void clearAuthorProtected() => $_clearField(6);
}

class GetListTimelineRequest extends $pb.GeneratedMessage {
  factory GetListTimelineRequest({
    $core.String? listId,
    $core.int? pageSize,
    $core.String? pageToken,
    $core.String? sinceToken,
  }) {
    final result = GetListTimelineRequest._();
    if (listId != null) result.listId = listId;
    if (pageSize != null) result.pageSize = pageSize;
    if (pageToken != null) result.pageToken = pageToken;
    if (sinceToken != null) result.sinceToken = sinceToken;
    return result;
  }

  GetListTimelineRequest._();

  factory GetListTimelineRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetListTimelineRequest()..mergeFromBuffer(data, registry);
  factory GetListTimelineRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetListTimelineRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetListTimelineRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.timeline.v1'),
      createEmptyInstance: GetListTimelineRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'listId')
    ..aI(2, _omitFieldNames ? '' : 'pageSize')
    ..aOS(3, _omitFieldNames ? '' : 'pageToken')
    ..aOS(4, _omitFieldNames ? '' : 'sinceToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetListTimelineRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetListTimelineRequest copyWith(
          void Function(GetListTimelineRequest) updates) =>
      super.copyWith((message) => updates(message as GetListTimelineRequest))
          as GetListTimelineRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use GetListTimelineRequest() / GetListTimelineRequest.new instead')
  static GetListTimelineRequest create() => GetListTimelineRequest._();
  static $pb.GeneratedMessage $_createMessage() => GetListTimelineRequest._();
  @$core.override
  GetListTimelineRequest createEmptyInstance() => GetListTimelineRequest._();
  @$core.pragma('dart2js:noInline')
  static GetListTimelineRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<GetListTimelineRequest>(
          GetListTimelineRequest.$_createMessage);
  static GetListTimelineRequest? _defaultInstance;

  /// 19-digit Snowflake; else VALIDATION "list_id", 0 reads.
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

  /// Older page (infinite scroll or gap fill).
  @$pb.TagNumber(3)
  $core.String get pageToken => $_getSZ(2);
  @$pb.TagNumber(3)
  set pageToken($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasPageToken() => $_has(2);
  @$pb.TagNumber(3)
  void clearPageToken() => $_clearField(3);

  /// Newer-than refresh.
  @$pb.TagNumber(4)
  $core.String get sinceToken => $_getSZ(3);
  @$pb.TagNumber(4)
  set sinceToken($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasSinceToken() => $_has(3);
  @$pb.TagNumber(4)
  void clearSinceToken() => $_clearField(4);
}

class GetListTimelineResponse extends $pb.GeneratedMessage {
  factory GetListTimelineResponse({
    $core.Iterable<$0.PostView>? posts,
    $core.String? nextPageToken,
    $core.String? sinceToken,
    $core.String? gapPageToken,
    $core.Iterable<$core.String>? removedIds,
    $1.ListInfo? list,
  }) {
    final result = GetListTimelineResponse._();
    if (posts != null) result.posts.addAll(posts);
    if (nextPageToken != null) result.nextPageToken = nextPageToken;
    if (sinceToken != null) result.sinceToken = sinceToken;
    if (gapPageToken != null) result.gapPageToken = gapPageToken;
    if (removedIds != null) result.removedIds.addAll(removedIds);
    if (list != null) result.list = list;
    return result;
  }

  GetListTimelineResponse._();

  factory GetListTimelineResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetListTimelineResponse()..mergeFromBuffer(data, registry);
  factory GetListTimelineResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetListTimelineResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetListTimelineResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.timeline.v1'),
      createEmptyInstance: GetListTimelineResponse.$_createMessage)
    ..pPM<$0.PostView>(1, _omitFieldNames ? '' : 'posts',
        subBuilder: $0.PostView.$_createMessage)
    ..aOS(2, _omitFieldNames ? '' : 'nextPageToken')
    ..aOS(3, _omitFieldNames ? '' : 'sinceToken')
    ..aOS(4, _omitFieldNames ? '' : 'gapPageToken')
    ..pPS(5, _omitFieldNames ? '' : 'removedIds')
    ..aOM<$1.ListInfo>(6, _omitFieldNames ? '' : 'list',
        subBuilder: $1.ListInfo.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetListTimelineResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetListTimelineResponse copyWith(
          void Function(GetListTimelineResponse) updates) =>
      super.copyWith((message) => updates(message as GetListTimelineResponse))
          as GetListTimelineResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use GetListTimelineResponse() / GetListTimelineResponse.new instead')
  static GetListTimelineResponse create() => GetListTimelineResponse._();
  static $pb.GeneratedMessage $_createMessage() => GetListTimelineResponse._();
  @$core.override
  GetListTimelineResponse createEmptyInstance() => GetListTimelineResponse._();
  @$core.pragma('dart2js:noInline')
  static GetListTimelineResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<GetListTimelineResponse>(
          GetListTimelineResponse.$_createMessage);
  static GetListTimelineResponse? _defaultInstance;

  /// Newest first.
  @$pb.TagNumber(1)
  $pb.PbList<$0.PostView> get posts => $_getList(0);

  /// "" => no older posts.
  @$pb.TagNumber(2)
  $core.String get nextPageToken => $_getSZ(1);
  @$pb.TagNumber(2)
  set nextPageToken($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasNextPageToken() => $_has(1);
  @$pb.TagNumber(2)
  void clearNextPageToken() => $_clearField(2);

  /// Persist; send on the next refresh.
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

  /// Refresh only (see the token contract): ids of posts by the list's members removed by a moderator since the
  /// since_token was issued. At most 50, newest removal first. Empty on every other mode.
  @$pb.TagNumber(5)
  $pb.PbList<$core.String> get removedIds => $_getList(4);

  /// The list's header (name, owner, member count, pinned_by_viewer), current as of this call: the client refreshes the
  /// tab's label from it.
  @$pb.TagNumber(6)
  $1.ListInfo get list => $_getN(5);
  @$pb.TagNumber(6)
  set list($1.ListInfo value) => $_setField(6, value);
  @$pb.TagNumber(6)
  $core.bool hasList() => $_has(5);
  @$pb.TagNumber(6)
  void clearList() => $_clearField(6);
  @$pb.TagNumber(6)
  $1.ListInfo ensureList() => $_ensure(5);
}

class SetHomeTabsRequest extends $pb.GeneratedMessage {
  factory SetHomeTabsRequest({
    $core.String? idempotencyKey,
    $core.Iterable<$2.HomeTab>? tabs,
  }) {
    final result = SetHomeTabsRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (tabs != null) result.tabs.addAll(tabs);
    return result;
  }

  SetHomeTabsRequest._();

  factory SetHomeTabsRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SetHomeTabsRequest()..mergeFromBuffer(data, registry);
  factory SetHomeTabsRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SetHomeTabsRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'SetHomeTabsRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.timeline.v1'),
      createEmptyInstance: SetHomeTabsRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..pPM<$2.HomeTab>(2, _omitFieldNames ? '' : 'tabs',
        subBuilder: $2.HomeTab.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SetHomeTabsRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SetHomeTabsRequest copyWith(void Function(SetHomeTabsRequest) updates) =>
      super.copyWith((message) => updates(message as SetHomeTabsRequest))
          as SetHomeTabsRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use SetHomeTabsRequest() / SetHomeTabsRequest.new instead')
  static SetHomeTabsRequest create() => SetHomeTabsRequest._();
  static $pb.GeneratedMessage $_createMessage() => SetHomeTabsRequest._();
  @$core.override
  SetHomeTabsRequest createEmptyInstance() => SetHomeTabsRequest._();
  @$core.pragma('dart2js:noInline')
  static SetHomeTabsRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<SetHomeTabsRequest>(
          SetHomeTabsRequest.$_createMessage);
  static SetHomeTabsRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  /// The full new order of pinned tabs (Following is implicit and never sent). Only kind and id are read.
  @$pb.TagNumber(2)
  $pb.PbList<$2.HomeTab> get tabs => $_getList(1);
}

class SetHomeTabsResponse extends $pb.GeneratedMessage {
  factory SetHomeTabsResponse({
    $core.Iterable<$2.HomeTab>? tabs,
  }) {
    final result = SetHomeTabsResponse._();
    if (tabs != null) result.tabs.addAll(tabs);
    return result;
  }

  SetHomeTabsResponse._();

  factory SetHomeTabsResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SetHomeTabsResponse()..mergeFromBuffer(data, registry);
  factory SetHomeTabsResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SetHomeTabsResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'SetHomeTabsResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.timeline.v1'),
      createEmptyInstance: SetHomeTabsResponse.$_createMessage)
    ..pPM<$2.HomeTab>(1, _omitFieldNames ? '' : 'tabs',
        subBuilder: $2.HomeTab.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SetHomeTabsResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SetHomeTabsResponse copyWith(void Function(SetHomeTabsResponse) updates) =>
      super.copyWith((message) => updates(message as SetHomeTabsResponse))
          as SetHomeTabsResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core
      .Deprecated('Use SetHomeTabsResponse() / SetHomeTabsResponse.new instead')
  static SetHomeTabsResponse create() => SetHomeTabsResponse._();
  static $pb.GeneratedMessage $_createMessage() => SetHomeTabsResponse._();
  @$core.override
  SetHomeTabsResponse createEmptyInstance() => SetHomeTabsResponse._();
  @$core.pragma('dart2js:noInline')
  static SetHomeTabsResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<SetHomeTabsResponse>(
          SetHomeTabsResponse.$_createMessage);
  static SetHomeTabsResponse? _defaultInstance;

  /// The stored tabs as GetMe will return them (titles set by the server; kinds whose flag is off omitted).
  @$pb.TagNumber(1)
  $pb.PbList<$2.HomeTab> get tabs => $_getList(0);
}

class TimelineServiceApi {
  final $pb.RpcClient _client;

  TimelineServiceApi(this._client);

  /// Chronological posts (excluding replies) from accounts the caller follows, plus the caller's own.
  /// Algorithm: graph/{uid} (cached 60 s) -> followees + self in chunks of 30 -> per-chunk query
  /// `authorId in chunk AND isReply == false AND createdAt (> since | < before) ORDER BY createdAt DESC
  /// LIMIT k`, k = max(1, ceil(2 * page_size / chunks)), <= 4 concurrent -> k-way merge -> return only the
  /// exact prefix (items newer than the newest k-th item of any chunk that filled its limit) -> drop
  /// blocked/muted/invisible -> hydrate viewer flags from userLikes/{uid}. Authors fully covered by the
  /// author-recent instance cache (last 20 posts, 60 s) skip Firestore.
  /// Filtering (ADR-0010 D6): authors the caller blocks, who block the caller (even if a stale following list
  /// still names them) or whom the caller mutes are dropped; the caller's own posts are always kept. Authors
  /// who are SUSPENDED or DELETING are not filtered at Stage 0 (moderation takedown / purge removes their posts).
  /// Viewer flags are false and userLikes is not read while FEATURE_ENGAGEMENT and FEATURE_BOOKMARKS are both off for the caller (ADR-0010 D3);
  /// with either on, one cached userLikes read hydrates the page (P5; liked / reposted only with engagement, bookmarked_by_viewer with either). A REPOST or QUOTE whose embedded author the caller
  /// blocks or mutes, or who blocks the caller, is dropped like a post by that author; a REPOST item's flags
  /// describe its original. Protected authors (ADR-0025 D4): Home rows are by the caller and followed accounts only,
  /// so none is hidden; a REPOST whose original is by a protected author the caller does not follow is dropped, and a
  /// QUOTE of such a post is kept with embed_viewer_state = PROTECTED and its embed stripped of text and media. 0 extra
  /// reads.
  /// Every query that returns 0 docs still costs 1 read. C = ceil((following + 1) / 30), following <= 5,000.
  /// Rate limit: 6 calls/min/uid (in memory). Deadline 10 s.
  /// Firestore: reads worst 2 + C + 2 * page_size (= 269 at 5,000 following, page 50; 2 = caller users via the
  ///            account-status interceptor + graph; +1 userLikes with FEATURE_ENGAGEMENT or FEATURE_BOOKMARKS on) / planning: refresh
  ///            4 + new posts (F=60: C=3, graph expired because refreshes are >= 60 s apart), older page or
  ///            cold open 30 (F=60, page 20), writes 0.
  /// A since_token refresh also consults the instance-cached removal log (removed_ids, behind FEATURE_REMOVED_IDS:
  /// 0 reads while that flag is off). The shared log refresh (0 on a warm hit, 1 to 50 once per instance per
  /// CACHE_TTL, 100 worst) runs on a detached counter and is NOT charged to the caller's read budget (request log
  /// field removal_log_reads). Only a token older than the instance's log cache reads for the caller: at most 107
  /// (one bounded window query on postRemovals, only for feeds of up to 180 accounts), so a refresh stays bounded
  /// by 2 + C + 2 * page_size = 269 at 5,000 following, page 50. Other modes read nothing from the log. Suspending
  /// an account with 50 or more posts makes only the feeds that show it reset once (see removed_ids in the token
  /// contract).
  /// Every call is charged to the per-uid daily Firestore read budget (ADR-0010 D5).
  $async.Future<GetHomeTimelineResponse> getHomeTimeline(
          $pb.ClientContext? ctx, GetHomeTimelineRequest request) =>
      _client.invoke<GetHomeTimelineResponse>(ctx, 'TimelineService',
          'GetHomeTimeline', request, GetHomeTimelineResponse());

  /// A user's posts, newest first. include_replies=false is the "Posts" tab (root posts), true is "Replies"
  /// (all of the user's posts incl. replies; identical to Posts until replies ship, ADR-0010 D11).
  /// Protected accounts (ADR-0025 D4): for a caller who is neither the account nor a follower of it, every tab answers
  /// author_protected = true with no posts and no tokens. It is decided before the author-recent cache or any page is
  /// read (3 cold reads: interceptor, target users, caller graph), after the NOT_FOUND rules below. The client shows
  /// the protected view (the profile itself comes from identity) and REPLACES any cached feed for this author. In
  /// every tab, a REPOST whose original is by a protected author the caller does not follow is dropped, and a QUOTE of
  /// such a post is kept with embed_viewer_state = PROTECTED and its embed stripped of text and media.
  /// NOT_FOUND (byte-identical to GetProfile's missing-user error) if the user is missing, SUSPENDED or DELETING,
  /// or blocks the caller. A caller who blocks or mutes the user still gets the posts; the client shows a banner
  /// for a block (ADR-0010 D6). The Posts-tab first page (<= 20) comes from the author-recent instance cache
  /// (60 s). Pages use Limit(page_size); next_page_token is set whenever a page is full (ADR-0010 D16).
  /// Reads: caller users (account-status interceptor) + user users (status) + caller graph (blocked-by), all
  /// cached 60 s, + page; +1 user graph if the caller's blocked-by list overflowed (ADR-0008 D2).
  /// Firestore: reads 3 + max(page_size, 20) cold (a cold Posts tab fills the 20-post author-recent entry, so
  /// page_size < 20 still reads 20; 53 at page 50) / 0 warm, planning 11; since_token refresh with 0 new
  /// posts 4 cold / 0-1 warm; +1 userLikes (cold, cached 60 s) with FEATURE_ENGAGEMENT or FEATURE_BOOKMARKS on. Writes 0.
  /// A since_token refresh also consults the removal log (removed_ids), scoped to the profile's author, with the same
  /// cost rules as GetHomeTimeline: the shared refresh is detached from the caller's budget; a token older than the
  /// instance's log cache adds at most 107 reads (one window query). Behind FEATURE_REMOVED_IDS: 0 reads while off.
  /// Tabs (ADR-0024 D5): tab = UNSPECIFIED (the default, every pre-W3 client) means "use include_replies" exactly as
  /// above; any other tab WINS and include_replies is ignored with no error. POSTS and REPLIES are the two feeds above
  /// and stay ungated. MEDIA (the author's posts with their own images, replies and quotes included, REPOSTs
  /// excluded) and REPOSTS (the author's REPOST items) need FEATURE_PROFILE_TABS (wire name "profile_tabs") on for
  /// the caller, else FAILED_PRECONDITION + FEATURE_DISABLED, metadata["feature"] = "profile_tabs", 0 reads. Same
  /// NOT_FOUND, block, mute and embed rules as the Posts tab (a REPOST whose embedded author the caller blocks or
  /// mutes, or who blocks the caller, is dropped; a QUOTE carries embed_viewer_state), same since_token,
  /// gap_page_token and removed_ids behaviour. MEDIA and REPOSTS use one Limit(page_size) query per page and no
  /// instance cache. Rate limit: the GetUserTimeline bucket, shared by every tab.
  /// Firestore (MEDIA or REPOSTS): reads 24 cold at page 20 / 54 at page 50 (interceptor, target users, caller
  /// graph, page, userLikes), 20 warm at page 20 (planning 20), writes 0.
  $async.Future<GetUserTimelineResponse> getUserTimeline(
          $pb.ClientContext? ctx, GetUserTimelineRequest request) =>
      _client.invoke<GetUserTimelineResponse>(ctx, 'TimelineService',
          'GetUserTimeline', request, GetUserTimelineResponse());

  /// A list's feed (ADR-0030 D5): chronological posts (excluding replies) by the list's members, newest first. It is
  /// Home's pull-merge run over the members instead of the followees: the same chunks of 30, k, <= 4 queries in
  /// flight, exact-prefix merge, author-recent instance cache (shared with Home, so a warm Home makes a list refresh
  /// cheaper), the same token contract above and the same removed_ids, scoped to the members. No new merge, cursor or
  /// cache.
  /// NOT_FOUND (one message, byte-identical to a list id that never existed; lists.proto header): the list is missing,
  /// private or hidden and the caller is not its owner, or its owner blocks the caller, is not ACTIVE or has an
  /// overflowed blockedBy (fail closed). A list that becomes NOT_FOUND between calls answers NOT_FOUND: the client
  /// shows the tab as unavailable and offers Unpin. An empty list answers an empty page with a since_token.
  /// Filtering, per viewer, after the cache (ADR-0030 D4, ADR-0010 D6): members who block the list's owner are dropped
  /// for every viewer (F4); members the caller blocks or mutes, or who block the caller, are dropped; the caller's own
  /// posts are kept. A caller whose blockedBy overflowed keeps only their own posts and members they follow (fail
  /// closed). Protected members (ADR-0025 D3, D4): a row by a protected member who has not approved the caller is
  /// dropped, which, unlike Home, can happen here; a REPOST of such an author's post is dropped and a QUOTE of one
  /// carries embed_viewer_state = PROTECTED, exactly as on Home. These decisions may consult the instance-cached
  /// protected-author set (detached refresh, 0 reads charged); when no set younger than PROTECTED_SET_MAX_STALE can be
  /// loaded the call answers UNAVAILABLE (retryable), never an unfiltered page.
  /// list is the list's header (lists.v1.ListInfo) on every response, read with the list: 0 extra reads.
  /// Flags: FEATURE_LISTS (wire name "lists", else FAILED_PRECONDITION + FEATURE_DISABLED, metadata["feature"] =
  /// "lists", 0 reads) and FEATURE_POSTS as for Home; removed_ids behind FEATURE_REMOVED_IDS.
  /// Rate limit: RATE_LIMIT_LIST_TIMELINE_PER_MIN, 12 calls/min/uid per instance (36 with 3 instances). Deadline 10 s.
  /// Firestore: C = ceil(members / 30) <= 5 at LIST_MAX_MEMBERS 150. Reads worst 6 + C + 2 * page_size for a non-owner
  /// caller (interceptor, list, caller graph, owner graph, owner profile, userLikes) = 111 at 150 members and page 50,
  /// 51 at page 20; the owner 4 + C + 2 * page_size. A since_token older than the instance's removal-log cache adds at
  /// most 107 (the ADR-0016 window query; lists have <= 180 members, so it always applies): 218 worst, under the
  /// per-call hold of 269. The shared removal-log refresh is detached, as for Home. Planning: refresh 4 + new posts,
  /// cold open or older page 30; an empty since refresh by the owner, cold, 3 + C. Writes 0.
  /// Every call is charged to the per-uid daily Firestore read budget (ADR-0010 D5).
  $async.Future<GetListTimelineResponse> getListTimeline(
          $pb.ClientContext? ctx, GetListTimelineRequest request) =>
      _client.invoke<GetListTimelineResponse>(ctx, 'TimelineService',
          'GetListTimeline', request, GetListTimelineResponse());

  /// Replace the caller's pinned Home tabs (after the fixed Following tab) with tabs, in that order (ADR-0030 D6,
  /// founder decision F5). Read back through IdentityService.GetMe home_tabs.
  /// Rules: at most HOME_TABS_MAX_PINNED (5) tabs, counting stored tabs of a kind whose flag is off for the caller
  /// (those are not in GetMe and are kept after the sent ones), else FAILED_PRECONDITION + LIMIT_REACHED,
  /// metadata["limit"] = "home_tabs". A duplicate (same kind and id), kind UNSPECIFIED, kind COMMUNITY (until W5 Part
  /// B ships its timeline) or a malformed id => INVALID_ARGUMENT + VALIDATION, metadata["field"] = "tabs", 0 reads.
  /// A LIST tab needs FEATURE_LISTS on for the caller, else FEATURE_DISABLED, metadata["feature"] = "lists", 0 reads;
  /// an empty tabs (unpin everything) is always accepted. A tab NOT already stored must be a list the caller may read
  /// now (GetList's rules), else VALIDATION "tabs", one answer for missing, private, hidden and blocked lists; a tab
  /// already stored is kept without being re-read, so an unavailable tab can still be moved or removed. title is
  /// ignored on input; the server sets it (common.v1.HomeTab).
  /// Idempotency: the standard TTL'd idempotency document, as every lists.v1 mutation (rule 4). One transaction in
  /// identity (the timeline.HomeTabsStore seam): idempotency doc and users/{uid} fresh, then a field-level update of
  /// users/{uid}.homeTabs (no other field). The same tabs again => the idempotency document only. The caller's profile
  /// cache on this instance is updated in place; other instances serve the new order within 60 s.
  /// Rate limits: the RATE_LIMIT_LISTS_WRITE_PER_MIN bucket (30/min/uid per instance) and the list_mutation_daily cap
  /// (LIST_MUTATIONS_PER_DAY 500 per uid per instance), shared with the list mutations. DEGRADED_MODE=readonly refuses
  /// it.
  /// Firestore: reads worst 19 cold (interceptor, idempotency, users/{uid}, <= 5 new list docs, caller graph, and for
  /// another user's list its owner's profile and graph, <= 5 owners, all cache-first), typical 4; writes 2 (users
  /// field-level, idempotency), 1 when nothing changes, + 1 TTL delete later; replay reads 2, writes 0.
  $async.Future<SetHomeTabsResponse> setHomeTabs(
          $pb.ClientContext? ctx, SetHomeTabsRequest request) =>
      _client.invoke<SetHomeTabsResponse>(ctx, 'TimelineService', 'SetHomeTabs',
          request, SetHomeTabsResponse());
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
