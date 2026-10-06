// This is a generated file - do not edit.
//
// Generated from dzeroth/posts/v1/posts.proto.

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

import '../../common/v1/common.pb.dart' as $0;
import 'posts.pbenum.dart';

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

export 'posts.pbenum.dart';

class Mention extends $pb.GeneratedMessage {
  factory Mention({
    $core.String? userId,
    $core.String? handle,
  }) {
    final result = Mention._();
    if (userId != null) result.userId = userId;
    if (handle != null) result.handle = handle;
    return result;
  }

  Mention._();

  factory Mention.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Mention()..mergeFromBuffer(data, registry);
  factory Mention.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Mention()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Mention',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.posts.v1'),
      createEmptyInstance: Mention.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'userId')
    ..aOS(2, _omitFieldNames ? '' : 'handle')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Mention clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Mention copyWith(void Function(Mention) updates) =>
      super.copyWith((message) => updates(message as Mention)) as Mention;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Mention() / Mention.new instead')
  static Mention create() => Mention._();
  static $pb.GeneratedMessage $_createMessage() => Mention._();
  @$core.override
  Mention createEmptyInstance() => Mention._();
  @$core.pragma('dart2js:noInline')
  static Mention getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Mention>(Mention.$_createMessage);
  static Mention? _defaultInstance;

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
}

/// A one-level, denormalized copy of another post (quoted or reposted), frozen at write time.
/// Cleared by the post-delete job when the original is deleted.
class EmbeddedPost extends $pb.GeneratedMessage {
  factory EmbeddedPost({
    $core.String? postId,
    $0.AuthorSnapshot? author,
    $core.String? text,
    $core.Iterable<$0.MediaRef>? media,
    $1.Timestamp? createdAt,
    $core.bool? unavailable,
  }) {
    final result = EmbeddedPost._();
    if (postId != null) result.postId = postId;
    if (author != null) result.author = author;
    if (text != null) result.text = text;
    if (media != null) result.media.addAll(media);
    if (createdAt != null) result.createdAt = createdAt;
    if (unavailable != null) result.unavailable = unavailable;
    return result;
  }

  EmbeddedPost._();

  factory EmbeddedPost.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      EmbeddedPost()..mergeFromBuffer(data, registry);
  factory EmbeddedPost.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      EmbeddedPost()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'EmbeddedPost',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.posts.v1'),
      createEmptyInstance: EmbeddedPost.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'postId')
    ..aOM<$0.AuthorSnapshot>(2, _omitFieldNames ? '' : 'author',
        subBuilder: $0.AuthorSnapshot.$_createMessage)
    ..aOS(3, _omitFieldNames ? '' : 'text')
    ..pPM<$0.MediaRef>(4, _omitFieldNames ? '' : 'media',
        subBuilder: $0.MediaRef.$_createMessage)
    ..aOM<$1.Timestamp>(5, _omitFieldNames ? '' : 'createdAt',
        subBuilder: $1.Timestamp.$_createMessage)
    ..aOB(6, _omitFieldNames ? '' : 'unavailable')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  EmbeddedPost clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  EmbeddedPost copyWith(void Function(EmbeddedPost) updates) =>
      super.copyWith((message) => updates(message as EmbeddedPost))
          as EmbeddedPost;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use EmbeddedPost() / EmbeddedPost.new instead')
  static EmbeddedPost create() => EmbeddedPost._();
  static $pb.GeneratedMessage $_createMessage() => EmbeddedPost._();
  @$core.override
  EmbeddedPost createEmptyInstance() => EmbeddedPost._();
  @$core.pragma('dart2js:noInline')
  static EmbeddedPost getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<EmbeddedPost>(
          EmbeddedPost.$_createMessage);
  static EmbeddedPost? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get postId => $_getSZ(0);
  @$pb.TagNumber(1)
  set postId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasPostId() => $_has(0);
  @$pb.TagNumber(1)
  void clearPostId() => $_clearField(1);

  @$pb.TagNumber(2)
  $0.AuthorSnapshot get author => $_getN(1);
  @$pb.TagNumber(2)
  set author($0.AuthorSnapshot value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasAuthor() => $_has(1);
  @$pb.TagNumber(2)
  void clearAuthor() => $_clearField(2);
  @$pb.TagNumber(2)
  $0.AuthorSnapshot ensureAuthor() => $_ensure(1);

  @$pb.TagNumber(3)
  $core.String get text => $_getSZ(2);
  @$pb.TagNumber(3)
  set text($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasText() => $_has(2);
  @$pb.TagNumber(3)
  void clearText() => $_clearField(3);

  @$pb.TagNumber(4)
  $pb.PbList<$0.MediaRef> get media => $_getList(3);

  @$pb.TagNumber(5)
  $1.Timestamp get createdAt => $_getN(4);
  @$pb.TagNumber(5)
  set createdAt($1.Timestamp value) => $_setField(5, value);
  @$pb.TagNumber(5)
  $core.bool hasCreatedAt() => $_has(4);
  @$pb.TagNumber(5)
  void clearCreatedAt() => $_clearField(5);
  @$pb.TagNumber(5)
  $1.Timestamp ensureCreatedAt() => $_ensure(4);

  /// True when the original was deleted or became invisible; render a tombstone.
  @$pb.TagNumber(6)
  $core.bool get unavailable => $_getBF(5);
  @$pb.TagNumber(6)
  set unavailable($core.bool value) => $_setBool(5, value);
  @$pb.TagNumber(6)
  $core.bool hasUnavailable() => $_has(5);
  @$pb.TagNumber(6)
  void clearUnavailable() => $_clearField(6);
}

class Post extends $pb.GeneratedMessage {
  factory Post({
    $core.String? postId,
    $0.AuthorSnapshot? author,
    PostKind? kind,
    $core.String? text,
    $core.Iterable<$0.MediaRef>? media,
    $core.String? replyToPostId,
    $core.String? replyToHandle,
    $core.String? conversationId,
    EmbeddedPost? embedded,
    $core.Iterable<$core.String>? hashtags,
    $core.Iterable<Mention>? mentions,
    $fixnum.Int64? likeCount,
    $fixnum.Int64? repostCount,
    $fixnum.Int64? replyCount,
    $fixnum.Int64? quoteCount,
    Visibility? visibility,
    $1.Timestamp? createdAt,
  }) {
    final result = Post._();
    if (postId != null) result.postId = postId;
    if (author != null) result.author = author;
    if (kind != null) result.kind = kind;
    if (text != null) result.text = text;
    if (media != null) result.media.addAll(media);
    if (replyToPostId != null) result.replyToPostId = replyToPostId;
    if (replyToHandle != null) result.replyToHandle = replyToHandle;
    if (conversationId != null) result.conversationId = conversationId;
    if (embedded != null) result.embedded = embedded;
    if (hashtags != null) result.hashtags.addAll(hashtags);
    if (mentions != null) result.mentions.addAll(mentions);
    if (likeCount != null) result.likeCount = likeCount;
    if (repostCount != null) result.repostCount = repostCount;
    if (replyCount != null) result.replyCount = replyCount;
    if (quoteCount != null) result.quoteCount = quoteCount;
    if (visibility != null) result.visibility = visibility;
    if (createdAt != null) result.createdAt = createdAt;
    return result;
  }

  Post._();

  factory Post.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Post()..mergeFromBuffer(data, registry);
  factory Post.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Post()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Post',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.posts.v1'),
      createEmptyInstance: Post.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'postId')
    ..aOM<$0.AuthorSnapshot>(2, _omitFieldNames ? '' : 'author',
        subBuilder: $0.AuthorSnapshot.$_createMessage)
    ..aE<PostKind>(3, _omitFieldNames ? '' : 'kind',
        enumValues: PostKind.values)
    ..aOS(4, _omitFieldNames ? '' : 'text')
    ..pPM<$0.MediaRef>(5, _omitFieldNames ? '' : 'media',
        subBuilder: $0.MediaRef.$_createMessage)
    ..aOS(6, _omitFieldNames ? '' : 'replyToPostId')
    ..aOS(7, _omitFieldNames ? '' : 'replyToHandle')
    ..aOS(8, _omitFieldNames ? '' : 'conversationId')
    ..aOM<EmbeddedPost>(9, _omitFieldNames ? '' : 'embedded',
        subBuilder: EmbeddedPost.$_createMessage)
    ..pPS(10, _omitFieldNames ? '' : 'hashtags')
    ..pPM<Mention>(11, _omitFieldNames ? '' : 'mentions',
        subBuilder: Mention.$_createMessage)
    ..aInt64(12, _omitFieldNames ? '' : 'likeCount')
    ..aInt64(13, _omitFieldNames ? '' : 'repostCount')
    ..aInt64(14, _omitFieldNames ? '' : 'replyCount')
    ..aInt64(15, _omitFieldNames ? '' : 'quoteCount')
    ..aE<Visibility>(16, _omitFieldNames ? '' : 'visibility',
        enumValues: Visibility.values)
    ..aOM<$1.Timestamp>(17, _omitFieldNames ? '' : 'createdAt',
        subBuilder: $1.Timestamp.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Post clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Post copyWith(void Function(Post) updates) =>
      super.copyWith((message) => updates(message as Post)) as Post;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Post() / Post.new instead')
  static Post create() => Post._();
  static $pb.GeneratedMessage $_createMessage() => Post._();
  @$core.override
  Post createEmptyInstance() => Post._();
  @$core.pragma('dart2js:noInline')
  static Post getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Post>(Post.$_createMessage);
  static Post? _defaultInstance;

  /// Snowflake, 19-digit zero-padded decimal.
  @$pb.TagNumber(1)
  $core.String get postId => $_getSZ(0);
  @$pb.TagNumber(1)
  set postId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasPostId() => $_has(0);
  @$pb.TagNumber(1)
  void clearPostId() => $_clearField(1);

  @$pb.TagNumber(2)
  $0.AuthorSnapshot get author => $_getN(1);
  @$pb.TagNumber(2)
  set author($0.AuthorSnapshot value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasAuthor() => $_has(1);
  @$pb.TagNumber(2)
  void clearAuthor() => $_clearField(2);
  @$pb.TagNumber(2)
  $0.AuthorSnapshot ensureAuthor() => $_ensure(1);

  @$pb.TagNumber(3)
  PostKind get kind => $_getN(2);
  @$pb.TagNumber(3)
  set kind(PostKind value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasKind() => $_has(2);
  @$pb.TagNumber(3)
  void clearKind() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.String get text => $_getSZ(3);
  @$pb.TagNumber(4)
  set text($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasText() => $_has(3);
  @$pb.TagNumber(4)
  void clearText() => $_clearField(4);

  @$pb.TagNumber(5)
  $pb.PbList<$0.MediaRef> get media => $_getList(4);

  /// Set for replies.
  @$pb.TagNumber(6)
  $core.String get replyToPostId => $_getSZ(5);
  @$pb.TagNumber(6)
  set replyToPostId($core.String value) => $_setString(5, value);
  @$pb.TagNumber(6)
  $core.bool hasReplyToPostId() => $_has(5);
  @$pb.TagNumber(6)
  void clearReplyToPostId() => $_clearField(6);

  /// Set for replies, for "Replying to @handle" without an extra read.
  @$pb.TagNumber(7)
  $core.String get replyToHandle => $_getSZ(6);
  @$pb.TagNumber(7)
  set replyToHandle($core.String value) => $_setString(6, value);
  @$pb.TagNumber(7)
  $core.bool hasReplyToHandle() => $_has(6);
  @$pb.TagNumber(7)
  void clearReplyToHandle() => $_clearField(7);

  /// Root post id of the thread (== post_id for roots).
  @$pb.TagNumber(8)
  $core.String get conversationId => $_getSZ(7);
  @$pb.TagNumber(8)
  set conversationId($core.String value) => $_setString(7, value);
  @$pb.TagNumber(8)
  $core.bool hasConversationId() => $_has(7);
  @$pb.TagNumber(8)
  void clearConversationId() => $_clearField(8);

  /// Set for QUOTE and REPOST.
  @$pb.TagNumber(9)
  EmbeddedPost get embedded => $_getN(8);
  @$pb.TagNumber(9)
  set embedded(EmbeddedPost value) => $_setField(9, value);
  @$pb.TagNumber(9)
  $core.bool hasEmbedded() => $_has(8);
  @$pb.TagNumber(9)
  void clearEmbedded() => $_clearField(9);
  @$pb.TagNumber(9)
  EmbeddedPost ensureEmbedded() => $_ensure(8);

  /// Lower-cased, without '#'.
  @$pb.TagNumber(10)
  $pb.PbList<$core.String> get hashtags => $_getList(9);

  @$pb.TagNumber(11)
  $pb.PbList<Mention> get mentions => $_getList(10);

  @$pb.TagNumber(12)
  $fixnum.Int64 get likeCount => $_getI64(11);
  @$pb.TagNumber(12)
  set likeCount($fixnum.Int64 value) => $_setInt64(11, value);
  @$pb.TagNumber(12)
  $core.bool hasLikeCount() => $_has(11);
  @$pb.TagNumber(12)
  void clearLikeCount() => $_clearField(12);

  @$pb.TagNumber(13)
  $fixnum.Int64 get repostCount => $_getI64(12);
  @$pb.TagNumber(13)
  set repostCount($fixnum.Int64 value) => $_setInt64(12, value);
  @$pb.TagNumber(13)
  $core.bool hasRepostCount() => $_has(12);
  @$pb.TagNumber(13)
  void clearRepostCount() => $_clearField(13);

  @$pb.TagNumber(14)
  $fixnum.Int64 get replyCount => $_getI64(13);
  @$pb.TagNumber(14)
  set replyCount($fixnum.Int64 value) => $_setInt64(13, value);
  @$pb.TagNumber(14)
  $core.bool hasReplyCount() => $_has(13);
  @$pb.TagNumber(14)
  void clearReplyCount() => $_clearField(14);

  @$pb.TagNumber(15)
  $fixnum.Int64 get quoteCount => $_getI64(14);
  @$pb.TagNumber(15)
  set quoteCount($fixnum.Int64 value) => $_setInt64(14, value);
  @$pb.TagNumber(15)
  $core.bool hasQuoteCount() => $_has(14);
  @$pb.TagNumber(15)
  void clearQuoteCount() => $_clearField(15);

  @$pb.TagNumber(16)
  Visibility get visibility => $_getN(15);
  @$pb.TagNumber(16)
  set visibility(Visibility value) => $_setField(16, value);
  @$pb.TagNumber(16)
  $core.bool hasVisibility() => $_has(15);
  @$pb.TagNumber(16)
  void clearVisibility() => $_clearField(16);

  @$pb.TagNumber(17)
  $1.Timestamp get createdAt => $_getN(16);
  @$pb.TagNumber(17)
  set createdAt($1.Timestamp value) => $_setField(17, value);
  @$pb.TagNumber(17)
  $core.bool hasCreatedAt() => $_has(16);
  @$pb.TagNumber(17)
  void clearCreatedAt() => $_clearField(17);
  @$pb.TagNumber(17)
  $1.Timestamp ensureCreatedAt() => $_ensure(16);
}

/// A post as seen by the caller. Viewer flags come from userLikes/{uid} (1 read per request, cached 60 s).
/// Until the engagement slice ships, both flags are always false and no userLikes read happens (ADR-0010 D3).
class PostView extends $pb.GeneratedMessage {
  factory PostView({
    Post? post,
    $core.bool? likedByViewer,
    $core.bool? repostedByViewer,
  }) {
    final result = PostView._();
    if (post != null) result.post = post;
    if (likedByViewer != null) result.likedByViewer = likedByViewer;
    if (repostedByViewer != null) result.repostedByViewer = repostedByViewer;
    return result;
  }

  PostView._();

  factory PostView.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      PostView()..mergeFromBuffer(data, registry);
  factory PostView.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      PostView()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'PostView',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.posts.v1'),
      createEmptyInstance: PostView.$_createMessage)
    ..aOM<Post>(1, _omitFieldNames ? '' : 'post',
        subBuilder: Post.$_createMessage)
    ..aOB(2, _omitFieldNames ? '' : 'likedByViewer')
    ..aOB(3, _omitFieldNames ? '' : 'repostedByViewer')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PostView clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PostView copyWith(void Function(PostView) updates) =>
      super.copyWith((message) => updates(message as PostView)) as PostView;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use PostView() / PostView.new instead')
  static PostView create() => PostView._();
  static $pb.GeneratedMessage $_createMessage() => PostView._();
  @$core.override
  PostView createEmptyInstance() => PostView._();
  @$core.pragma('dart2js:noInline')
  static PostView getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<PostView>(PostView.$_createMessage);
  static PostView? _defaultInstance;

  @$pb.TagNumber(1)
  Post get post => $_getN(0);
  @$pb.TagNumber(1)
  set post(Post value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasPost() => $_has(0);
  @$pb.TagNumber(1)
  void clearPost() => $_clearField(1);
  @$pb.TagNumber(1)
  Post ensurePost() => $_ensure(0);

  @$pb.TagNumber(2)
  $core.bool get likedByViewer => $_getBF(1);
  @$pb.TagNumber(2)
  set likedByViewer($core.bool value) => $_setBool(1, value);
  @$pb.TagNumber(2)
  $core.bool hasLikedByViewer() => $_has(1);
  @$pb.TagNumber(2)
  void clearLikedByViewer() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.bool get repostedByViewer => $_getBF(2);
  @$pb.TagNumber(3)
  set repostedByViewer($core.bool value) => $_setBool(2, value);
  @$pb.TagNumber(3)
  $core.bool hasRepostedByViewer() => $_has(2);
  @$pb.TagNumber(3)
  void clearRepostedByViewer() => $_clearField(3);
}

class CreatePostRequest extends $pb.GeneratedMessage {
  factory CreatePostRequest({
    $core.String? idempotencyKey,
    $core.String? text,
    $core.Iterable<$core.String>? mediaIds,
    $core.String? replyToPostId,
    $core.String? quoteOfPostId,
    $core.Iterable<$core.String>? mediaAltTexts,
  }) {
    final result = CreatePostRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (text != null) result.text = text;
    if (mediaIds != null) result.mediaIds.addAll(mediaIds);
    if (replyToPostId != null) result.replyToPostId = replyToPostId;
    if (quoteOfPostId != null) result.quoteOfPostId = quoteOfPostId;
    if (mediaAltTexts != null) result.mediaAltTexts.addAll(mediaAltTexts);
    return result;
  }

  CreatePostRequest._();

  factory CreatePostRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CreatePostRequest()..mergeFromBuffer(data, registry);
  factory CreatePostRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CreatePostRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CreatePostRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.posts.v1'),
      createEmptyInstance: CreatePostRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'text')
    ..pPS(3, _omitFieldNames ? '' : 'mediaIds')
    ..aOS(4, _omitFieldNames ? '' : 'replyToPostId')
    ..aOS(5, _omitFieldNames ? '' : 'quoteOfPostId')
    ..pPS(6, _omitFieldNames ? '' : 'mediaAltTexts')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreatePostRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreatePostRequest copyWith(void Function(CreatePostRequest) updates) =>
      super.copyWith((message) => updates(message as CreatePostRequest))
          as CreatePostRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use CreatePostRequest() / CreatePostRequest.new instead')
  static CreatePostRequest create() => CreatePostRequest._();
  static $pb.GeneratedMessage $_createMessage() => CreatePostRequest._();
  @$core.override
  CreatePostRequest createEmptyInstance() => CreatePostRequest._();
  @$core.pragma('dart2js:noInline')
  static CreatePostRequest getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<CreatePostRequest>(
          CreatePostRequest.$_createMessage);
  static CreatePostRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get text => $_getSZ(1);
  @$pb.TagNumber(2)
  set text($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasText() => $_has(1);
  @$pb.TagNumber(2)
  void clearText() => $_clearField(2);

  /// 0-4 media ids from dzeroth.media.v1 FinalizeUpload (status READY or READY_UNSCREENED).
  @$pb.TagNumber(3)
  $pb.PbList<$core.String> get mediaIds => $_getList(2);

  @$pb.TagNumber(4)
  $core.String get replyToPostId => $_getSZ(3);
  @$pb.TagNumber(4)
  set replyToPostId($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasReplyToPostId() => $_has(3);
  @$pb.TagNumber(4)
  void clearReplyToPostId() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.String get quoteOfPostId => $_getSZ(4);
  @$pb.TagNumber(5)
  set quoteOfPostId($core.String value) => $_setString(4, value);
  @$pb.TagNumber(5)
  $core.bool hasQuoteOfPostId() => $_has(4);
  @$pb.TagNumber(5)
  void clearQuoteOfPostId() => $_clearField(5);

  /// Parallel to media_ids; optional accessibility text <= 1,000 chars each.
  @$pb.TagNumber(6)
  $pb.PbList<$core.String> get mediaAltTexts => $_getList(5);
}

class CreatePostResponse extends $pb.GeneratedMessage {
  factory CreatePostResponse({
    PostView? post,
  }) {
    final result = CreatePostResponse._();
    if (post != null) result.post = post;
    return result;
  }

  CreatePostResponse._();

  factory CreatePostResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CreatePostResponse()..mergeFromBuffer(data, registry);
  factory CreatePostResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CreatePostResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CreatePostResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.posts.v1'),
      createEmptyInstance: CreatePostResponse.$_createMessage)
    ..aOM<PostView>(1, _omitFieldNames ? '' : 'post',
        subBuilder: PostView.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreatePostResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreatePostResponse copyWith(void Function(CreatePostResponse) updates) =>
      super.copyWith((message) => updates(message as CreatePostResponse))
          as CreatePostResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use CreatePostResponse() / CreatePostResponse.new instead')
  static CreatePostResponse create() => CreatePostResponse._();
  static $pb.GeneratedMessage $_createMessage() => CreatePostResponse._();
  @$core.override
  CreatePostResponse createEmptyInstance() => CreatePostResponse._();
  @$core.pragma('dart2js:noInline')
  static CreatePostResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<CreatePostResponse>(
          CreatePostResponse.$_createMessage);
  static CreatePostResponse? _defaultInstance;

  @$pb.TagNumber(1)
  PostView get post => $_getN(0);
  @$pb.TagNumber(1)
  set post(PostView value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasPost() => $_has(0);
  @$pb.TagNumber(1)
  void clearPost() => $_clearField(1);
  @$pb.TagNumber(1)
  PostView ensurePost() => $_ensure(0);
}

class DeletePostRequest extends $pb.GeneratedMessage {
  factory DeletePostRequest({
    $core.String? idempotencyKey,
    $core.String? postId,
  }) {
    final result = DeletePostRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (postId != null) result.postId = postId;
    return result;
  }

  DeletePostRequest._();

  factory DeletePostRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      DeletePostRequest()..mergeFromBuffer(data, registry);
  factory DeletePostRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      DeletePostRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'DeletePostRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.posts.v1'),
      createEmptyInstance: DeletePostRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'postId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DeletePostRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DeletePostRequest copyWith(void Function(DeletePostRequest) updates) =>
      super.copyWith((message) => updates(message as DeletePostRequest))
          as DeletePostRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use DeletePostRequest() / DeletePostRequest.new instead')
  static DeletePostRequest create() => DeletePostRequest._();
  static $pb.GeneratedMessage $_createMessage() => DeletePostRequest._();
  @$core.override
  DeletePostRequest createEmptyInstance() => DeletePostRequest._();
  @$core.pragma('dart2js:noInline')
  static DeletePostRequest getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<DeletePostRequest>(
          DeletePostRequest.$_createMessage);
  static DeletePostRequest? _defaultInstance;

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

class DeletePostResponse extends $pb.GeneratedMessage {
  factory DeletePostResponse() => DeletePostResponse._();

  DeletePostResponse._();

  factory DeletePostResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      DeletePostResponse()..mergeFromBuffer(data, registry);
  factory DeletePostResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      DeletePostResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'DeletePostResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.posts.v1'),
      createEmptyInstance: DeletePostResponse.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DeletePostResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DeletePostResponse copyWith(void Function(DeletePostResponse) updates) =>
      super.copyWith((message) => updates(message as DeletePostResponse))
          as DeletePostResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use DeletePostResponse() / DeletePostResponse.new instead')
  static DeletePostResponse create() => DeletePostResponse._();
  static $pb.GeneratedMessage $_createMessage() => DeletePostResponse._();
  @$core.override
  DeletePostResponse createEmptyInstance() => DeletePostResponse._();
  @$core.pragma('dart2js:noInline')
  static DeletePostResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<DeletePostResponse>(
          DeletePostResponse.$_createMessage);
  static DeletePostResponse? _defaultInstance;
}

class GetPostRequest extends $pb.GeneratedMessage {
  factory GetPostRequest({
    $core.String? postId,
  }) {
    final result = GetPostRequest._();
    if (postId != null) result.postId = postId;
    return result;
  }

  GetPostRequest._();

  factory GetPostRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetPostRequest()..mergeFromBuffer(data, registry);
  factory GetPostRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetPostRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetPostRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.posts.v1'),
      createEmptyInstance: GetPostRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'postId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetPostRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetPostRequest copyWith(void Function(GetPostRequest) updates) =>
      super.copyWith((message) => updates(message as GetPostRequest))
          as GetPostRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use GetPostRequest() / GetPostRequest.new instead')
  static GetPostRequest create() => GetPostRequest._();
  static $pb.GeneratedMessage $_createMessage() => GetPostRequest._();
  @$core.override
  GetPostRequest createEmptyInstance() => GetPostRequest._();
  @$core.pragma('dart2js:noInline')
  static GetPostRequest getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<GetPostRequest>(
          GetPostRequest.$_createMessage);
  static GetPostRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get postId => $_getSZ(0);
  @$pb.TagNumber(1)
  set postId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasPostId() => $_has(0);
  @$pb.TagNumber(1)
  void clearPostId() => $_clearField(1);
}

class GetPostResponse extends $pb.GeneratedMessage {
  factory GetPostResponse({
    PostView? post,
  }) {
    final result = GetPostResponse._();
    if (post != null) result.post = post;
    return result;
  }

  GetPostResponse._();

  factory GetPostResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetPostResponse()..mergeFromBuffer(data, registry);
  factory GetPostResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetPostResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetPostResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.posts.v1'),
      createEmptyInstance: GetPostResponse.$_createMessage)
    ..aOM<PostView>(1, _omitFieldNames ? '' : 'post',
        subBuilder: PostView.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetPostResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetPostResponse copyWith(void Function(GetPostResponse) updates) =>
      super.copyWith((message) => updates(message as GetPostResponse))
          as GetPostResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use GetPostResponse() / GetPostResponse.new instead')
  static GetPostResponse create() => GetPostResponse._();
  static $pb.GeneratedMessage $_createMessage() => GetPostResponse._();
  @$core.override
  GetPostResponse createEmptyInstance() => GetPostResponse._();
  @$core.pragma('dart2js:noInline')
  static GetPostResponse getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<GetPostResponse>(
          GetPostResponse.$_createMessage);
  static GetPostResponse? _defaultInstance;

  @$pb.TagNumber(1)
  PostView get post => $_getN(0);
  @$pb.TagNumber(1)
  set post(PostView value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasPost() => $_has(0);
  @$pb.TagNumber(1)
  void clearPost() => $_clearField(1);
  @$pb.TagNumber(1)
  PostView ensurePost() => $_ensure(0);
}

class GetThreadRequest extends $pb.GeneratedMessage {
  factory GetThreadRequest({
    $core.String? postId,
    $core.int? pageSize,
    $core.String? pageToken,
  }) {
    final result = GetThreadRequest._();
    if (postId != null) result.postId = postId;
    if (pageSize != null) result.pageSize = pageSize;
    if (pageToken != null) result.pageToken = pageToken;
    return result;
  }

  GetThreadRequest._();

  factory GetThreadRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetThreadRequest()..mergeFromBuffer(data, registry);
  factory GetThreadRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetThreadRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetThreadRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.posts.v1'),
      createEmptyInstance: GetThreadRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'postId')
    ..aI(2, _omitFieldNames ? '' : 'pageSize')
    ..aOS(3, _omitFieldNames ? '' : 'pageToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetThreadRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetThreadRequest copyWith(void Function(GetThreadRequest) updates) =>
      super.copyWith((message) => updates(message as GetThreadRequest))
          as GetThreadRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use GetThreadRequest() / GetThreadRequest.new instead')
  static GetThreadRequest create() => GetThreadRequest._();
  static $pb.GeneratedMessage $_createMessage() => GetThreadRequest._();
  @$core.override
  GetThreadRequest createEmptyInstance() => GetThreadRequest._();
  @$core.pragma('dart2js:noInline')
  static GetThreadRequest getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<GetThreadRequest>(
          GetThreadRequest.$_createMessage);
  static GetThreadRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get postId => $_getSZ(0);
  @$pb.TagNumber(1)
  set postId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasPostId() => $_has(0);
  @$pb.TagNumber(1)
  void clearPostId() => $_clearField(1);

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

class GetThreadResponse extends $pb.GeneratedMessage {
  factory GetThreadResponse({
    PostView? focal,
    PostView? parent,
    PostView? root,
    $core.Iterable<PostView>? replies,
    $core.String? nextPageToken,
  }) {
    final result = GetThreadResponse._();
    if (focal != null) result.focal = focal;
    if (parent != null) result.parent = parent;
    if (root != null) result.root = root;
    if (replies != null) result.replies.addAll(replies);
    if (nextPageToken != null) result.nextPageToken = nextPageToken;
    return result;
  }

  GetThreadResponse._();

  factory GetThreadResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetThreadResponse()..mergeFromBuffer(data, registry);
  factory GetThreadResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetThreadResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetThreadResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.posts.v1'),
      createEmptyInstance: GetThreadResponse.$_createMessage)
    ..aOM<PostView>(1, _omitFieldNames ? '' : 'focal',
        subBuilder: PostView.$_createMessage)
    ..aOM<PostView>(2, _omitFieldNames ? '' : 'parent',
        subBuilder: PostView.$_createMessage)
    ..aOM<PostView>(3, _omitFieldNames ? '' : 'root',
        subBuilder: PostView.$_createMessage)
    ..pPM<PostView>(4, _omitFieldNames ? '' : 'replies',
        subBuilder: PostView.$_createMessage)
    ..aOS(5, _omitFieldNames ? '' : 'nextPageToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetThreadResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetThreadResponse copyWith(void Function(GetThreadResponse) updates) =>
      super.copyWith((message) => updates(message as GetThreadResponse))
          as GetThreadResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use GetThreadResponse() / GetThreadResponse.new instead')
  static GetThreadResponse create() => GetThreadResponse._();
  static $pb.GeneratedMessage $_createMessage() => GetThreadResponse._();
  @$core.override
  GetThreadResponse createEmptyInstance() => GetThreadResponse._();
  @$core.pragma('dart2js:noInline')
  static GetThreadResponse getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<GetThreadResponse>(
          GetThreadResponse.$_createMessage);
  static GetThreadResponse? _defaultInstance;

  @$pb.TagNumber(1)
  PostView get focal => $_getN(0);
  @$pb.TagNumber(1)
  set focal(PostView value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasFocal() => $_has(0);
  @$pb.TagNumber(1)
  void clearFocal() => $_clearField(1);
  @$pb.TagNumber(1)
  PostView ensureFocal() => $_ensure(0);

  /// Unset when the focal post is a root, or the parent is unavailable.
  @$pb.TagNumber(2)
  PostView get parent => $_getN(1);
  @$pb.TagNumber(2)
  set parent(PostView value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasParent() => $_has(1);
  @$pb.TagNumber(2)
  void clearParent() => $_clearField(2);
  @$pb.TagNumber(2)
  PostView ensureParent() => $_ensure(1);

  /// Unset when the focal post is the root.
  @$pb.TagNumber(3)
  PostView get root => $_getN(2);
  @$pb.TagNumber(3)
  set root(PostView value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasRoot() => $_has(2);
  @$pb.TagNumber(3)
  void clearRoot() => $_clearField(3);
  @$pb.TagNumber(3)
  PostView ensureRoot() => $_ensure(2);

  /// Conversation posts in chronological order (excluding focal/parent/root).
  @$pb.TagNumber(4)
  $pb.PbList<PostView> get replies => $_getList(3);

  @$pb.TagNumber(5)
  $core.String get nextPageToken => $_getSZ(4);
  @$pb.TagNumber(5)
  set nextPageToken($core.String value) => $_setString(4, value);
  @$pb.TagNumber(5)
  $core.bool hasNextPageToken() => $_has(4);
  @$pb.TagNumber(5)
  void clearNextPageToken() => $_clearField(5);
}

class PostServiceApi {
  final $pb.RpcClient _client;

  PostServiceApi(this._client);

  /// Create a post, reply or quote. Text <= 280 code points after NFC; <= 4 READY media owned by the caller;
  /// <= 10 mentions (resolved via handles/*, cached), <= 10 hashtags (extracted server-side).
  /// Requires a verified email or a Google/Apple provider. Quota: 100 posts/day (quotas/{uid}; 20/day for
  /// accounts younger than 24 h).
  /// Slice 1 (ADR-0010 D2): root posts only. A non-empty reply_to_post_id, quote_of_post_id, media_ids or
  /// media_alt_texts => FAILED_PRECONDITION + FEATURE_DISABLED with metadata["feature"] = "replies" | "quotes" |
  /// "media" (first match in that order), 0 reads, until the replies/engagement/media slices ship.
  /// Text (ADR-0010 D9): CRLF/CR -> LF, TAB -> space, NFC, trim; empty, control characters other than LF, or bidi
  /// formatting controls (U+202A-U+202E, U+2066-U+2069) => VALIDATION field "text"; <= 280 code points, <= 10
  /// lines. Links are kept as typed and count toward the length (no server rewriting or previews).
  /// Mentions (ADR-0010 D7): "@" + handle (3-15 of [A-Za-z0-9_], not preceded by a letter/number/_@#/.:&$+-,
  /// never truncated); first 10 distinct, stored lower-cased as {user_id, handle}. Unknown handles stay plain
  /// text; mentions never depend on the block graph (a user who blocked the author is kept, so the response
  /// cannot reveal the block, ADR-0010 D7 M2); mentioning a user the author blocks is allowed.
  /// Hashtags (ADR-0010 D8): "#" + 1-50 of letters/marks/numbers/_ (plus ZWJ/ZWNJ inside), >= 1 letter;
  /// lower-cased, first 10 distinct stored; the text is unchanged.
  /// One transaction: idempotency doc + quotas read fresh; Create idempotency doc + Create post +
  /// users.postsCount + quotas (+ parent replyCount / quoted quoteCount once those ship). The post id (and
  /// created_at) is drawn in each transaction attempt; the transaction has a 5 s deadline (ADR-0010 D13).
  /// Replay: idempotency doc exists => return the stored post (+1 read if not cached); a different body =>
  /// INVALID_ARGUMENT + IDEMPOTENCY_KEY_REUSED, 0 writes.
  /// Firestore until replies/quotes/media ship (ADR-0010): reads 14 cold / 2 warm, planning 2.5 (caller users via
  /// the account-status interceptor 1 + handles <= 10 in (no author graph read since M2) if the text has mention
  /// candidates in one GetAll + idempotency 1 + quotas 1); writes 4/4 (idempotency, post, users.postsCount, quotas) + 1 eventual
  /// TTL delete. Replay: reads 14 cold / 1 warm, writes 0.
  /// Full contract once replies, quotes, media and notifications ship: reads 19/1, writes 6/4 (+<= 11 async
  /// notification writes: 1 per mentioned user + 1 for the parent/quoted author).
  $async.Future<CreatePostResponse> createPost(
          $pb.ClientContext? ctx, CreatePostRequest request) =>
      _client.invoke<CreatePostResponse>(
          ctx, 'PostService', 'CreatePost', request, CreatePostResponse());

  /// Delete own post. post_id must be 19 digits (else VALIDATION). Only the author's call deletes anything:
  /// another user's post, an unknown id and an already-deleted post all return success with 0 writes,
  /// byte-identical, so the call reveals neither existence nor blocks (ADR-0010 D4). Replay => success.
  /// Sync: one batch Delete(post, Exists) + users.postsCount -1; a failed Exists precondition (a concurrent
  /// delete won) => success, 0 writes, so the counter is decremented exactly once. Instance caches are evicted
  /// locally; others converge in <= 60 s.
  /// Until replies/media/engagement ship there is no async work (a root post has no dependants).
  /// Firestore until then: reads 2 cold / 0 warm, planning 1 (interceptor caller users + post); writes 1/1,
  /// deletes 1/1 (0/0 on a no-op).
  /// Full contract later: + parent replyCount (writes 2/1) and an async `post-delete` job for likes/reposts docs,
  /// quote embeds and media objects (batches <= 500, resumable; + async deletes = likes + reposts of the post).
  $async.Future<DeletePostResponse> deletePost(
          $pb.ClientContext? ctx, DeletePostRequest request) =>
      _client.invoke<DeletePostResponse>(
          ctx, 'PostService', 'DeletePost', request, DeletePostResponse());

  /// A single post. NOT_FOUND ("post not found", byte-identical in every case) if the post is missing or
  /// deleted, hidden by visibility, the author blocks the caller, or the author is SUSPENDED, DELETING or gone.
  /// A caller who blocks or mutes the author still gets the post; the client shows a banner (ADR-0010 D6).
  /// Viewer flags are always false until engagement ships (no userLikes read, ADR-0010 D3).
  /// Reads: caller users (account-status interceptor) + post + author users (status) + caller graph (blocked-by),
  /// all instance-cached 60 s; +1 author graph if the caller's blocked-by list overflowed (ADR-0008 D2).
  /// Firestore: reads 4 cold (+1 overflow) / 0 warm, planning 1; +1 (userLikes) once engagement ships. Writes 0.
  $async.Future<GetPostResponse> getPost(
          $pb.ClientContext? ctx, GetPostRequest request) =>
      _client.invoke<GetPostResponse>(
          ctx, 'PostService', 'GetPost', request, GetPostResponse());

  /// Post detail: the focal post, its parent and conversation root, and a page of the conversation in
  /// chronological order (posts where conversationId == root, createdAt ASC). Blocked/muted/invisible
  /// replies are dropped after the read (page may be short; follow next_page_token).
  /// Returns UNIMPLEMENTED until the replies slice (P3); its ADR restates this budget.
  /// Firestore: reads 56/10 (focal+parent+root 3, graphs 2, userLikes 1, page <= 50), writes 0.
  $async.Future<GetThreadResponse> getThread(
          $pb.ClientContext? ctx, GetThreadRequest request) =>
      _client.invoke<GetThreadResponse>(
          ctx, 'PostService', 'GetThread', request, GetThreadResponse());
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
