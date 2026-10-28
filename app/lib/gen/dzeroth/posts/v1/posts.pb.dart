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

/// A one-level, denormalized copy of another post (quoted or reposted), frozen at write time (the original's
/// author snapshot is not refreshed by the profile-snapshot job). Replaced by a tombstone (unavailable = true, only
/// post_id set) by the post-delete job when the original is deleted, and when its author deletes their account.
/// A REPOST whose original is deleted is removed outright instead.
class EmbeddedPost extends $pb.GeneratedMessage {
  factory EmbeddedPost({
    $core.String? postId,
    $0.AuthorSnapshot? author,
    $core.String? text,
    $core.Iterable<$0.MediaRef>? media,
    $1.Timestamp? createdAt,
    $core.bool? unavailable,
    $core.bool? paidPartnership,
    $core.bool? madeWithAi,
    ReplyPolicy? replyPolicy,
  }) {
    final result = EmbeddedPost._();
    if (postId != null) result.postId = postId;
    if (author != null) result.author = author;
    if (text != null) result.text = text;
    if (media != null) result.media.addAll(media);
    if (createdAt != null) result.createdAt = createdAt;
    if (unavailable != null) result.unavailable = unavailable;
    if (paidPartnership != null) result.paidPartnership = paidPartnership;
    if (madeWithAi != null) result.madeWithAi = madeWithAi;
    if (replyPolicy != null) result.replyPolicy = replyPolicy;
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
    ..aOB(7, _omitFieldNames ? '' : 'paidPartnership')
    ..aOB(8, _omitFieldNames ? '' : 'madeWithAi')
    ..aE<ReplyPolicy>(9, _omitFieldNames ? '' : 'replyPolicy',
        enumValues: ReplyPolicy.values)
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

  /// The original's disclosure labels (ADR-0021 D3), frozen at write time; render them on the embed.
  @$pb.TagNumber(7)
  $core.bool get paidPartnership => $_getBF(6);
  @$pb.TagNumber(7)
  set paidPartnership($core.bool value) => $_setBool(6, value);
  @$pb.TagNumber(7)
  $core.bool hasPaidPartnership() => $_has(6);
  @$pb.TagNumber(7)
  void clearPaidPartnership() => $_clearField(7);

  @$pb.TagNumber(8)
  $core.bool get madeWithAi => $_getBF(7);
  @$pb.TagNumber(8)
  set madeWithAi($core.bool value) => $_setBool(7, value);
  @$pb.TagNumber(8)
  $core.bool hasMadeWithAi() => $_has(7);
  @$pb.TagNumber(8)
  void clearMadeWithAi() => $_clearField(8);

  /// The original's effective reply policy, for the viewer hint of a REPOST row (ADR-0021 D2).
  @$pb.TagNumber(9)
  ReplyPolicy get replyPolicy => $_getN(8);
  @$pb.TagNumber(9)
  set replyPolicy(ReplyPolicy value) => $_setField(9, value);
  @$pb.TagNumber(9)
  $core.bool hasReplyPolicy() => $_has(8);
  @$pb.TagNumber(9)
  void clearReplyPolicy() => $_clearField(9);
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
    ReplyPolicy? replyPolicy,
    $core.bool? paidPartnership,
    $core.bool? madeWithAi,
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
    if (replyPolicy != null) result.replyPolicy = replyPolicy;
    if (paidPartnership != null) result.paidPartnership = paidPartnership;
    if (madeWithAi != null) result.madeWithAi = madeWithAi;
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
    ..aE<ReplyPolicy>(18, _omitFieldNames ? '' : 'replyPolicy',
        enumValues: ReplyPolicy.values)
    ..aOB(19, _omitFieldNames ? '' : 'paidPartnership')
    ..aOB(20, _omitFieldNames ? '' : 'madeWithAi')
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

  /// Effective reply policy (ADR-0021 D2); on replies, the one inherited from the conversation. UNSPECIFIED ==
  /// EVERYONE.
  @$pb.TagNumber(18)
  ReplyPolicy get replyPolicy => $_getN(17);
  @$pb.TagNumber(18)
  set replyPolicy(ReplyPolicy value) => $_setField(18, value);
  @$pb.TagNumber(18)
  $core.bool hasReplyPolicy() => $_has(17);
  @$pb.TagNumber(18)
  void clearReplyPolicy() => $_clearField(18);

  /// User-asserted disclosure labels (ADR-0021 D3).
  @$pb.TagNumber(19)
  $core.bool get paidPartnership => $_getBF(18);
  @$pb.TagNumber(19)
  set paidPartnership($core.bool value) => $_setBool(18, value);
  @$pb.TagNumber(19)
  $core.bool hasPaidPartnership() => $_has(18);
  @$pb.TagNumber(19)
  void clearPaidPartnership() => $_clearField(19);

  @$pb.TagNumber(20)
  $core.bool get madeWithAi => $_getBF(19);
  @$pb.TagNumber(20)
  set madeWithAi($core.bool value) => $_setBool(19, value);
  @$pb.TagNumber(20)
  $core.bool hasMadeWithAi() => $_has(19);
  @$pb.TagNumber(20)
  void clearMadeWithAi() => $_clearField(20);
}

/// A post as seen by the caller. Viewer flags come from userLikes/{uid} (1 read per request, cached 60 s) while
/// FEATURE_ENGAGEMENT or FEATURE_BOOKMARKS is on for the caller (liked / reposted only with engagement, bookmarked_by_viewer with either); otherwise all are false and no userLikes read happens (ADR-0010 D3).
/// For a REPOST item the flags describe the original (embedded.post_id): the caller liked / reposted it.
class PostView extends $pb.GeneratedMessage {
  factory PostView({
    Post? post,
    $core.bool? likedByViewer,
    $core.bool? repostedByViewer,
    ReplyPermission? viewerReplyPermission,
    EmbedViewerState? embedViewerState,
    $core.bool? bookmarkedByViewer,
  }) {
    final result = PostView._();
    if (post != null) result.post = post;
    if (likedByViewer != null) result.likedByViewer = likedByViewer;
    if (repostedByViewer != null) result.repostedByViewer = repostedByViewer;
    if (viewerReplyPermission != null)
      result.viewerReplyPermission = viewerReplyPermission;
    if (embedViewerState != null) result.embedViewerState = embedViewerState;
    if (bookmarkedByViewer != null)
      result.bookmarkedByViewer = bookmarkedByViewer;
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
    ..aE<ReplyPermission>(4, _omitFieldNames ? '' : 'viewerReplyPermission',
        enumValues: ReplyPermission.values)
    ..aE<EmbedViewerState>(5, _omitFieldNames ? '' : 'embedViewerState',
        enumValues: EmbedViewerState.values)
    ..aOB(6, _omitFieldNames ? '' : 'bookmarkedByViewer')
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

  /// Whether the caller may reply (ADR-0021 D2). Timelines decide it with 0 reads for root posts only (EVERYONE, the
  /// viewer is the author, or MENTIONED_ONLY); a REPOST row uses embedded.reply_policy; anything else is UNKNOWN.
  @$pb.TagNumber(4)
  ReplyPermission get viewerReplyPermission => $_getN(3);
  @$pb.TagNumber(4)
  set viewerReplyPermission(ReplyPermission value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasViewerReplyPermission() => $_has(3);
  @$pb.TagNumber(4)
  void clearViewerReplyPermission() => $_clearField(4);

  /// Set by GetPost and GetThread for a REPOST or QUOTE whose embedded author the viewer blocks or mutes, so the
  /// client shows the placeholder even when its relationship cache is cold (issue #152). Timelines do not set BLOCKED
  /// or MUTED: they drop such rows (ADR-0018 D13). PROTECTED (ADR-0025 D4) is different: every surface that returns a
  /// QUOTE row, timelines and lists included, keeps the row and sets it, with the embed stripped.
  @$pb.TagNumber(5)
  EmbedViewerState get embedViewerState => $_getN(4);
  @$pb.TagNumber(5)
  set embedViewerState(EmbedViewerState value) => $_setField(5, value);
  @$pb.TagNumber(5)
  $core.bool hasEmbedViewerState() => $_has(4);
  @$pb.TagNumber(5)
  void clearEmbedViewerState() => $_clearField(5);

  /// Whether the caller bookmarked this item (ADR-0023 D3); true only for the caller, never another user's state. For a
  /// REPOST row it describes the original (embedded.post_id), like liked_by_viewer. Hydrated from userLikes.bookmarks at
  /// 0 extra reads when FEATURE_ENGAGEMENT is on for the viewer (the userLikes read already happens), +1 cold read
  /// (cached 60 s) when only FEATURE_BOOKMARKS is on; absent (false) when neither flag is on for the viewer. Staleness
  /// bound: the userLikes instance cache TTL (60 s). With only bookmarks on, liked_by_viewer and reposted_by_viewer
  /// stay false.
  @$pb.TagNumber(6)
  $core.bool get bookmarkedByViewer => $_getBF(5);
  @$pb.TagNumber(6)
  set bookmarkedByViewer($core.bool value) => $_setBool(5, value);
  @$pb.TagNumber(6)
  $core.bool hasBookmarkedByViewer() => $_has(5);
  @$pb.TagNumber(6)
  void clearBookmarkedByViewer() => $_clearField(6);
}

class CreatePostRequest extends $pb.GeneratedMessage {
  factory CreatePostRequest({
    $core.String? idempotencyKey,
    $core.String? text,
    $core.Iterable<$core.String>? mediaIds,
    $core.String? replyToPostId,
    $core.String? quoteOfPostId,
    $core.Iterable<$core.String>? mediaAltTexts,
    ReplyPolicy? replyPolicy,
    $core.bool? paidPartnership,
    $core.bool? madeWithAi,
  }) {
    final result = CreatePostRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (text != null) result.text = text;
    if (mediaIds != null) result.mediaIds.addAll(mediaIds);
    if (replyToPostId != null) result.replyToPostId = replyToPostId;
    if (quoteOfPostId != null) result.quoteOfPostId = quoteOfPostId;
    if (mediaAltTexts != null) result.mediaAltTexts.addAll(mediaAltTexts);
    if (replyPolicy != null) result.replyPolicy = replyPolicy;
    if (paidPartnership != null) result.paidPartnership = paidPartnership;
    if (madeWithAi != null) result.madeWithAi = madeWithAi;
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
    ..aE<ReplyPolicy>(7, _omitFieldNames ? '' : 'replyPolicy',
        enumValues: ReplyPolicy.values)
    ..aOB(8, _omitFieldNames ? '' : 'paidPartnership')
    ..aOB(9, _omitFieldNames ? '' : 'madeWithAi')
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

  /// Root posts and quotes only (ADR-0021 D2); FEATURE_REPLY_AUDIENCE.
  @$pb.TagNumber(7)
  ReplyPolicy get replyPolicy => $_getN(6);
  @$pb.TagNumber(7)
  set replyPolicy(ReplyPolicy value) => $_setField(7, value);
  @$pb.TagNumber(7)
  $core.bool hasReplyPolicy() => $_has(6);
  @$pb.TagNumber(7)
  void clearReplyPolicy() => $_clearField(7);

  /// Disclosure labels (ADR-0021 D3); FEATURE_CONTENT_DISCLOSURE.
  @$pb.TagNumber(8)
  $core.bool get paidPartnership => $_getBF(7);
  @$pb.TagNumber(8)
  set paidPartnership($core.bool value) => $_setBool(7, value);
  @$pb.TagNumber(8)
  $core.bool hasPaidPartnership() => $_has(7);
  @$pb.TagNumber(8)
  void clearPaidPartnership() => $_clearField(8);

  @$pb.TagNumber(9)
  $core.bool get madeWithAi => $_getBF(8);
  @$pb.TagNumber(9)
  set madeWithAi($core.bool value) => $_setBool(8, value);
  @$pb.TagNumber(9)
  $core.bool hasMadeWithAi() => $_has(8);
  @$pb.TagNumber(9)
  void clearMadeWithAi() => $_clearField(9);
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
    $core.bool? parentUnavailable,
    $core.bool? rootUnavailable,
  }) {
    final result = GetThreadResponse._();
    if (focal != null) result.focal = focal;
    if (parent != null) result.parent = parent;
    if (root != null) result.root = root;
    if (replies != null) result.replies.addAll(replies);
    if (nextPageToken != null) result.nextPageToken = nextPageToken;
    if (parentUnavailable != null) result.parentUnavailable = parentUnavailable;
    if (rootUnavailable != null) result.rootUnavailable = rootUnavailable;
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
    ..aOB(6, _omitFieldNames ? '' : 'parentUnavailable')
    ..aOB(7, _omitFieldNames ? '' : 'rootUnavailable')
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

  /// Unset when the focal post is a root, or the parent is unavailable (see parent_unavailable).
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

  /// True when the focal post is a reply whose parent no longer exists or cannot be shown to the caller
  /// (deleted, author suspended/blocking, not public). Render a tombstone. Additive in P3.
  @$pb.TagNumber(6)
  $core.bool get parentUnavailable => $_getBF(5);
  @$pb.TagNumber(6)
  set parentUnavailable($core.bool value) => $_setBool(5, value);
  @$pb.TagNumber(6)
  $core.bool hasParentUnavailable() => $_has(5);
  @$pb.TagNumber(6)
  void clearParentUnavailable() => $_clearField(6);

  /// Same for the conversation root when the focal post is a reply.
  @$pb.TagNumber(7)
  $core.bool get rootUnavailable => $_getBF(6);
  @$pb.TagNumber(7)
  set rootUnavailable($core.bool value) => $_setBool(6, value);
  @$pb.TagNumber(7)
  $core.bool hasRootUnavailable() => $_has(6);
  @$pb.TagNumber(7)
  void clearRootUnavailable() => $_clearField(7);
}

/// A post waiting to be published by the server (ADR-0021 D4). Kept 7 days after it reaches a terminal state.
class ScheduledPost extends $pb.GeneratedMessage {
  factory ScheduledPost({
    $core.String? scheduledId,
    $core.String? text,
    $core.Iterable<$0.MediaRef>? media,
    ReplyPolicy? replyPolicy,
    $core.bool? paidPartnership,
    $core.bool? madeWithAi,
    $1.Timestamp? publishAt,
    ScheduledPostStatus? status,
    $core.String? postId,
    ScheduledPostFailure? failure,
    $1.Timestamp? createdAt,
  }) {
    final result = ScheduledPost._();
    if (scheduledId != null) result.scheduledId = scheduledId;
    if (text != null) result.text = text;
    if (media != null) result.media.addAll(media);
    if (replyPolicy != null) result.replyPolicy = replyPolicy;
    if (paidPartnership != null) result.paidPartnership = paidPartnership;
    if (madeWithAi != null) result.madeWithAi = madeWithAi;
    if (publishAt != null) result.publishAt = publishAt;
    if (status != null) result.status = status;
    if (postId != null) result.postId = postId;
    if (failure != null) result.failure = failure;
    if (createdAt != null) result.createdAt = createdAt;
    return result;
  }

  ScheduledPost._();

  factory ScheduledPost.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ScheduledPost()..mergeFromBuffer(data, registry);
  factory ScheduledPost.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ScheduledPost()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ScheduledPost',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.posts.v1'),
      createEmptyInstance: ScheduledPost.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'scheduledId')
    ..aOS(2, _omitFieldNames ? '' : 'text')
    ..pPM<$0.MediaRef>(3, _omitFieldNames ? '' : 'media',
        subBuilder: $0.MediaRef.$_createMessage)
    ..aE<ReplyPolicy>(4, _omitFieldNames ? '' : 'replyPolicy',
        enumValues: ReplyPolicy.values)
    ..aOB(5, _omitFieldNames ? '' : 'paidPartnership')
    ..aOB(6, _omitFieldNames ? '' : 'madeWithAi')
    ..aOM<$1.Timestamp>(7, _omitFieldNames ? '' : 'publishAt',
        subBuilder: $1.Timestamp.$_createMessage)
    ..aE<ScheduledPostStatus>(8, _omitFieldNames ? '' : 'status',
        enumValues: ScheduledPostStatus.values)
    ..aOS(9, _omitFieldNames ? '' : 'postId')
    ..aE<ScheduledPostFailure>(10, _omitFieldNames ? '' : 'failure',
        enumValues: ScheduledPostFailure.values)
    ..aOM<$1.Timestamp>(11, _omitFieldNames ? '' : 'createdAt',
        subBuilder: $1.Timestamp.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ScheduledPost clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ScheduledPost copyWith(void Function(ScheduledPost) updates) =>
      super.copyWith((message) => updates(message as ScheduledPost))
          as ScheduledPost;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use ScheduledPost() / ScheduledPost.new instead')
  static ScheduledPost create() => ScheduledPost._();
  static $pb.GeneratedMessage $_createMessage() => ScheduledPost._();
  @$core.override
  ScheduledPost createEmptyInstance() => ScheduledPost._();
  @$core.pragma('dart2js:noInline')
  static ScheduledPost getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<ScheduledPost>(
          ScheduledPost.$_createMessage);
  static ScheduledPost? _defaultInstance;

  /// 32 lowercase hex characters.
  @$pb.TagNumber(1)
  $core.String get scheduledId => $_getSZ(0);
  @$pb.TagNumber(1)
  set scheduledId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasScheduledId() => $_has(0);
  @$pb.TagNumber(1)
  void clearScheduledId() => $_clearField(1);

  /// Empty unless PENDING (the draft is cleared on PUBLISHED, CANCELLED and FAILED).
  @$pb.TagNumber(2)
  $core.String get text => $_getSZ(1);
  @$pb.TagNumber(2)
  set text($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasText() => $_has(1);
  @$pb.TagNumber(2)
  void clearText() => $_clearField(2);

  /// Including alt text; lists render thumb_url only. Empty unless PENDING (the draft is cleared on PUBLISHED, CANCELLED and FAILED).
  @$pb.TagNumber(3)
  $pb.PbList<$0.MediaRef> get media => $_getList(2);

  @$pb.TagNumber(4)
  ReplyPolicy get replyPolicy => $_getN(3);
  @$pb.TagNumber(4)
  set replyPolicy(ReplyPolicy value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasReplyPolicy() => $_has(3);
  @$pb.TagNumber(4)
  void clearReplyPolicy() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.bool get paidPartnership => $_getBF(4);
  @$pb.TagNumber(5)
  set paidPartnership($core.bool value) => $_setBool(4, value);
  @$pb.TagNumber(5)
  $core.bool hasPaidPartnership() => $_has(4);
  @$pb.TagNumber(5)
  void clearPaidPartnership() => $_clearField(5);

  @$pb.TagNumber(6)
  $core.bool get madeWithAi => $_getBF(5);
  @$pb.TagNumber(6)
  set madeWithAi($core.bool value) => $_setBool(5, value);
  @$pb.TagNumber(6)
  $core.bool hasMadeWithAi() => $_has(5);
  @$pb.TagNumber(6)
  void clearMadeWithAi() => $_clearField(6);

  /// UTC, a whole minute, as stored by the server (show this, not the requested time).
  @$pb.TagNumber(7)
  $1.Timestamp get publishAt => $_getN(6);
  @$pb.TagNumber(7)
  set publishAt($1.Timestamp value) => $_setField(7, value);
  @$pb.TagNumber(7)
  $core.bool hasPublishAt() => $_has(6);
  @$pb.TagNumber(7)
  void clearPublishAt() => $_clearField(7);
  @$pb.TagNumber(7)
  $1.Timestamp ensurePublishAt() => $_ensure(6);

  @$pb.TagNumber(8)
  ScheduledPostStatus get status => $_getN(7);
  @$pb.TagNumber(8)
  set status(ScheduledPostStatus value) => $_setField(8, value);
  @$pb.TagNumber(8)
  $core.bool hasStatus() => $_has(7);
  @$pb.TagNumber(8)
  void clearStatus() => $_clearField(8);

  /// Set when PUBLISHED.
  @$pb.TagNumber(9)
  $core.String get postId => $_getSZ(8);
  @$pb.TagNumber(9)
  set postId($core.String value) => $_setString(8, value);
  @$pb.TagNumber(9)
  $core.bool hasPostId() => $_has(8);
  @$pb.TagNumber(9)
  void clearPostId() => $_clearField(9);

  /// Set when FAILED.
  @$pb.TagNumber(10)
  ScheduledPostFailure get failure => $_getN(9);
  @$pb.TagNumber(10)
  set failure(ScheduledPostFailure value) => $_setField(10, value);
  @$pb.TagNumber(10)
  $core.bool hasFailure() => $_has(9);
  @$pb.TagNumber(10)
  void clearFailure() => $_clearField(10);

  @$pb.TagNumber(11)
  $1.Timestamp get createdAt => $_getN(10);
  @$pb.TagNumber(11)
  set createdAt($1.Timestamp value) => $_setField(11, value);
  @$pb.TagNumber(11)
  $core.bool hasCreatedAt() => $_has(10);
  @$pb.TagNumber(11)
  void clearCreatedAt() => $_clearField(11);
  @$pb.TagNumber(11)
  $1.Timestamp ensureCreatedAt() => $_ensure(10);
}

class SchedulePostRequest extends $pb.GeneratedMessage {
  factory SchedulePostRequest({
    $core.String? idempotencyKey,
    $core.String? text,
    $core.Iterable<$core.String>? mediaIds,
    $core.Iterable<$core.String>? mediaAltTexts,
    ReplyPolicy? replyPolicy,
    $core.bool? paidPartnership,
    $core.bool? madeWithAi,
    $1.Timestamp? publishAt,
  }) {
    final result = SchedulePostRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (text != null) result.text = text;
    if (mediaIds != null) result.mediaIds.addAll(mediaIds);
    if (mediaAltTexts != null) result.mediaAltTexts.addAll(mediaAltTexts);
    if (replyPolicy != null) result.replyPolicy = replyPolicy;
    if (paidPartnership != null) result.paidPartnership = paidPartnership;
    if (madeWithAi != null) result.madeWithAi = madeWithAi;
    if (publishAt != null) result.publishAt = publishAt;
    return result;
  }

  SchedulePostRequest._();

  factory SchedulePostRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SchedulePostRequest()..mergeFromBuffer(data, registry);
  factory SchedulePostRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SchedulePostRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'SchedulePostRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.posts.v1'),
      createEmptyInstance: SchedulePostRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'text')
    ..pPS(3, _omitFieldNames ? '' : 'mediaIds')
    ..pPS(4, _omitFieldNames ? '' : 'mediaAltTexts')
    ..aE<ReplyPolicy>(5, _omitFieldNames ? '' : 'replyPolicy',
        enumValues: ReplyPolicy.values)
    ..aOB(6, _omitFieldNames ? '' : 'paidPartnership')
    ..aOB(7, _omitFieldNames ? '' : 'madeWithAi')
    ..aOM<$1.Timestamp>(8, _omitFieldNames ? '' : 'publishAt',
        subBuilder: $1.Timestamp.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SchedulePostRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SchedulePostRequest copyWith(void Function(SchedulePostRequest) updates) =>
      super.copyWith((message) => updates(message as SchedulePostRequest))
          as SchedulePostRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core
      .Deprecated('Use SchedulePostRequest() / SchedulePostRequest.new instead')
  static SchedulePostRequest create() => SchedulePostRequest._();
  static $pb.GeneratedMessage $_createMessage() => SchedulePostRequest._();
  @$core.override
  SchedulePostRequest createEmptyInstance() => SchedulePostRequest._();
  @$core.pragma('dart2js:noInline')
  static SchedulePostRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<SchedulePostRequest>(
          SchedulePostRequest.$_createMessage);
  static SchedulePostRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  /// CreatePost text rules.
  @$pb.TagNumber(2)
  $core.String get text => $_getSZ(1);
  @$pb.TagNumber(2)
  set text($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasText() => $_has(1);
  @$pb.TagNumber(2)
  void clearText() => $_clearField(2);

  /// 0-4 media ids, as CreatePost.
  @$pb.TagNumber(3)
  $pb.PbList<$core.String> get mediaIds => $_getList(2);

  /// Parallel to media_ids, as CreatePost.
  @$pb.TagNumber(4)
  $pb.PbList<$core.String> get mediaAltTexts => $_getList(3);

  @$pb.TagNumber(5)
  ReplyPolicy get replyPolicy => $_getN(4);
  @$pb.TagNumber(5)
  set replyPolicy(ReplyPolicy value) => $_setField(5, value);
  @$pb.TagNumber(5)
  $core.bool hasReplyPolicy() => $_has(4);
  @$pb.TagNumber(5)
  void clearReplyPolicy() => $_clearField(5);

  @$pb.TagNumber(6)
  $core.bool get paidPartnership => $_getBF(5);
  @$pb.TagNumber(6)
  set paidPartnership($core.bool value) => $_setBool(5, value);
  @$pb.TagNumber(6)
  $core.bool hasPaidPartnership() => $_has(5);
  @$pb.TagNumber(6)
  void clearPaidPartnership() => $_clearField(6);

  @$pb.TagNumber(7)
  $core.bool get madeWithAi => $_getBF(6);
  @$pb.TagNumber(7)
  set madeWithAi($core.bool value) => $_setBool(6, value);
  @$pb.TagNumber(7)
  $core.bool hasMadeWithAi() => $_has(6);
  @$pb.TagNumber(7)
  void clearMadeWithAi() => $_clearField(7);

  /// UTC; truncated to the minute by the server. The client's time zone is display-only.
  @$pb.TagNumber(8)
  $1.Timestamp get publishAt => $_getN(7);
  @$pb.TagNumber(8)
  set publishAt($1.Timestamp value) => $_setField(8, value);
  @$pb.TagNumber(8)
  $core.bool hasPublishAt() => $_has(7);
  @$pb.TagNumber(8)
  void clearPublishAt() => $_clearField(8);
  @$pb.TagNumber(8)
  $1.Timestamp ensurePublishAt() => $_ensure(7);
}

class SchedulePostResponse extends $pb.GeneratedMessage {
  factory SchedulePostResponse({
    ScheduledPost? scheduledPost,
  }) {
    final result = SchedulePostResponse._();
    if (scheduledPost != null) result.scheduledPost = scheduledPost;
    return result;
  }

  SchedulePostResponse._();

  factory SchedulePostResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SchedulePostResponse()..mergeFromBuffer(data, registry);
  factory SchedulePostResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SchedulePostResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'SchedulePostResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.posts.v1'),
      createEmptyInstance: SchedulePostResponse.$_createMessage)
    ..aOM<ScheduledPost>(1, _omitFieldNames ? '' : 'scheduledPost',
        subBuilder: ScheduledPost.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SchedulePostResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SchedulePostResponse copyWith(void Function(SchedulePostResponse) updates) =>
      super.copyWith((message) => updates(message as SchedulePostResponse))
          as SchedulePostResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use SchedulePostResponse() / SchedulePostResponse.new instead')
  static SchedulePostResponse create() => SchedulePostResponse._();
  static $pb.GeneratedMessage $_createMessage() => SchedulePostResponse._();
  @$core.override
  SchedulePostResponse createEmptyInstance() => SchedulePostResponse._();
  @$core.pragma('dart2js:noInline')
  static SchedulePostResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<SchedulePostResponse>(
          SchedulePostResponse.$_createMessage);
  static SchedulePostResponse? _defaultInstance;

  @$pb.TagNumber(1)
  ScheduledPost get scheduledPost => $_getN(0);
  @$pb.TagNumber(1)
  set scheduledPost(ScheduledPost value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasScheduledPost() => $_has(0);
  @$pb.TagNumber(1)
  void clearScheduledPost() => $_clearField(1);
  @$pb.TagNumber(1)
  ScheduledPost ensureScheduledPost() => $_ensure(0);
}

class ListScheduledPostsRequest extends $pb.GeneratedMessage {
  factory ListScheduledPostsRequest({
    $core.int? pageSize,
    $core.String? pageToken,
  }) {
    final result = ListScheduledPostsRequest._();
    if (pageSize != null) result.pageSize = pageSize;
    if (pageToken != null) result.pageToken = pageToken;
    return result;
  }

  ListScheduledPostsRequest._();

  factory ListScheduledPostsRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListScheduledPostsRequest()..mergeFromBuffer(data, registry);
  factory ListScheduledPostsRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListScheduledPostsRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListScheduledPostsRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.posts.v1'),
      createEmptyInstance: ListScheduledPostsRequest.$_createMessage)
    ..aI(1, _omitFieldNames ? '' : 'pageSize')
    ..aOS(2, _omitFieldNames ? '' : 'pageToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListScheduledPostsRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListScheduledPostsRequest copyWith(
          void Function(ListScheduledPostsRequest) updates) =>
      super.copyWith((message) => updates(message as ListScheduledPostsRequest))
          as ListScheduledPostsRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ListScheduledPostsRequest() / ListScheduledPostsRequest.new instead')
  static ListScheduledPostsRequest create() => ListScheduledPostsRequest._();
  static $pb.GeneratedMessage $_createMessage() =>
      ListScheduledPostsRequest._();
  @$core.override
  ListScheduledPostsRequest createEmptyInstance() =>
      ListScheduledPostsRequest._();
  @$core.pragma('dart2js:noInline')
  static ListScheduledPostsRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListScheduledPostsRequest>(
          ListScheduledPostsRequest.$_createMessage);
  static ListScheduledPostsRequest? _defaultInstance;

  /// 0 => 20, max 50.
  @$pb.TagNumber(1)
  $core.int get pageSize => $_getIZ(0);
  @$pb.TagNumber(1)
  set pageSize($core.int value) => $_setSignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasPageSize() => $_has(0);
  @$pb.TagNumber(1)
  void clearPageSize() => $_clearField(1);

  /// Opaque, bound to the caller.
  @$pb.TagNumber(2)
  $core.String get pageToken => $_getSZ(1);
  @$pb.TagNumber(2)
  set pageToken($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasPageToken() => $_has(1);
  @$pb.TagNumber(2)
  void clearPageToken() => $_clearField(2);
}

class ListScheduledPostsResponse extends $pb.GeneratedMessage {
  factory ListScheduledPostsResponse({
    $core.Iterable<ScheduledPost>? scheduledPosts,
    $core.String? nextPageToken,
  }) {
    final result = ListScheduledPostsResponse._();
    if (scheduledPosts != null) result.scheduledPosts.addAll(scheduledPosts);
    if (nextPageToken != null) result.nextPageToken = nextPageToken;
    return result;
  }

  ListScheduledPostsResponse._();

  factory ListScheduledPostsResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListScheduledPostsResponse()..mergeFromBuffer(data, registry);
  factory ListScheduledPostsResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListScheduledPostsResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListScheduledPostsResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.posts.v1'),
      createEmptyInstance: ListScheduledPostsResponse.$_createMessage)
    ..pPM<ScheduledPost>(1, _omitFieldNames ? '' : 'scheduledPosts',
        subBuilder: ScheduledPost.$_createMessage)
    ..aOS(2, _omitFieldNames ? '' : 'nextPageToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListScheduledPostsResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListScheduledPostsResponse copyWith(
          void Function(ListScheduledPostsResponse) updates) =>
      super.copyWith(
              (message) => updates(message as ListScheduledPostsResponse))
          as ListScheduledPostsResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ListScheduledPostsResponse() / ListScheduledPostsResponse.new instead')
  static ListScheduledPostsResponse create() => ListScheduledPostsResponse._();
  static $pb.GeneratedMessage $_createMessage() =>
      ListScheduledPostsResponse._();
  @$core.override
  ListScheduledPostsResponse createEmptyInstance() =>
      ListScheduledPostsResponse._();
  @$core.pragma('dart2js:noInline')
  static ListScheduledPostsResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListScheduledPostsResponse>(
          ListScheduledPostsResponse.$_createMessage);
  static ListScheduledPostsResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<ScheduledPost> get scheduledPosts => $_getList(0);

  @$pb.TagNumber(2)
  $core.String get nextPageToken => $_getSZ(1);
  @$pb.TagNumber(2)
  set nextPageToken($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasNextPageToken() => $_has(1);
  @$pb.TagNumber(2)
  void clearNextPageToken() => $_clearField(2);
}

class CancelScheduledPostRequest extends $pb.GeneratedMessage {
  factory CancelScheduledPostRequest({
    $core.String? idempotencyKey,
    $core.String? scheduledId,
  }) {
    final result = CancelScheduledPostRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (scheduledId != null) result.scheduledId = scheduledId;
    return result;
  }

  CancelScheduledPostRequest._();

  factory CancelScheduledPostRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CancelScheduledPostRequest()..mergeFromBuffer(data, registry);
  factory CancelScheduledPostRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CancelScheduledPostRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CancelScheduledPostRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.posts.v1'),
      createEmptyInstance: CancelScheduledPostRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'scheduledId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CancelScheduledPostRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CancelScheduledPostRequest copyWith(
          void Function(CancelScheduledPostRequest) updates) =>
      super.copyWith(
              (message) => updates(message as CancelScheduledPostRequest))
          as CancelScheduledPostRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use CancelScheduledPostRequest() / CancelScheduledPostRequest.new instead')
  static CancelScheduledPostRequest create() => CancelScheduledPostRequest._();
  static $pb.GeneratedMessage $_createMessage() =>
      CancelScheduledPostRequest._();
  @$core.override
  CancelScheduledPostRequest createEmptyInstance() =>
      CancelScheduledPostRequest._();
  @$core.pragma('dart2js:noInline')
  static CancelScheduledPostRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<CancelScheduledPostRequest>(
          CancelScheduledPostRequest.$_createMessage);
  static CancelScheduledPostRequest? _defaultInstance;

  /// Unused; format-validated so clients keep one code path.
  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get scheduledId => $_getSZ(1);
  @$pb.TagNumber(2)
  set scheduledId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasScheduledId() => $_has(1);
  @$pb.TagNumber(2)
  void clearScheduledId() => $_clearField(2);
}

class CancelScheduledPostResponse extends $pb.GeneratedMessage {
  factory CancelScheduledPostResponse({
    ScheduledPost? scheduledPost,
  }) {
    final result = CancelScheduledPostResponse._();
    if (scheduledPost != null) result.scheduledPost = scheduledPost;
    return result;
  }

  CancelScheduledPostResponse._();

  factory CancelScheduledPostResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CancelScheduledPostResponse()..mergeFromBuffer(data, registry);
  factory CancelScheduledPostResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CancelScheduledPostResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CancelScheduledPostResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.posts.v1'),
      createEmptyInstance: CancelScheduledPostResponse.$_createMessage)
    ..aOM<ScheduledPost>(1, _omitFieldNames ? '' : 'scheduledPost',
        subBuilder: ScheduledPost.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CancelScheduledPostResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CancelScheduledPostResponse copyWith(
          void Function(CancelScheduledPostResponse) updates) =>
      super.copyWith(
              (message) => updates(message as CancelScheduledPostResponse))
          as CancelScheduledPostResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use CancelScheduledPostResponse() / CancelScheduledPostResponse.new instead')
  static CancelScheduledPostResponse create() =>
      CancelScheduledPostResponse._();
  static $pb.GeneratedMessage $_createMessage() =>
      CancelScheduledPostResponse._();
  @$core.override
  CancelScheduledPostResponse createEmptyInstance() =>
      CancelScheduledPostResponse._();
  @$core.pragma('dart2js:noInline')
  static CancelScheduledPostResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<CancelScheduledPostResponse>(
          CancelScheduledPostResponse.$_createMessage);
  static CancelScheduledPostResponse? _defaultInstance;

  /// The current state; PUBLISHED means it was too late to cancel (not an error).
  @$pb.TagNumber(1)
  ScheduledPost get scheduledPost => $_getN(0);
  @$pb.TagNumber(1)
  set scheduledPost(ScheduledPost value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasScheduledPost() => $_has(0);
  @$pb.TagNumber(1)
  void clearScheduledPost() => $_clearField(1);
  @$pb.TagNumber(1)
  ScheduledPost ensureScheduledPost() => $_ensure(0);
}

class PostServiceApi {
  final $pb.RpcClient _client;

  PostServiceApi(this._client);

  /// Create a post, reply or quote. Text <= 280 code points after NFC; <= 4 READY media owned by the caller;
  /// <= 10 mentions (resolved via handles/*, cached), <= 10 hashtags (extracted server-side).
  /// Requires a verified email or a Google/Apple provider. Quota: 100 posts/day (quotas/{uid}; 20/day for
  /// accounts younger than 24 h).
  /// Not available while the sub-feature's flag is off for the caller (ADR-0010 D2): a non-empty reply_to_post_id
  /// (FEATURE_REPLIES), quote_of_post_id (FEATURE_ENGAGEMENT), media_ids / media_alt_texts (FEATURE_MEDIA), a
  /// reply_policy other than UNSPECIFIED (FEATURE_REPLY_AUDIENCE) or paid_partnership / made_with_ai true
  /// (FEATURE_CONTENT_DISCLOSURE) => FAILED_PRECONDITION + FEATURE_DISABLED with metadata["feature"] = "replies" |
  /// "quotes" | "media" | "reply_audience" | "content_disclosure" (first match in that order), 0 reads.
  /// Reply policy (ADR-0021 D2): settable on a root post or a quote only (a non-UNSPECIFIED value on a reply =>
  /// VALIDATION field "reply_policy"); FOLLOWING_OF_FOLLOWING and VERIFIED => VALIDATION field "reply_policy" ("not
  /// available yet"). UNSPECIFIED and EVERYONE are stored as absent. It covers the whole conversation: a reply stores
  /// the policy inherited from its parent (0 extra reads). A reply into a FOLLOWING or MENTIONED_ONLY conversation is
  /// checked against the conversation root R after the parent visibility check: an unusable R (missing, not public,
  /// hidden, author not ACTIVE, a block in either direction, caller blockedBy overflow, or a quote root whose embedded
  /// author blocks the caller) => NOT_FOUND "post not found"; otherwise R's author always may reply, FOLLOWING needs
  /// R's author to follow the caller (graph cache 60 s), MENTIONED_ONLY needs the caller in R's mentions; else
  /// PERMISSION_DENIED + REPLY_NOT_ALLOWED (metadata["policy"]), 0 writes, nothing stored under the idempotency key.
  /// Enforcement is not flag-gated. Extra reads: EVERYONE / absent +0; parent = root: MENTIONED_ONLY +0, FOLLOWING
  /// +1 cold; deeper: MENTIONED_ONLY +3, FOLLOWING +4 cold; +0 warm.
  /// Disclosure (ADR-0021 D3): paid_partnership and made_with_ai are user-asserted labels, never rejected; copied
  /// into the embedded snapshot of quotes and reposts. Clients compare the returned post's reply_policy and labels
  /// with what they sent (UNSPECIFIED == EVERYONE) and warn on a mismatch (ADR-0021 L-1).
  /// Quotes (P5, plan engagement.md, FEATURE_ENGAGEMENT): quote_of_post_id is a 19-digit post id that must be visible
  /// to the caller by the GetPost rules (else NOT_FOUND "post not found", 0 writes). Quoting a REPOST quotes its
  /// original. A quote needs its own text or at least one image, cannot also set reply_to_post_id (VALIDATION), is
  /// kind QUOTE, a root post for feeds (never a reply), carries an embedded one-level snapshot of the quoted post
  /// frozen at write time, and increments the quoted post's quote_count in the same transaction. Reads +3 cold /
  /// +0 warm for the visibility check and writes +1 (quoteCount) over a root post: 17 cold / 2 warm reads, 5 writes.
  /// Deleting the quoted post replaces the embed with an unavailable tombstone (async job).
  /// Protected authors (ADR-0025 D5): quoting a protected account's post is refused for everyone but that account:
  /// a caller who may not see the post gets NOT_FOUND "post not found" (the visibility check above), and an approved
  /// follower gets FAILED_PRECONDITION + PROTECTED_ACCOUNT; both 0 writes. A reply to such a post by an approved
  /// follower is allowed and is public: it shows its own text, never the parent's.
  /// Replies (P3, plan replies-and-threads.md): reply_to_post_id is honoured when FEATURE_REPLIES is on for the caller (else
  /// FEATURE_DISABLED, metadata["feature"]="replies"). The parent must be visible to the caller by the GetPost
  /// rules (missing, deleted, hidden, suspended author or an author who blocks the caller => NOT_FOUND
  /// "post not found", 0 writes). The reply copies the parent's conversation_id, sets reply_to_handle, increments
  /// the parent's reply_count in the same transaction and is never fanned out to the home timeline.
  /// Reply reads 15 cold / 3 warm, writes 5 (idempotency, post, users.postsCount, quotas, parent replyCount).
  /// Reply audience (ADR-0021 D2): a reply into a restricted conversation (FOLLOWING / MENTIONED_ONLY root) is checked after
  /// the parent visibility check. Extra reads over a plain reply: EVERYONE +0; restricted, parent is the root: MENTIONED_ONLY +0,
  /// FOLLOWING +1 cold (root author's graph); restricted, deeper reply: MENTIONED_ONLY +3 / FOLLOWING +4 cold (root post, root
  /// author's profile, caller graph if the caller wrote the parent, + root author's graph for FOLLOWING); +0 warm (60 s caches).
  /// A refusal is PERMISSION_DENIED + ERROR_REASON_REPLY_NOT_ALLOWED with metadata "policy" = "following" | "mentioned_only",
  /// 0 writes, same reads as the allowed path. A conversation root that is unusable for the caller (deleted, hidden, suspended or
  /// deleting author, or one who blocks the caller) is NOT_FOUND "post not found", never REPLY_NOT_ALLOWED.
  /// Media (P4, FEATURE_MEDIA): media_ids are 1-4 distinct READY or READY_UNSCREENED POST images owned by the caller
  /// and not yet attached to a post; any other id (missing, someone else's, an avatar, PENDING, REJECTED, already
  /// used) => FAILED_PRECONDITION + MEDIA_NOT_READY, one answer for every cause. media_alt_texts is empty or
  /// parallel to media_ids, each <= 1,000 characters. A post with at least one image may have empty text. The
  /// image refs (url, thumb_url, size, blurhash, alt) are copied into the post; lists render thumb_url only.
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
  /// Firestore for a root post without images (ADR-0010): reads 14 cold / 2 warm, planning 2.5 (caller users via
  /// the account-status interceptor 1 + handles <= 10 in (no author graph read since M2) if the text has mention
  /// candidates in one GetAll + idempotency 1 + quotas 1); writes 4/4 (idempotency, post, users.postsCount, quotas) + 1 eventual
  /// TTL delete. Replay: reads 14 cold / 1 warm, writes 0.
  /// With n images (P4): + n reads (one GetAll of media/* inside the transaction) and + n writes (media/{id}.postId),
  /// so at most 17 cold / 6 warm reads and 8 writes; a replay re-reads no media.
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
  /// Every deleted post publishes one `post_delete` job after the commit (Pub/Sub, no Firestore access on the
  /// request path). The job (idempotent, resumable) deletes its public image objects and media documents, its
  /// likes and reposts documents (and the REPOST posts docs those created), and replaces the embedded snapshot of
  /// quotes of it with an unavailable tombstone. Async cost: 2 post reads + n media + 3 queries (1 read minimum
  /// each) + 1 read and 1 delete per dependant.
  /// Deleting a REPOST post doc is UndoRepost (P5): its reposts/{originalId}_{uid} doc goes in the same batch and the
  /// original's repostCount is decremented best effort after the commit. Deleting a QUOTE decrements the quoted
  /// post's quoteCount best effort, like a reply's parent replyCount.
  /// Firestore (request path): reads 2 cold / 0 warm, planning 1 (interceptor caller users + post); writes 1/1,
  /// deletes 1/1 (0/0 on a no-op), + 1 best-effort counter write for a reply, quote or repost.
  $async.Future<DeletePostResponse> deletePost(
          $pb.ClientContext? ctx, DeletePostRequest request) =>
      _client.invoke<DeletePostResponse>(
          ctx, 'PostService', 'DeletePost', request, DeletePostResponse());

  /// A single post. NOT_FOUND ("post not found", byte-identical in every case) if the post is missing or
  /// deleted, hidden by visibility, the author blocks the caller, or the author is SUSPENDED, DELETING or gone.
  /// A caller who blocks or mutes the author still gets the post; the client shows a banner (ADR-0010 D6).
  /// Viewer flags are false and userLikes is not read while FEATURE_ENGAGEMENT and FEATURE_BOOKMARKS are both off for the caller (ADR-0010 D3);
  /// with either on they come from userLikes/{caller} (cache-first, 60 s): liked / reposted only with engagement, bookmarked_by_viewer with either. A REPOST or QUOTE whose embedded author
  /// blocks the caller is NOT_FOUND like a post by that author.
  /// Protected authors (ADR-0025 D4): a post by a protected account is NOT_FOUND (the same bytes) for a caller who is
  /// neither that account nor a follower of it, and so is a REPOST of such a post; a QUOTE of one is returned with
  /// embed_viewer_state = PROTECTED and its embed stripped of text and media. Post.visibility is FOLLOWERS while the
  /// author is protected. Decided from the instance-cached protected-author set: 0 extra reads.
  /// Reads: caller users (account-status interceptor) + post + author users (status) + caller graph (blocked-by),
  /// all instance-cached 60 s; +1 author graph if the caller's blocked-by list overflowed (ADR-0008 D2).
  /// Firestore: reads 4 cold (+1 overflow) / 0 warm, planning 1; +1 userLikes cold with engagement or bookmarks on. Writes 0.
  /// viewer_reply_permission (ADR-0021 D2): for a root post in a FOLLOWING conversation (viewer not the author) +1
  /// cold read (the author's graph); a reply in a restricted conversation is always UNKNOWN (+0).
  $async.Future<GetPostResponse> getPost(
          $pb.ClientContext? ctx, GetPostRequest request) =>
      _client.invoke<GetPostResponse>(
          ctx, 'PostService', 'GetPost', request, GetPostResponse());

  /// Post detail: the focal post, its parent and conversation root, and a page of the conversation in
  /// chronological order (posts where conversationId == root, createdAt ASC, the root itself skipped).
  /// Behind FEATURE_REPLIES (and FEATURE_POSTS); FEATURE_DISABLED with metadata["feature"] = "replies" if off.
  /// NOT_FOUND "post not found" (the GetPost rules) if the focal post is missing, deleted, hidden, or its author
  /// blocks the caller. A parent/root that is deleted, suspended, hidden or blocks the caller is not an error:
  /// it is returned unset with parent_unavailable / root_unavailable = true so the client renders a tombstone.
  /// Replies by authors the caller blocks or mutes (and by authors who block the caller) are dropped after the
  /// read, so a page may be short; follow next_page_token while it is non-empty.
  /// Protected authors (ADR-0025 D4), for a caller who is neither the author nor a follower of it: a focal post by a
  /// protected account is NOT_FOUND; such a parent or root is unset with parent_unavailable / root_unavailable; reply
  /// rows by such an account are dropped (the page may be short); QUOTE embeds as in GetPost. 0 extra reads.
  /// page_size: default 10 (first page, cost-model lever 6.2), clamped to 1..30. Opaque page_token bound to
  /// the caller and the focal post.
  /// Firestore (plan replies-and-threads.md): reads <= 1 (interceptor) + focal 1 + parent/root 2 + <= 3 author profiles
  /// + caller graph 1 (+1 author graph on blockedBy overflow) + page <= 30 = 38 cold, <= 3 warm
  /// (one conversation query, minimum 1); writes 0.
  /// viewer_reply_permission (ADR-0021 D2): UNKNOWN when root_unavailable; otherwise computed from the root, +1 cold
  /// read for a FOLLOWING conversation (the root author's graph), +0 warm.
  $async.Future<GetThreadResponse> getThread(
          $pb.ClientContext? ctx, GetThreadRequest request) =>
      _client.invoke<GetThreadResponse>(
          ctx, 'PostService', 'GetThread', request, GetThreadResponse());

  /// Scheduled posts (ADR-0021 D4). All three need FEATURE_POSTS. SchedulePost also needs FEATURE_SCHEDULED_POSTS on for the
  /// caller; ListScheduledPosts and CancelScheduledPost only need it not globally off, so a caller outside the allowlist or
  /// percent bucket can still list and cancel what they already scheduled. Otherwise FAILED_PRECONDITION +
  /// FEATURE_DISABLED (metadata["feature"] = "scheduled_posts" for the latter), 0 reads. They
  /// only ever touch users/{caller}/scheduled; another user's id is NOT_FOUND like an unknown id. They share the
  /// CreatePost rate-limit bucket. A published post is created by the server sweep (Cloud Scheduler, every 5 min),
  /// up to ~5 min after publish_at; an item more than 6 h late is FAILED EXPIRED instead of published.
  ///
  /// Schedule a root post (no reply, quote or poll) with the CreatePost text and media rules, plus the media,
  /// reply_audience and content_disclosure sub-feature checks and a verified email, as CreatePost. publish_at is
  /// truncated to the whole minute (UTC) and must be within [now + 2 min, now + 60 d] by server time, else VALIDATION
  /// field "publish_at". Media are validated (owned, READY or READY_UNSCREENED, unattached) but not reserved: an image
  /// used elsewhere before publish fails the item MEDIA_UNAVAILABLE; it stays reachable by its public URL until then.
  /// Idempotency: the doc id is derived from (caller, idempotency_key); a replay returns the stored item (even after
  /// the lead time passed or a cap filled), a different effective body => IDEMPOTENCY_KEY_REUSED. A replay of a
  /// PUBLISHED, CANCELLED or FAILED item returns it without text or media.
  /// A call that gets a cap error (LIMIT_REACHED, QUOTA_EXCEEDED) may be a near-simultaneous duplicate of a call that just
  /// succeeded: keep the same idempotency_key and retry after any such error, and the retry returns the stored item.
  /// Caps: 25 pending (soft: counted outside the transaction, so concurrent calls can overshoot it by the number in
  /// flight) => LIMIT_REACHED metadata["limit"] = "scheduled_pending"; 3 pending within +/-4 min of publish_at (exact:
  /// counted inside the transaction, so concurrent calls cannot exceed it; a near-simultaneous duplicate that finds the
  /// window full is answered with the stored item) => LIMIT_REACHED "scheduled_window"; 50 calls per IST day (10 for
  /// accounts younger than 24 h) => QUOTA_EXCEEDED metadata["quota"] = "schedules". The posts daily quota is charged at
  /// publish.
  /// Firestore: reads 9 worst (interceptor 1, scheduled doc 1, pending count 1, quotas 1, window count 1, media <= 4)
  /// / 5 typical without media (4 of them the service's own; the interceptor's profile read is a cache hit when warm);
  /// writes 2 (scheduled doc, quotas). A concurrent duplicate adds 1 (the winner's doc is re-read), and a transaction
  /// retry under contention re-reads quotas, the window count and the media (up to 6 more per retry). Replay / at
  /// pending cap / at window cap / at daily cap: reads 2 / 3 / 6 / 5 worst, writes 0 (the window cap reads this key's own
  /// document once more, to tell a full window from a duplicate).
  $async.Future<SchedulePostResponse> schedulePost(
          $pb.ClientContext? ctx, SchedulePostRequest request) =>
      _client.invoke<SchedulePostResponse>(
          ctx, 'PostService', 'SchedulePost', request, SchedulePostResponse());

  /// The caller's PENDING and FAILED scheduled posts, publish_at ascending. page_size 0 => 20, clamped to 50; opaque
  /// page_token bound to the caller.
  /// Firestore: reads 1 + page (21 at 20, 51 at 50), typical 1 + items (min 1); writes 0.
  $async.Future<ListScheduledPostsResponse> listScheduledPosts(
          $pb.ClientContext? ctx, ListScheduledPostsRequest request) =>
      _client.invoke<ListScheduledPostsResponse>(ctx, 'PostService',
          'ListScheduledPosts', request, ListScheduledPostsResponse());

  /// Cancel a PENDING item, or dismiss a FAILED one; returns the item's current state without text or media.
  /// Idempotent by state: an item already PUBLISHED (too late, not an error) or CANCELLED is returned unchanged with
  /// 0 writes. scheduled_id must match ^[0-9a-f]{32}$ (else VALIDATION); unknown => NOT_FOUND. idempotency_key is
  /// format-validated (VALIDATION when malformed) but not stored.
  /// Firestore: reads 2 worst / 1 typical; writes 1 (0 if already terminal); +1 TTL delete after 7 d.
  $async.Future<CancelScheduledPostResponse> cancelScheduledPost(
          $pb.ClientContext? ctx, CancelScheduledPostRequest request) =>
      _client.invoke<CancelScheduledPostResponse>(ctx, 'PostService',
          'CancelScheduledPost', request, CancelScheduledPostResponse());
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
