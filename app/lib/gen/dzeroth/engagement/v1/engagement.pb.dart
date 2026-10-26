// This is a generated file - do not edit.
//
// Generated from dzeroth/engagement/v1/engagement.proto.

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
    as $1;

import '../../posts/v1/posts.pb.dart' as $0;

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

/// The post's engagement as the caller now sees it. Counts are the instance's best knowledge (the post doc read
/// plus this call's own change), so they may lag other users' concurrent actions by up to the 60 s cache TTL.
class PostEngagement extends $pb.GeneratedMessage {
  factory PostEngagement({
    $core.String? postId,
    $fixnum.Int64? likeCount,
    $fixnum.Int64? repostCount,
    $core.bool? likedByViewer,
    $core.bool? repostedByViewer,
  }) {
    final result = PostEngagement._();
    if (postId != null) result.postId = postId;
    if (likeCount != null) result.likeCount = likeCount;
    if (repostCount != null) result.repostCount = repostCount;
    if (likedByViewer != null) result.likedByViewer = likedByViewer;
    if (repostedByViewer != null) result.repostedByViewer = repostedByViewer;
    return result;
  }

  PostEngagement._();

  factory PostEngagement.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      PostEngagement()..mergeFromBuffer(data, registry);
  factory PostEngagement.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      PostEngagement()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'PostEngagement',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.engagement.v1'),
      createEmptyInstance: PostEngagement.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'postId')
    ..aInt64(2, _omitFieldNames ? '' : 'likeCount')
    ..aInt64(3, _omitFieldNames ? '' : 'repostCount')
    ..aOB(4, _omitFieldNames ? '' : 'likedByViewer')
    ..aOB(5, _omitFieldNames ? '' : 'repostedByViewer')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PostEngagement clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PostEngagement copyWith(void Function(PostEngagement) updates) =>
      super.copyWith((message) => updates(message as PostEngagement))
          as PostEngagement;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use PostEngagement() / PostEngagement.new instead')
  static PostEngagement create() => PostEngagement._();
  static $pb.GeneratedMessage $_createMessage() => PostEngagement._();
  @$core.override
  PostEngagement createEmptyInstance() => PostEngagement._();
  @$core.pragma('dart2js:noInline')
  static PostEngagement getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<PostEngagement>(
          PostEngagement.$_createMessage);
  static PostEngagement? _defaultInstance;

  /// The post the action applied to: the original when the request named a REPOST.
  @$pb.TagNumber(1)
  $core.String get postId => $_getSZ(0);
  @$pb.TagNumber(1)
  set postId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasPostId() => $_has(0);
  @$pb.TagNumber(1)
  void clearPostId() => $_clearField(1);

  @$pb.TagNumber(2)
  $fixnum.Int64 get likeCount => $_getI64(1);
  @$pb.TagNumber(2)
  set likeCount($fixnum.Int64 value) => $_setInt64(1, value);
  @$pb.TagNumber(2)
  $core.bool hasLikeCount() => $_has(1);
  @$pb.TagNumber(2)
  void clearLikeCount() => $_clearField(2);

  @$pb.TagNumber(3)
  $fixnum.Int64 get repostCount => $_getI64(2);
  @$pb.TagNumber(3)
  set repostCount($fixnum.Int64 value) => $_setInt64(2, value);
  @$pb.TagNumber(3)
  $core.bool hasRepostCount() => $_has(2);
  @$pb.TagNumber(3)
  void clearRepostCount() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.bool get likedByViewer => $_getBF(3);
  @$pb.TagNumber(4)
  set likedByViewer($core.bool value) => $_setBool(3, value);
  @$pb.TagNumber(4)
  $core.bool hasLikedByViewer() => $_has(3);
  @$pb.TagNumber(4)
  void clearLikedByViewer() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.bool get repostedByViewer => $_getBF(4);
  @$pb.TagNumber(5)
  set repostedByViewer($core.bool value) => $_setBool(4, value);
  @$pb.TagNumber(5)
  $core.bool hasRepostedByViewer() => $_has(4);
  @$pb.TagNumber(5)
  void clearRepostedByViewer() => $_clearField(5);
}

class LikePostRequest extends $pb.GeneratedMessage {
  factory LikePostRequest({
    $core.String? idempotencyKey,
    $core.String? postId,
  }) {
    final result = LikePostRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (postId != null) result.postId = postId;
    return result;
  }

  LikePostRequest._();

  factory LikePostRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      LikePostRequest()..mergeFromBuffer(data, registry);
  factory LikePostRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      LikePostRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'LikePostRequest',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.engagement.v1'),
      createEmptyInstance: LikePostRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'postId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  LikePostRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  LikePostRequest copyWith(void Function(LikePostRequest) updates) =>
      super.copyWith((message) => updates(message as LikePostRequest))
          as LikePostRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use LikePostRequest() / LikePostRequest.new instead')
  static LikePostRequest create() => LikePostRequest._();
  static $pb.GeneratedMessage $_createMessage() => LikePostRequest._();
  @$core.override
  LikePostRequest createEmptyInstance() => LikePostRequest._();
  @$core.pragma('dart2js:noInline')
  static LikePostRequest getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<LikePostRequest>(
          LikePostRequest.$_createMessage);
  static LikePostRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get postId => $_getSZ(1);
  @$pb.TagNumber(2)
  set postId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasPostId() => $_has(1);
  @$pb.TagNumber(2)
  void clearPostId() => $_clearField(2);
}

class LikePostResponse extends $pb.GeneratedMessage {
  factory LikePostResponse({
    PostEngagement? engagement,
  }) {
    final result = LikePostResponse._();
    if (engagement != null) result.engagement = engagement;
    return result;
  }

  LikePostResponse._();

  factory LikePostResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      LikePostResponse()..mergeFromBuffer(data, registry);
  factory LikePostResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      LikePostResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'LikePostResponse',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.engagement.v1'),
      createEmptyInstance: LikePostResponse.$_createMessage)
    ..aOM<PostEngagement>(1, _omitFieldNames ? '' : 'engagement',
        subBuilder: PostEngagement.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  LikePostResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  LikePostResponse copyWith(void Function(LikePostResponse) updates) =>
      super.copyWith((message) => updates(message as LikePostResponse))
          as LikePostResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use LikePostResponse() / LikePostResponse.new instead')
  static LikePostResponse create() => LikePostResponse._();
  static $pb.GeneratedMessage $_createMessage() => LikePostResponse._();
  @$core.override
  LikePostResponse createEmptyInstance() => LikePostResponse._();
  @$core.pragma('dart2js:noInline')
  static LikePostResponse getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<LikePostResponse>(
          LikePostResponse.$_createMessage);
  static LikePostResponse? _defaultInstance;

  @$pb.TagNumber(1)
  PostEngagement get engagement => $_getN(0);
  @$pb.TagNumber(1)
  set engagement(PostEngagement value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasEngagement() => $_has(0);
  @$pb.TagNumber(1)
  void clearEngagement() => $_clearField(1);
  @$pb.TagNumber(1)
  PostEngagement ensureEngagement() => $_ensure(0);
}

class UnlikePostRequest extends $pb.GeneratedMessage {
  factory UnlikePostRequest({
    $core.String? idempotencyKey,
    $core.String? postId,
  }) {
    final result = UnlikePostRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (postId != null) result.postId = postId;
    return result;
  }

  UnlikePostRequest._();

  factory UnlikePostRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UnlikePostRequest()..mergeFromBuffer(data, registry);
  factory UnlikePostRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UnlikePostRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'UnlikePostRequest',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.engagement.v1'),
      createEmptyInstance: UnlikePostRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'postId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UnlikePostRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UnlikePostRequest copyWith(void Function(UnlikePostRequest) updates) =>
      super.copyWith((message) => updates(message as UnlikePostRequest))
          as UnlikePostRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use UnlikePostRequest() / UnlikePostRequest.new instead')
  static UnlikePostRequest create() => UnlikePostRequest._();
  static $pb.GeneratedMessage $_createMessage() => UnlikePostRequest._();
  @$core.override
  UnlikePostRequest createEmptyInstance() => UnlikePostRequest._();
  @$core.pragma('dart2js:noInline')
  static UnlikePostRequest getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<UnlikePostRequest>(
          UnlikePostRequest.$_createMessage);
  static UnlikePostRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get postId => $_getSZ(1);
  @$pb.TagNumber(2)
  set postId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasPostId() => $_has(1);
  @$pb.TagNumber(2)
  void clearPostId() => $_clearField(2);
}

class UnlikePostResponse extends $pb.GeneratedMessage {
  factory UnlikePostResponse({
    PostEngagement? engagement,
  }) {
    final result = UnlikePostResponse._();
    if (engagement != null) result.engagement = engagement;
    return result;
  }

  UnlikePostResponse._();

  factory UnlikePostResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UnlikePostResponse()..mergeFromBuffer(data, registry);
  factory UnlikePostResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UnlikePostResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'UnlikePostResponse',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.engagement.v1'),
      createEmptyInstance: UnlikePostResponse.$_createMessage)
    ..aOM<PostEngagement>(1, _omitFieldNames ? '' : 'engagement',
        subBuilder: PostEngagement.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UnlikePostResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UnlikePostResponse copyWith(void Function(UnlikePostResponse) updates) =>
      super.copyWith((message) => updates(message as UnlikePostResponse))
          as UnlikePostResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use UnlikePostResponse() / UnlikePostResponse.new instead')
  static UnlikePostResponse create() => UnlikePostResponse._();
  static $pb.GeneratedMessage $_createMessage() => UnlikePostResponse._();
  @$core.override
  UnlikePostResponse createEmptyInstance() => UnlikePostResponse._();
  @$core.pragma('dart2js:noInline')
  static UnlikePostResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<UnlikePostResponse>(
          UnlikePostResponse.$_createMessage);
  static UnlikePostResponse? _defaultInstance;

  @$pb.TagNumber(1)
  PostEngagement get engagement => $_getN(0);
  @$pb.TagNumber(1)
  set engagement(PostEngagement value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasEngagement() => $_has(0);
  @$pb.TagNumber(1)
  void clearEngagement() => $_clearField(1);
  @$pb.TagNumber(1)
  PostEngagement ensureEngagement() => $_ensure(0);
}

class RepostPostRequest extends $pb.GeneratedMessage {
  factory RepostPostRequest({
    $core.String? idempotencyKey,
    $core.String? postId,
  }) {
    final result = RepostPostRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (postId != null) result.postId = postId;
    return result;
  }

  RepostPostRequest._();

  factory RepostPostRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RepostPostRequest()..mergeFromBuffer(data, registry);
  factory RepostPostRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RepostPostRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RepostPostRequest',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.engagement.v1'),
      createEmptyInstance: RepostPostRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'postId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RepostPostRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RepostPostRequest copyWith(void Function(RepostPostRequest) updates) =>
      super.copyWith((message) => updates(message as RepostPostRequest))
          as RepostPostRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use RepostPostRequest() / RepostPostRequest.new instead')
  static RepostPostRequest create() => RepostPostRequest._();
  static $pb.GeneratedMessage $_createMessage() => RepostPostRequest._();
  @$core.override
  RepostPostRequest createEmptyInstance() => RepostPostRequest._();
  @$core.pragma('dart2js:noInline')
  static RepostPostRequest getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<RepostPostRequest>(
          RepostPostRequest.$_createMessage);
  static RepostPostRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get postId => $_getSZ(1);
  @$pb.TagNumber(2)
  set postId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasPostId() => $_has(1);
  @$pb.TagNumber(2)
  void clearPostId() => $_clearField(2);
}

class RepostPostResponse extends $pb.GeneratedMessage {
  factory RepostPostResponse({
    PostEngagement? engagement,
    $core.String? repostPostId,
  }) {
    final result = RepostPostResponse._();
    if (engagement != null) result.engagement = engagement;
    if (repostPostId != null) result.repostPostId = repostPostId;
    return result;
  }

  RepostPostResponse._();

  factory RepostPostResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RepostPostResponse()..mergeFromBuffer(data, registry);
  factory RepostPostResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RepostPostResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RepostPostResponse',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.engagement.v1'),
      createEmptyInstance: RepostPostResponse.$_createMessage)
    ..aOM<PostEngagement>(1, _omitFieldNames ? '' : 'engagement',
        subBuilder: PostEngagement.$_createMessage)
    ..aOS(2, _omitFieldNames ? '' : 'repostPostId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RepostPostResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RepostPostResponse copyWith(void Function(RepostPostResponse) updates) =>
      super.copyWith((message) => updates(message as RepostPostResponse))
          as RepostPostResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use RepostPostResponse() / RepostPostResponse.new instead')
  static RepostPostResponse create() => RepostPostResponse._();
  static $pb.GeneratedMessage $_createMessage() => RepostPostResponse._();
  @$core.override
  RepostPostResponse createEmptyInstance() => RepostPostResponse._();
  @$core.pragma('dart2js:noInline')
  static RepostPostResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<RepostPostResponse>(
          RepostPostResponse.$_createMessage);
  static RepostPostResponse? _defaultInstance;

  @$pb.TagNumber(1)
  PostEngagement get engagement => $_getN(0);
  @$pb.TagNumber(1)
  set engagement(PostEngagement value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasEngagement() => $_has(0);
  @$pb.TagNumber(1)
  void clearEngagement() => $_clearField(1);
  @$pb.TagNumber(1)
  PostEngagement ensureEngagement() => $_ensure(0);

  /// The REPOST post doc created for (or already existing for) this repost; DeletePost on it has the same effect
  /// as UndoRepost.
  @$pb.TagNumber(2)
  $core.String get repostPostId => $_getSZ(1);
  @$pb.TagNumber(2)
  set repostPostId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasRepostPostId() => $_has(1);
  @$pb.TagNumber(2)
  void clearRepostPostId() => $_clearField(2);
}

class UndoRepostRequest extends $pb.GeneratedMessage {
  factory UndoRepostRequest({
    $core.String? idempotencyKey,
    $core.String? postId,
  }) {
    final result = UndoRepostRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (postId != null) result.postId = postId;
    return result;
  }

  UndoRepostRequest._();

  factory UndoRepostRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UndoRepostRequest()..mergeFromBuffer(data, registry);
  factory UndoRepostRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UndoRepostRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'UndoRepostRequest',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.engagement.v1'),
      createEmptyInstance: UndoRepostRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'postId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UndoRepostRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UndoRepostRequest copyWith(void Function(UndoRepostRequest) updates) =>
      super.copyWith((message) => updates(message as UndoRepostRequest))
          as UndoRepostRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use UndoRepostRequest() / UndoRepostRequest.new instead')
  static UndoRepostRequest create() => UndoRepostRequest._();
  static $pb.GeneratedMessage $_createMessage() => UndoRepostRequest._();
  @$core.override
  UndoRepostRequest createEmptyInstance() => UndoRepostRequest._();
  @$core.pragma('dart2js:noInline')
  static UndoRepostRequest getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<UndoRepostRequest>(
          UndoRepostRequest.$_createMessage);
  static UndoRepostRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get postId => $_getSZ(1);
  @$pb.TagNumber(2)
  set postId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasPostId() => $_has(1);
  @$pb.TagNumber(2)
  void clearPostId() => $_clearField(2);
}

class UndoRepostResponse extends $pb.GeneratedMessage {
  factory UndoRepostResponse({
    PostEngagement? engagement,
  }) {
    final result = UndoRepostResponse._();
    if (engagement != null) result.engagement = engagement;
    return result;
  }

  UndoRepostResponse._();

  factory UndoRepostResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UndoRepostResponse()..mergeFromBuffer(data, registry);
  factory UndoRepostResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UndoRepostResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'UndoRepostResponse',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.engagement.v1'),
      createEmptyInstance: UndoRepostResponse.$_createMessage)
    ..aOM<PostEngagement>(1, _omitFieldNames ? '' : 'engagement',
        subBuilder: PostEngagement.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UndoRepostResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UndoRepostResponse copyWith(void Function(UndoRepostResponse) updates) =>
      super.copyWith((message) => updates(message as UndoRepostResponse))
          as UndoRepostResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use UndoRepostResponse() / UndoRepostResponse.new instead')
  static UndoRepostResponse create() => UndoRepostResponse._();
  static $pb.GeneratedMessage $_createMessage() => UndoRepostResponse._();
  @$core.override
  UndoRepostResponse createEmptyInstance() => UndoRepostResponse._();
  @$core.pragma('dart2js:noInline')
  static UndoRepostResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<UndoRepostResponse>(
          UndoRepostResponse.$_createMessage);
  static UndoRepostResponse? _defaultInstance;

  @$pb.TagNumber(1)
  PostEngagement get engagement => $_getN(0);
  @$pb.TagNumber(1)
  set engagement(PostEngagement value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasEngagement() => $_has(0);
  @$pb.TagNumber(1)
  void clearEngagement() => $_clearField(1);
  @$pb.TagNumber(1)
  PostEngagement ensureEngagement() => $_ensure(0);
}

/// The caller's bookmark state of one post after AddBookmark or RemoveBookmark (ADR-0023).
class BookmarkState extends $pb.GeneratedMessage {
  factory BookmarkState({
    $core.String? postId,
    $core.bool? bookmarked,
  }) {
    final result = BookmarkState._();
    if (postId != null) result.postId = postId;
    if (bookmarked != null) result.bookmarked = bookmarked;
    return result;
  }

  BookmarkState._();

  factory BookmarkState.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      BookmarkState()..mergeFromBuffer(data, registry);
  factory BookmarkState.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      BookmarkState()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'BookmarkState',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.engagement.v1'),
      createEmptyInstance: BookmarkState.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'postId')
    ..aOB(2, _omitFieldNames ? '' : 'bookmarked')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BookmarkState clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BookmarkState copyWith(void Function(BookmarkState) updates) =>
      super.copyWith((message) => updates(message as BookmarkState))
          as BookmarkState;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use BookmarkState() / BookmarkState.new instead')
  static BookmarkState create() => BookmarkState._();
  static $pb.GeneratedMessage $_createMessage() => BookmarkState._();
  @$core.override
  BookmarkState createEmptyInstance() => BookmarkState._();
  @$core.pragma('dart2js:noInline')
  static BookmarkState getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<BookmarkState>(
          BookmarkState.$_createMessage);
  static BookmarkState? _defaultInstance;

  /// The post the action applied to: the original when AddBookmark named a REPOST. Pass this id to RemoveBookmark.
  @$pb.TagNumber(1)
  $core.String get postId => $_getSZ(0);
  @$pb.TagNumber(1)
  set postId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasPostId() => $_has(0);
  @$pb.TagNumber(1)
  void clearPostId() => $_clearField(1);

  /// True after AddBookmark (including a post that was already bookmarked), false after RemoveBookmark.
  @$pb.TagNumber(2)
  $core.bool get bookmarked => $_getBF(1);
  @$pb.TagNumber(2)
  set bookmarked($core.bool value) => $_setBool(1, value);
  @$pb.TagNumber(2)
  $core.bool hasBookmarked() => $_has(1);
  @$pb.TagNumber(2)
  void clearBookmarked() => $_clearField(2);
}

class AddBookmarkRequest extends $pb.GeneratedMessage {
  factory AddBookmarkRequest({
    $core.String? idempotencyKey,
    $core.String? postId,
  }) {
    final result = AddBookmarkRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (postId != null) result.postId = postId;
    return result;
  }

  AddBookmarkRequest._();

  factory AddBookmarkRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      AddBookmarkRequest()..mergeFromBuffer(data, registry);
  factory AddBookmarkRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      AddBookmarkRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'AddBookmarkRequest',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.engagement.v1'),
      createEmptyInstance: AddBookmarkRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'postId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AddBookmarkRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AddBookmarkRequest copyWith(void Function(AddBookmarkRequest) updates) =>
      super.copyWith((message) => updates(message as AddBookmarkRequest))
          as AddBookmarkRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use AddBookmarkRequest() / AddBookmarkRequest.new instead')
  static AddBookmarkRequest create() => AddBookmarkRequest._();
  static $pb.GeneratedMessage $_createMessage() => AddBookmarkRequest._();
  @$core.override
  AddBookmarkRequest createEmptyInstance() => AddBookmarkRequest._();
  @$core.pragma('dart2js:noInline')
  static AddBookmarkRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<AddBookmarkRequest>(
          AddBookmarkRequest.$_createMessage);
  static AddBookmarkRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get postId => $_getSZ(1);
  @$pb.TagNumber(2)
  set postId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasPostId() => $_has(1);
  @$pb.TagNumber(2)
  void clearPostId() => $_clearField(2);
}

class AddBookmarkResponse extends $pb.GeneratedMessage {
  factory AddBookmarkResponse({
    BookmarkState? state,
  }) {
    final result = AddBookmarkResponse._();
    if (state != null) result.state = state;
    return result;
  }

  AddBookmarkResponse._();

  factory AddBookmarkResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      AddBookmarkResponse()..mergeFromBuffer(data, registry);
  factory AddBookmarkResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      AddBookmarkResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'AddBookmarkResponse',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.engagement.v1'),
      createEmptyInstance: AddBookmarkResponse.$_createMessage)
    ..aOM<BookmarkState>(1, _omitFieldNames ? '' : 'state',
        subBuilder: BookmarkState.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AddBookmarkResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AddBookmarkResponse copyWith(void Function(AddBookmarkResponse) updates) =>
      super.copyWith((message) => updates(message as AddBookmarkResponse))
          as AddBookmarkResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core
      .Deprecated('Use AddBookmarkResponse() / AddBookmarkResponse.new instead')
  static AddBookmarkResponse create() => AddBookmarkResponse._();
  static $pb.GeneratedMessage $_createMessage() => AddBookmarkResponse._();
  @$core.override
  AddBookmarkResponse createEmptyInstance() => AddBookmarkResponse._();
  @$core.pragma('dart2js:noInline')
  static AddBookmarkResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<AddBookmarkResponse>(
          AddBookmarkResponse.$_createMessage);
  static AddBookmarkResponse? _defaultInstance;

  @$pb.TagNumber(1)
  BookmarkState get state => $_getN(0);
  @$pb.TagNumber(1)
  set state(BookmarkState value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasState() => $_has(0);
  @$pb.TagNumber(1)
  void clearState() => $_clearField(1);
  @$pb.TagNumber(1)
  BookmarkState ensureState() => $_ensure(0);
}

class RemoveBookmarkRequest extends $pb.GeneratedMessage {
  factory RemoveBookmarkRequest({
    $core.String? idempotencyKey,
    $core.String? postId,
  }) {
    final result = RemoveBookmarkRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (postId != null) result.postId = postId;
    return result;
  }

  RemoveBookmarkRequest._();

  factory RemoveBookmarkRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RemoveBookmarkRequest()..mergeFromBuffer(data, registry);
  factory RemoveBookmarkRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RemoveBookmarkRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RemoveBookmarkRequest',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.engagement.v1'),
      createEmptyInstance: RemoveBookmarkRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'postId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RemoveBookmarkRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RemoveBookmarkRequest copyWith(
          void Function(RemoveBookmarkRequest) updates) =>
      super.copyWith((message) => updates(message as RemoveBookmarkRequest))
          as RemoveBookmarkRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use RemoveBookmarkRequest() / RemoveBookmarkRequest.new instead')
  static RemoveBookmarkRequest create() => RemoveBookmarkRequest._();
  static $pb.GeneratedMessage $_createMessage() => RemoveBookmarkRequest._();
  @$core.override
  RemoveBookmarkRequest createEmptyInstance() => RemoveBookmarkRequest._();
  @$core.pragma('dart2js:noInline')
  static RemoveBookmarkRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<RemoveBookmarkRequest>(
          RemoveBookmarkRequest.$_createMessage);
  static RemoveBookmarkRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  /// The original post id (BookmarkState.post_id), never a REPOST id.
  @$pb.TagNumber(2)
  $core.String get postId => $_getSZ(1);
  @$pb.TagNumber(2)
  set postId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasPostId() => $_has(1);
  @$pb.TagNumber(2)
  void clearPostId() => $_clearField(2);
}

class RemoveBookmarkResponse extends $pb.GeneratedMessage {
  factory RemoveBookmarkResponse({
    BookmarkState? state,
  }) {
    final result = RemoveBookmarkResponse._();
    if (state != null) result.state = state;
    return result;
  }

  RemoveBookmarkResponse._();

  factory RemoveBookmarkResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RemoveBookmarkResponse()..mergeFromBuffer(data, registry);
  factory RemoveBookmarkResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RemoveBookmarkResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RemoveBookmarkResponse',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.engagement.v1'),
      createEmptyInstance: RemoveBookmarkResponse.$_createMessage)
    ..aOM<BookmarkState>(1, _omitFieldNames ? '' : 'state',
        subBuilder: BookmarkState.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RemoveBookmarkResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RemoveBookmarkResponse copyWith(
          void Function(RemoveBookmarkResponse) updates) =>
      super.copyWith((message) => updates(message as RemoveBookmarkResponse))
          as RemoveBookmarkResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use RemoveBookmarkResponse() / RemoveBookmarkResponse.new instead')
  static RemoveBookmarkResponse create() => RemoveBookmarkResponse._();
  static $pb.GeneratedMessage $_createMessage() => RemoveBookmarkResponse._();
  @$core.override
  RemoveBookmarkResponse createEmptyInstance() => RemoveBookmarkResponse._();
  @$core.pragma('dart2js:noInline')
  static RemoveBookmarkResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<RemoveBookmarkResponse>(
          RemoveBookmarkResponse.$_createMessage);
  static RemoveBookmarkResponse? _defaultInstance;

  @$pb.TagNumber(1)
  BookmarkState get state => $_getN(0);
  @$pb.TagNumber(1)
  set state(BookmarkState value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasState() => $_has(0);
  @$pb.TagNumber(1)
  void clearState() => $_clearField(1);
  @$pb.TagNumber(1)
  BookmarkState ensureState() => $_ensure(0);
}

class ListBookmarksRequest extends $pb.GeneratedMessage {
  factory ListBookmarksRequest({
    $core.int? pageSize,
    $core.String? pageToken,
  }) {
    final result = ListBookmarksRequest._();
    if (pageSize != null) result.pageSize = pageSize;
    if (pageToken != null) result.pageToken = pageToken;
    return result;
  }

  ListBookmarksRequest._();

  factory ListBookmarksRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListBookmarksRequest()..mergeFromBuffer(data, registry);
  factory ListBookmarksRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListBookmarksRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListBookmarksRequest',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.engagement.v1'),
      createEmptyInstance: ListBookmarksRequest.$_createMessage)
    ..aI(1, _omitFieldNames ? '' : 'pageSize')
    ..aOS(2, _omitFieldNames ? '' : 'pageToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListBookmarksRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListBookmarksRequest copyWith(void Function(ListBookmarksRequest) updates) =>
      super.copyWith((message) => updates(message as ListBookmarksRequest))
          as ListBookmarksRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ListBookmarksRequest() / ListBookmarksRequest.new instead')
  static ListBookmarksRequest create() => ListBookmarksRequest._();
  static $pb.GeneratedMessage $_createMessage() => ListBookmarksRequest._();
  @$core.override
  ListBookmarksRequest createEmptyInstance() => ListBookmarksRequest._();
  @$core.pragma('dart2js:noInline')
  static ListBookmarksRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListBookmarksRequest>(
          ListBookmarksRequest.$_createMessage);
  static ListBookmarksRequest? _defaultInstance;

  /// 0 => 20, max 50 (clamped).
  @$pb.TagNumber(1)
  $core.int get pageSize => $_getIZ(0);
  @$pb.TagNumber(1)
  set pageSize($core.int value) => $_setSignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasPageSize() => $_has(0);
  @$pb.TagNumber(1)
  void clearPageSize() => $_clearField(1);

  /// Opaque, bound to the caller. Empty => the first page (most recently bookmarked).
  @$pb.TagNumber(2)
  $core.String get pageToken => $_getSZ(1);
  @$pb.TagNumber(2)
  set pageToken($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasPageToken() => $_has(1);
  @$pb.TagNumber(2)
  void clearPageToken() => $_clearField(2);
}

/// One saved post as the caller sees it now.
class Bookmark extends $pb.GeneratedMessage {
  factory Bookmark({
    $0.PostView? post,
    $1.Timestamp? bookmarkedAt,
  }) {
    final result = Bookmark._();
    if (post != null) result.post = post;
    if (bookmarkedAt != null) result.bookmarkedAt = bookmarkedAt;
    return result;
  }

  Bookmark._();

  factory Bookmark.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Bookmark()..mergeFromBuffer(data, registry);
  factory Bookmark.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Bookmark()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Bookmark',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.engagement.v1'),
      createEmptyInstance: Bookmark.$_createMessage)
    ..aOM<$0.PostView>(1, _omitFieldNames ? '' : 'post',
        subBuilder: $0.PostView.$_createMessage)
    ..aOM<$1.Timestamp>(2, _omitFieldNames ? '' : 'bookmarkedAt',
        subBuilder: $1.Timestamp.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Bookmark clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Bookmark copyWith(void Function(Bookmark) updates) =>
      super.copyWith((message) => updates(message as Bookmark)) as Bookmark;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Bookmark() / Bookmark.new instead')
  static Bookmark create() => Bookmark._();
  static $pb.GeneratedMessage $_createMessage() => Bookmark._();
  @$core.override
  Bookmark createEmptyInstance() => Bookmark._();
  @$core.pragma('dart2js:noInline')
  static Bookmark getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Bookmark>(Bookmark.$_createMessage);
  static Bookmark? _defaultInstance;

  /// The live post (never a stored copy), with the caller's viewer flags.
  @$pb.TagNumber(1)
  $0.PostView get post => $_getN(0);
  @$pb.TagNumber(1)
  set post($0.PostView value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasPost() => $_has(0);
  @$pb.TagNumber(1)
  void clearPost() => $_clearField(1);
  @$pb.TagNumber(1)
  $0.PostView ensurePost() => $_ensure(0);

  /// When the caller bookmarked it (server time); the list order.
  @$pb.TagNumber(2)
  $1.Timestamp get bookmarkedAt => $_getN(1);
  @$pb.TagNumber(2)
  set bookmarkedAt($1.Timestamp value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasBookmarkedAt() => $_has(1);
  @$pb.TagNumber(2)
  void clearBookmarkedAt() => $_clearField(2);
  @$pb.TagNumber(2)
  $1.Timestamp ensureBookmarkedAt() => $_ensure(1);
}

class ListBookmarksResponse extends $pb.GeneratedMessage {
  factory ListBookmarksResponse({
    $core.Iterable<Bookmark>? bookmarks,
    $core.String? nextPageToken,
  }) {
    final result = ListBookmarksResponse._();
    if (bookmarks != null) result.bookmarks.addAll(bookmarks);
    if (nextPageToken != null) result.nextPageToken = nextPageToken;
    return result;
  }

  ListBookmarksResponse._();

  factory ListBookmarksResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListBookmarksResponse()..mergeFromBuffer(data, registry);
  factory ListBookmarksResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListBookmarksResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListBookmarksResponse',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.engagement.v1'),
      createEmptyInstance: ListBookmarksResponse.$_createMessage)
    ..pPM<Bookmark>(1, _omitFieldNames ? '' : 'bookmarks',
        subBuilder: Bookmark.$_createMessage)
    ..aOS(2, _omitFieldNames ? '' : 'nextPageToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListBookmarksResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListBookmarksResponse copyWith(
          void Function(ListBookmarksResponse) updates) =>
      super.copyWith((message) => updates(message as ListBookmarksResponse))
          as ListBookmarksResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ListBookmarksResponse() / ListBookmarksResponse.new instead')
  static ListBookmarksResponse create() => ListBookmarksResponse._();
  static $pb.GeneratedMessage $_createMessage() => ListBookmarksResponse._();
  @$core.override
  ListBookmarksResponse createEmptyInstance() => ListBookmarksResponse._();
  @$core.pragma('dart2js:noInline')
  static ListBookmarksResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListBookmarksResponse>(
          ListBookmarksResponse.$_createMessage);
  static ListBookmarksResponse? _defaultInstance;

  /// Most recently bookmarked first. May be shorter than page_size (rows dropped after the read, see ListBookmarks).
  @$pb.TagNumber(1)
  $pb.PbList<Bookmark> get bookmarks => $_getList(0);

  /// "" => no more bookmarks.
  @$pb.TagNumber(2)
  $core.String get nextPageToken => $_getSZ(1);
  @$pb.TagNumber(2)
  set nextPageToken($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasNextPageToken() => $_has(1);
  @$pb.TagNumber(2)
  void clearNextPageToken() => $_clearField(2);
}

class ListLikedPostsRequest extends $pb.GeneratedMessage {
  factory ListLikedPostsRequest({
    $core.int? pageSize,
    $core.String? pageToken,
  }) {
    final result = ListLikedPostsRequest._();
    if (pageSize != null) result.pageSize = pageSize;
    if (pageToken != null) result.pageToken = pageToken;
    return result;
  }

  ListLikedPostsRequest._();

  factory ListLikedPostsRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListLikedPostsRequest()..mergeFromBuffer(data, registry);
  factory ListLikedPostsRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListLikedPostsRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListLikedPostsRequest',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.engagement.v1'),
      createEmptyInstance: ListLikedPostsRequest.$_createMessage)
    ..aI(1, _omitFieldNames ? '' : 'pageSize')
    ..aOS(2, _omitFieldNames ? '' : 'pageToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListLikedPostsRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListLikedPostsRequest copyWith(
          void Function(ListLikedPostsRequest) updates) =>
      super.copyWith((message) => updates(message as ListLikedPostsRequest))
          as ListLikedPostsRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ListLikedPostsRequest() / ListLikedPostsRequest.new instead')
  static ListLikedPostsRequest create() => ListLikedPostsRequest._();
  static $pb.GeneratedMessage $_createMessage() => ListLikedPostsRequest._();
  @$core.override
  ListLikedPostsRequest createEmptyInstance() => ListLikedPostsRequest._();
  @$core.pragma('dart2js:noInline')
  static ListLikedPostsRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListLikedPostsRequest>(
          ListLikedPostsRequest.$_createMessage);
  static ListLikedPostsRequest? _defaultInstance;

  /// 0 => 20, max 50 (clamped).
  @$pb.TagNumber(1)
  $core.int get pageSize => $_getIZ(0);
  @$pb.TagNumber(1)
  set pageSize($core.int value) => $_setSignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasPageSize() => $_has(0);
  @$pb.TagNumber(1)
  void clearPageSize() => $_clearField(1);

  /// Opaque, bound to the caller, 24 h TTL. Empty => the first page (most recently liked).
  @$pb.TagNumber(2)
  $core.String get pageToken => $_getSZ(1);
  @$pb.TagNumber(2)
  set pageToken($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasPageToken() => $_has(1);
  @$pb.TagNumber(2)
  void clearPageToken() => $_clearField(2);
}

class ListLikedPostsResponse extends $pb.GeneratedMessage {
  factory ListLikedPostsResponse({
    $core.Iterable<$0.PostView>? posts,
    $core.String? nextPageToken,
  }) {
    final result = ListLikedPostsResponse._();
    if (posts != null) result.posts.addAll(posts);
    if (nextPageToken != null) result.nextPageToken = nextPageToken;
    return result;
  }

  ListLikedPostsResponse._();

  factory ListLikedPostsResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListLikedPostsResponse()..mergeFromBuffer(data, registry);
  factory ListLikedPostsResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListLikedPostsResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListLikedPostsResponse',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.engagement.v1'),
      createEmptyInstance: ListLikedPostsResponse.$_createMessage)
    ..pPM<$0.PostView>(1, _omitFieldNames ? '' : 'posts',
        subBuilder: $0.PostView.$_createMessage)
    ..aOS(2, _omitFieldNames ? '' : 'nextPageToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListLikedPostsResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListLikedPostsResponse copyWith(
          void Function(ListLikedPostsResponse) updates) =>
      super.copyWith((message) => updates(message as ListLikedPostsResponse))
          as ListLikedPostsResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ListLikedPostsResponse() / ListLikedPostsResponse.new instead')
  static ListLikedPostsResponse create() => ListLikedPostsResponse._();
  static $pb.GeneratedMessage $_createMessage() => ListLikedPostsResponse._();
  @$core.override
  ListLikedPostsResponse createEmptyInstance() => ListLikedPostsResponse._();
  @$core.pragma('dart2js:noInline')
  static ListLikedPostsResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListLikedPostsResponse>(
          ListLikedPostsResponse.$_createMessage);
  static ListLikedPostsResponse? _defaultInstance;

  /// Most recently liked first; the live posts with the caller's viewer flags. May be shorter than page_size (rows
  /// dropped after the read, see ListLikedPosts).
  @$pb.TagNumber(1)
  $pb.PbList<$0.PostView> get posts => $_getList(0);

  /// "" => no more likes.
  @$pb.TagNumber(2)
  $core.String get nextPageToken => $_getSZ(1);
  @$pb.TagNumber(2)
  set nextPageToken($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasNextPageToken() => $_has(1);
  @$pb.TagNumber(2)
  void clearNextPageToken() => $_clearField(2);
}

class EngagementServiceApi {
  final $pb.RpcClient _client;

  EngagementServiceApi(this._client);

  /// Like a post. Idempotent: liking a liked post succeeds with 0 writes. Quota: 500 likes/day/user (100 for
  /// accounts younger than 24 h), RESOURCE_EXHAUSTED + QUOTA_EXCEEDED metadata["quota"]="likes". Per-user bucket
  /// RATE_LIMIT_LIKES_PER_MIN (30/min).
  /// One transaction: reads quotas/{uid}; writes likes/{id} (Create; AlreadyExists at commit is the replay),
  /// posts/{id}.likeCount (Increment), userLikes/{uid} (ArrayUnion; trimmed to the newest 1,000 by a separate
  /// best-effort write) and quotas/{uid}.
  /// Firestore: reads 1 in the transaction (+ the visibility check: post, author users, caller graph = 3 cold /
  /// 0 warm, + the account-status interceptor's users read; +2 when post_id is a REPOST), writes 4. Replay: same
  /// reads, 0 writes.
  $async.Future<LikePostResponse> likePost(
          $pb.ClientContext? ctx, LikePostRequest request) =>
      _client.invoke<LikePostResponse>(
          ctx, 'EngagementService', 'LikePost', request, LikePostResponse());

  /// Remove a like. Idempotent: not liked => success with 0 writes. Needs no visibility check (a user can always
  /// retract), so a post that became invisible or was deleted can still be unliked.
  /// One batch: Delete likes/{id} (Exists precondition), posts/{id}.likeCount (Increment -1, skipped when the post
  /// is gone) and userLikes/{uid} (ArrayRemove). Firestore: reads <= 1 (the post for the returned counts, cache
  /// first, +1 when post_id is a REPOST), writes 2 + 1 delete; a no-op writes 0.
  $async.Future<UnlikePostResponse> unlikePost(
          $pb.ClientContext? ctx, UnlikePostRequest request) =>
      _client.invoke<UnlikePostResponse>(ctx, 'EngagementService', 'UnlikePost',
          request, UnlikePostResponse());

  /// Repost a post: creates reposts/{postId}_{uid} and a posts doc with kind REPOST, an embedded snapshot of the
  /// original, authored by the caller (it appears in the caller's profile and in followers' home timelines like
  /// any root post, and is removed by DeletePost or UndoRepost). Reposting a post you already reposted succeeds and
  /// returns the existing repost (0 writes). A repost of a REPOST resolves to the original. Counts toward the posts
  /// quota (100/day, 20 for new accounts) and users.postsCount.
  /// One transaction: reads quotas/{uid}; writes reposts/{id}, posts/{newId}, posts/{id}.repostCount,
  /// users/{uid}.postsCount, userLikes/{uid}.recentReposts and quotas/{uid}. Firestore: reads 1 in the transaction
  /// (+ visibility check 3 cold / 0 warm, + interceptor; +2 when post_id is a REPOST), writes 6. Replay: +1 read
  /// (reposts/{id}), 0 writes.
  $async.Future<RepostPostResponse> repostPost(
          $pb.ClientContext? ctx, RepostPostRequest request) =>
      _client.invoke<RepostPostResponse>(ctx, 'EngagementService', 'RepostPost',
          request, RepostPostResponse());

  /// Undo a repost. post_id is the ORIGINAL post (use embedded.post_id of a REPOST item). Idempotent: not
  /// reposted => success with 0 writes. One read of reposts/{id}, then one batch: deletes reposts/{id} (Exists
  /// precondition) and the REPOST post doc, decrements the original's repostCount (skipped when it is gone) and
  /// users.postsCount, ArrayRemove on userLikes.recentReposts. Firestore: reads 1 (+ the original for the returned
  /// counts, cache first), writes 3 + 2 deletes.
  $async.Future<UndoRepostResponse> undoRepost(
          $pb.ClientContext? ctx, UndoRepostRequest request) =>
      _client.invoke<UndoRepostResponse>(ctx, 'EngagementService', 'UndoRepost',
          request, UndoRepostResponse());

  /// Bookmark a post. A REPOST id bookmarks its original (the returned post_id). The post must be visible to the
  /// caller by the GetPost rules (missing, deleted, hidden, suspended or blocking author, or a QUOTE whose embedded
  /// author blocks the caller => NOT_FOUND "post not found", 0 writes).
  /// Idempotency (rule 4): idempotency/{hash(uid, "AddBookmark", key)} is stored in the same transaction (TTL'd); a
  /// replay returns the stored state with 0 writes even if the bookmark was removed since, and a different post_id
  /// under the same key => INVALID_ARGUMENT + IDEMPOTENCY_KEY_REUSED. Bookmarking an already bookmarked post with a
  /// fresh key succeeds with 1 write, the idempotency doc, so a late retry replays (bookmarked_at is unchanged).
  /// Caps: at most BOOKMARKS_MAX_PER_USER bookmarks (1,000; exact: counted from userLikes/{uid}.bookmarks read inside
  /// the transaction) => FAILED_PRECONDITION + LIMIT_REACHED metadata["limit"] = "bookmarks"; QUOTA_BOOKMARKS_PER_DAY
  /// adds per IST day (200; 50 for accounts younger than 24 h) => RESOURCE_EXHAUSTED + QUOTA_EXCEEDED
  /// metadata["quota"] = "bookmarks". A replay or an already bookmarked post is not charged.
  /// One transaction: reads idempotency, quotas and userLikes fresh; Create users/{uid}/bookmarks/{postId}, Create
  /// the idempotency doc, set quotas/{uid}.bookmarks, ArrayUnion userLikes/{uid}.bookmarks (the complete set of the
  /// caller's bookmarked post ids, which hydrates viewer state with no extra read; ADR-0023 D3).
  /// Firestore: reads 7 cold / 3 warm, planning 4 (interceptor 1, visibility check post + author users + caller graph
  /// 3 cold / 0 warm, idempotency 1, quotas 1, userLikes 1; +2 when post_id is a REPOST, +1 on blockedBy overflow);
  /// writes 4 (bookmark, idempotency, quotas, userLikes) + 1 TTL delete later. Replay: reads 5 cold / 1 warm, writes
  /// 0. Already bookmarked: writes 1 (idempotency). At the cap or at the quota: writes 0.
  $async.Future<AddBookmarkResponse> addBookmark(
          $pb.ClientContext? ctx, AddBookmarkRequest request) =>
      _client.invoke<AddBookmarkResponse>(ctx, 'EngagementService',
          'AddBookmark', request, AddBookmarkResponse());

  /// Remove a bookmark. post_id is the id AddBookmark returned (the original for a REPOST; a REPOST id here is a
  /// no-op). Needs no visibility check: a user can always remove a bookmark of a post that was deleted or became
  /// invisible. Not charged to a daily quota. Idempotent: not bookmarked => success with 1 write (the idempotency doc).
  /// Idempotency (rule 4): as AddBookmark ("RemoveBookmark" in the hash); a replay returns the stored state with 0
  /// writes, so a late retry never removes a bookmark that was added again after it.
  /// One transaction: reads idempotency; Delete users/{uid}/bookmarks/{postId} (Exists precondition), Create the
  /// idempotency doc and ArrayRemove userLikes/{uid}.bookmarks; a failed Exists is the no-op (1 write: idempotency).
  /// Firestore: reads 2 cold / 1 warm (interceptor, idempotency); writes 2 (idempotency, userLikes) + 1 delete + 1
  /// TTL delete later; a no-op writes 1 (idempotency), a replay 0.
  $async.Future<RemoveBookmarkResponse> removeBookmark(
          $pb.ClientContext? ctx, RemoveBookmarkRequest request) =>
      _client.invoke<RemoveBookmarkResponse>(ctx, 'EngagementService',
          'RemoveBookmark', request, RemoveBookmarkResponse());

  /// The caller's bookmarks, most recently bookmarked first, each rendered from the LIVE post (current text, author
  /// snapshot and counts; viewer flags as in timelines). page_size 0 => 20, clamped to 1..50. Opaque page_token
  /// bound to the caller (cursor (bookmarkedAt, postId)); expired, foreign or tampered => INVALID_ARGUMENT +
  /// VALIDATION metadata["field"] = "page_token", 0 reads: drop it and reload the first page.
  /// Client contract: there is no since_token and no removed_ids. On every open, REPLACE the cached first page with
  /// the response, then scroll with next_page_token.
  /// Rows are dropped after the read (ADR-0023 D2): the post is missing (deleted, or its author's account was
  /// purged), hidden by a moderator (takedown or author suspension), or its author (or a QUOTE's embedded author) is
  /// blocked by, blocks, or is muted by the caller (the ADR-0010 D6 Home column). A page may therefore be short or
  /// empty while next_page_token is non-empty: keep following it while it is non-empty. A post whose author is
  /// DELETING is shown until the purge deletes it, as in Home.
  /// A row whose post no longer exists is pruned (its bookmark doc deleted and its id removed from
  /// userLikes.bookmarks, best effort, once); hidden and blocked rows are kept, because a restore or an unblock
  /// brings them back. No pruning under DEGRADED_MODE=readonly.
  /// Firestore: reads 1 + page + <= page + 2 cold (interceptor, the bookmarks query, one posts GetMany cache-first,
  /// caller graph, userLikes for viewer flags; graph and userLikes cached 60 s): 43 at page 20, 103 at page 50; an
  /// empty list 2. Warm (posts in the instance cache) 1 + page. Writes 0, plus, on a page that prunes, 1 write
  /// (userLikes ArrayRemove) and 1 delete per pruned row (a deleted post's bookmark is pruned once).
  $async.Future<ListBookmarksResponse> listBookmarks(
          $pb.ClientContext? ctx, ListBookmarksRequest request) =>
      _client.invoke<ListBookmarksResponse>(ctx, 'EngagementService',
          'ListBookmarks', request, ListBookmarksResponse());

  /// The caller's own likes, most recently liked first (ADR-0024 D6). OWNER-ONLY: the request has no user id and
  /// must never get one; the source is userLikes/{caller}.recent (the newest 1,000 likes, read through engagement's
  /// 60 s cache), so nobody can list another user's likes. Likes older than the newest 1,000 are not listed, and there
  /// is no liked-at time (recent[] stores none). Each row is the LIVE post (one cache-first posts GetMany of the
  /// page's ids) with viewer flags from the same userLikes read (0 extra reads).
  /// Needs FEATURE_LIKES_LIST (wire name "likes_list") on for the caller, and FEATURE_POSTS; it does not need
  /// FEATURE_ENGAGEMENT (it lists likes made while that was on). Otherwise FAILED_PRECONDITION + FEATURE_DISABLED,
  /// metadata["feature"] = "likes_list", 0 reads. Rate limit: RATE_LIMIT_LIKES_LIST_PER_MIN, 10/min/uid per instance
  /// (at most 30/min with 3 instances). Charged to the per-uid daily read budget (ADR-0010 D5).
  /// Rows are dropped after the read, as in ListBookmarks: the post is missing, hidden by a moderator, or its author
  /// (or a QUOTE's or REPOST's embedded author) is blocked by, blocks, or is muted by the caller. Nothing is pruned
  /// (the like path owns recent[]), so a page may be short or empty while next_page_token is non-empty: keep
  /// following it while it is non-empty.
  /// page_size 0 => 20, clamped to 1..50. page_token is opaque, bound to the caller ("likes" feed), 24 h TTL; it
  /// resumes by post id (the next and last returned ids, then an offset from the newest end), so an unlike, re-like
  /// or trim between pages skips or repeats nothing beyond the rows changed at the page boundary. Expired, foreign or
  /// tampered => INVALID_ARGUMENT + VALIDATION, metadata["field"] = "page_token", 0 reads: reload the first page.
  /// Client contract: no since_token, no removed_ids; on every open REPLACE the cached first page.
  /// Firestore: reads 23 cold at page 20 / 53 at page 50 (interceptor 1, userLikes 1, GetMany <= page, caller graph
  /// 1); warm (posts cached) 20 / 50, planning 22; an empty recent[] 2. Writes 0.
  $async.Future<ListLikedPostsResponse> listLikedPosts(
          $pb.ClientContext? ctx, ListLikedPostsRequest request) =>
      _client.invoke<ListLikedPostsResponse>(ctx, 'EngagementService',
          'ListLikedPosts', request, ListLikedPostsResponse());
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
