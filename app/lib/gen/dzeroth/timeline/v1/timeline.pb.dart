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

import '../../posts/v1/posts.pb.dart' as $0;

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

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
  }) {
    final result = GetHomeTimelineResponse._();
    if (posts != null) result.posts.addAll(posts);
    if (nextPageToken != null) result.nextPageToken = nextPageToken;
    if (sinceToken != null) result.sinceToken = sinceToken;
    if (gapPageToken != null) result.gapPageToken = gapPageToken;
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
}

class GetUserTimelineRequest extends $pb.GeneratedMessage {
  factory GetUserTimelineRequest({
    $core.String? userId,
    $core.bool? includeReplies,
    $core.int? pageSize,
    $core.String? pageToken,
    $core.String? sinceToken,
  }) {
    final result = GetUserTimelineRequest._();
    if (userId != null) result.userId = userId;
    if (includeReplies != null) result.includeReplies = includeReplies;
    if (pageSize != null) result.pageSize = pageSize;
    if (pageToken != null) result.pageToken = pageToken;
    if (sinceToken != null) result.sinceToken = sinceToken;
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
}

class GetUserTimelineResponse extends $pb.GeneratedMessage {
  factory GetUserTimelineResponse({
    $core.Iterable<$0.PostView>? posts,
    $core.String? nextPageToken,
    $core.String? sinceToken,
    $core.String? gapPageToken,
  }) {
    final result = GetUserTimelineResponse._();
    if (posts != null) result.posts.addAll(posts);
    if (nextPageToken != null) result.nextPageToken = nextPageToken;
    if (sinceToken != null) result.sinceToken = sinceToken;
    if (gapPageToken != null) result.gapPageToken = gapPageToken;
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
  /// Viewer flags are false and userLikes is not read until engagement ships (ADR-0010 D3).
  /// Every query that returns 0 docs still costs 1 read. C = ceil((following + 1) / 30), following <= 5,000.
  /// Rate limit: 6 calls/min/uid (in memory). Deadline 10 s.
  /// Firestore: reads worst 2 + C + 2 * page_size (= 269 at 5,000 following, page 50; 2 = caller users via the
  ///            account-status interceptor + graph; +1 userLikes once engagement ships) / planning: refresh
  ///            4 + new posts (F=60: C=3, graph expired because refreshes are >= 60 s apart), older page or
  ///            cold open 30 (F=60, page 20), writes 0.
  /// Every call is charged to the per-uid daily Firestore read budget (ADR-0010 D5).
  $async.Future<GetHomeTimelineResponse> getHomeTimeline(
          $pb.ClientContext? ctx, GetHomeTimelineRequest request) =>
      _client.invoke<GetHomeTimelineResponse>(ctx, 'TimelineService',
          'GetHomeTimeline', request, GetHomeTimelineResponse());

  /// A user's posts, newest first. include_replies=false is the "Posts" tab (root posts), true is "Replies"
  /// (all of the user's posts incl. replies; identical to Posts until replies ship, ADR-0010 D11).
  /// Private accounts: only the owner and approved followers (others get an empty list + profile via identity).
  /// Deferred with private accounts (ADR-0008 D1): every post is PUBLIC today.
  /// NOT_FOUND (byte-identical to GetProfile's missing-user error) if the user is missing, SUSPENDED or DELETING,
  /// or blocks the caller. A caller who blocks or mutes the user still gets the posts; the client shows a banner
  /// for a block (ADR-0010 D6). The Posts-tab first page (<= 20) comes from the author-recent instance cache
  /// (60 s). Pages use Limit(page_size); next_page_token is set whenever a page is full (ADR-0010 D16).
  /// Reads: caller users (account-status interceptor) + user users (status) + caller graph (blocked-by), all
  /// cached 60 s, + page; +1 user graph if the caller's blocked-by list overflowed (ADR-0008 D2).
  /// Firestore: reads 3 + max(page_size, 20) cold (a cold Posts tab fills the 20-post author-recent entry, so
  /// page_size < 20 still reads 20; 53 at page 50) / 0 warm, planning 11; since_token refresh with 0 new
  /// posts 4 cold / 0-1 warm; +1 (userLikes) once engagement ships. Writes 0.
  $async.Future<GetUserTimelineResponse> getUserTimeline(
          $pb.ClientContext? ctx, GetUserTimelineRequest request) =>
      _client.invoke<GetUserTimelineResponse>(ctx, 'TimelineService',
          'GetUserTimeline', request, GetUserTimelineResponse());
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
