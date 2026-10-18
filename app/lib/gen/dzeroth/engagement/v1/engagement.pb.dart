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
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
