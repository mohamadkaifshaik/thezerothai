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
    as $0;

import '../../beacons/v1/beacons.pbenum.dart' as $2;
import '../../common/v1/common.pb.dart' as $1;
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

/// One choice of a poll.
class PollChoice extends $pb.GeneratedMessage {
  factory PollChoice({
    $core.String? label,
    $fixnum.Int64? votes,
  }) {
    final result = PollChoice._();
    if (label != null) result.label = label;
    if (votes != null) result.votes = votes;
    return result;
  }

  PollChoice._();

  factory PollChoice.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      PollChoice()..mergeFromBuffer(data, registry);
  factory PollChoice.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      PollChoice()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'PollChoice',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.posts.v1'),
      createEmptyInstance: PollChoice.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'label')
    ..aInt64(2, _omitFieldNames ? '' : 'votes')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PollChoice clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PollChoice copyWith(void Function(PollChoice) updates) =>
      super.copyWith((message) => updates(message as PollChoice)) as PollChoice;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use PollChoice() / PollChoice.new instead')
  static PollChoice create() => PollChoice._();
  static $pb.GeneratedMessage $_createMessage() => PollChoice._();
  @$core.override
  PollChoice createEmptyInstance() => PollChoice._();
  @$core.pragma('dart2js:noInline')
  static PollChoice getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<PollChoice>(PollChoice.$_createMessage);
  static PollChoice? _defaultInstance;

  /// 1-25 code points, as the author wrote it (normalised by the text rules).
  @$pb.TagNumber(1)
  $core.String get label => $_getSZ(0);
  @$pb.TagNumber(1)
  set label($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasLabel() => $_has(0);
  @$pb.TagNumber(1)
  void clearLabel() => $_clearField(1);

  /// Votes for this choice. 0 whenever Poll.results_visible is false: hidden, not zero (the bytes are the same whatever
  /// the real count). Never render bars or percentages from it unless results_visible is true.
  @$pb.TagNumber(2)
  $fixnum.Int64 get votes => $_getI64(1);
  @$pb.TagNumber(2)
  set votes($fixnum.Int64 value) => $_setInt64(1, value);
  @$pb.TagNumber(2)
  $core.bool hasVotes() => $_has(1);
  @$pb.TagNumber(2)
  void clearVotes() => $_clearField(2);
}

/// A poll on a root post. Stored on the post doc, so it needs no extra lookup anywhere a post is read.
/// Counts are the post's instance-cached state (up to 60 s stale), except in the VotePoll response (the committed
/// counts). Per viewer: never cache a Post with a poll across viewers on the client.
/// In EmbeddedPost.poll (a repost or quote row) it is a frozen definition: labels and closes_at only, every votes 0,
/// total_votes 0 and results_visible false always; render a compact "Poll · N choices" and open the original (GetPost)
/// for live results.
class Poll extends $pb.GeneratedMessage {
  factory Poll({
    $core.Iterable<PollChoice>? choices,
    $0.Timestamp? closesAt,
    $fixnum.Int64? totalVotes,
    $core.bool? resultsVisible,
    $core.bool? closed,
  }) {
    final result = Poll._();
    if (choices != null) result.choices.addAll(choices);
    if (closesAt != null) result.closesAt = closesAt;
    if (totalVotes != null) result.totalVotes = totalVotes;
    if (resultsVisible != null) result.resultsVisible = resultsVisible;
    if (closed != null) result.closed = closed;
    return result;
  }

  Poll._();

  factory Poll.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Poll()..mergeFromBuffer(data, registry);
  factory Poll.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Poll()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Poll',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.posts.v1'),
      createEmptyInstance: Poll.$_createMessage)
    ..pPM<PollChoice>(1, _omitFieldNames ? '' : 'choices',
        subBuilder: PollChoice.$_createMessage)
    ..aOM<$0.Timestamp>(2, _omitFieldNames ? '' : 'closesAt',
        subBuilder: $0.Timestamp.$_createMessage)
    ..aInt64(3, _omitFieldNames ? '' : 'totalVotes')
    ..aOB(4, _omitFieldNames ? '' : 'resultsVisible')
    ..aOB(5, _omitFieldNames ? '' : 'closed')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Poll clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Poll copyWith(void Function(Poll) updates) =>
      super.copyWith((message) => updates(message as Poll)) as Poll;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Poll() / Poll.new instead')
  static Poll create() => Poll._();
  static $pb.GeneratedMessage $_createMessage() => Poll._();
  @$core.override
  Poll createEmptyInstance() => Poll._();
  @$core.pragma('dart2js:noInline')
  static Poll getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Poll>(Poll.$_createMessage);
  static Poll? _defaultInstance;

  /// 2-4 choices in the author's order; VotePoll.choice_index indexes this list.
  @$pb.TagNumber(1)
  $pb.PbList<PollChoice> get choices => $_getList(0);

  /// Server time; created_at + the requested duration. The client counts down from it; it never decides "closed" for
  /// the server.
  @$pb.TagNumber(2)
  $0.Timestamp get closesAt => $_getN(1);
  @$pb.TagNumber(2)
  set closesAt($0.Timestamp value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasClosesAt() => $_has(1);
  @$pb.TagNumber(2)
  void clearClosesAt() => $_clearField(2);
  @$pb.TagNumber(2)
  $0.Timestamp ensureClosesAt() => $_ensure(1);

  /// Total votes, always shown (F3), including while per-choice counts are hidden. 0 in EmbeddedPost.poll.
  @$pb.TagNumber(3)
  $fixnum.Int64 get totalVotes => $_getI64(2);
  @$pb.TagNumber(3)
  set totalVotes($fixnum.Int64 value) => $_setInt64(2, value);
  @$pb.TagNumber(3)
  $core.bool hasTotalVotes() => $_has(2);
  @$pb.TagNumber(3)
  void clearTotalVotes() => $_clearField(3);

  /// True when the viewer may see per-choice counts: the poll is closed, the viewer is the author, the viewer voted, or
  /// FEATURE_POLLS is globally off (voting impossible). Nobody can see who voted for what.
  @$pb.TagNumber(4)
  $core.bool get resultsVisible => $_getBF(3);
  @$pb.TagNumber(4)
  set resultsVisible($core.bool value) => $_setBool(3, value);
  @$pb.TagNumber(4)
  $core.bool hasResultsVisible() => $_has(3);
  @$pb.TagNumber(4)
  void clearResultsVisible() => $_clearField(4);

  /// now >= closes_at by server time when the response was built.
  @$pb.TagNumber(5)
  $core.bool get closed => $_getBF(4);
  @$pb.TagNumber(5)
  set closed($core.bool value) => $_setBool(4, value);
  @$pb.TagNumber(5)
  $core.bool hasClosed() => $_has(4);
  @$pb.TagNumber(5)
  void clearClosed() => $_clearField(5);
}

/// The poll a CreatePost asks for.
class PollDraft extends $pb.GeneratedMessage {
  factory PollDraft({
    $core.Iterable<$core.String>? choices,
    $core.int? durationMinutes,
  }) {
    final result = PollDraft._();
    if (choices != null) result.choices.addAll(choices);
    if (durationMinutes != null) result.durationMinutes = durationMinutes;
    return result;
  }

  PollDraft._();

  factory PollDraft.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      PollDraft()..mergeFromBuffer(data, registry);
  factory PollDraft.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      PollDraft()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'PollDraft',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.posts.v1'),
      createEmptyInstance: PollDraft.$_createMessage)
    ..pPS(1, _omitFieldNames ? '' : 'choices')
    ..aI(2, _omitFieldNames ? '' : 'durationMinutes')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PollDraft clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PollDraft copyWith(void Function(PollDraft) updates) =>
      super.copyWith((message) => updates(message as PollDraft)) as PollDraft;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use PollDraft() / PollDraft.new instead')
  static PollDraft create() => PollDraft._();
  static $pb.GeneratedMessage $_createMessage() => PollDraft._();
  @$core.override
  PollDraft createEmptyInstance() => PollDraft._();
  @$core.pragma('dart2js:noInline')
  static PollDraft getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<PollDraft>(PollDraft.$_createMessage);
  static PollDraft? _defaultInstance;

  /// 2-4 choices, each 1-25 code points, distinct after NFC and case folding.
  @$pb.TagNumber(1)
  $pb.PbList<$core.String> get choices => $_getList(0);

  /// 5 to 10080 (7 days). The client default is 1440 (1 day).
  @$pb.TagNumber(2)
  $core.int get durationMinutes => $_getIZ(1);
  @$pb.TagNumber(2)
  set durationMinutes($core.int value) => $_setSignedInt32(1, value);
  @$pb.TagNumber(2)
  $core.bool hasDurationMinutes() => $_has(1);
  @$pb.TagNumber(2)
  void clearDurationMinutes() => $_clearField(2);
}

/// A one-level, denormalized copy of another post (quoted or reposted), frozen at write time (the original's
/// author snapshot is not refreshed by the profile-snapshot job). Replaced by a tombstone (unavailable = true, only
/// post_id set) by the post-delete job when the original is deleted, and when its author deletes their account.
/// A REPOST whose original is deleted is removed outright instead.
/// It carries no community label at Stage 0: a REPOST row shows "reposted", never the original's community.
class EmbeddedPost extends $pb.GeneratedMessage {
  factory EmbeddedPost({
    $core.String? postId,
    $1.AuthorSnapshot? author,
    $core.String? text,
    $core.Iterable<$1.MediaRef>? media,
    $0.Timestamp? createdAt,
    $core.bool? unavailable,
    $core.bool? paidPartnership,
    $core.bool? madeWithAi,
    ReplyPolicy? replyPolicy,
    Poll? poll,
    ArticlePreview? article,
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
    if (poll != null) result.poll = poll;
    if (article != null) result.article = article;
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
    ..aOM<$1.AuthorSnapshot>(2, _omitFieldNames ? '' : 'author',
        subBuilder: $1.AuthorSnapshot.$_createMessage)
    ..aOS(3, _omitFieldNames ? '' : 'text')
    ..pPM<$1.MediaRef>(4, _omitFieldNames ? '' : 'media',
        subBuilder: $1.MediaRef.$_createMessage)
    ..aOM<$0.Timestamp>(5, _omitFieldNames ? '' : 'createdAt',
        subBuilder: $0.Timestamp.$_createMessage)
    ..aOB(6, _omitFieldNames ? '' : 'unavailable')
    ..aOB(7, _omitFieldNames ? '' : 'paidPartnership')
    ..aOB(8, _omitFieldNames ? '' : 'madeWithAi')
    ..aE<ReplyPolicy>(9, _omitFieldNames ? '' : 'replyPolicy',
        enumValues: ReplyPolicy.values)
    ..aOM<Poll>(10, _omitFieldNames ? '' : 'poll',
        subBuilder: Poll.$_createMessage)
    ..aOM<ArticlePreview>(11, _omitFieldNames ? '' : 'article',
        subBuilder: ArticlePreview.$_createMessage)
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
  $1.AuthorSnapshot get author => $_getN(1);
  @$pb.TagNumber(2)
  set author($1.AuthorSnapshot value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasAuthor() => $_has(1);
  @$pb.TagNumber(2)
  void clearAuthor() => $_clearField(2);
  @$pb.TagNumber(2)
  $1.AuthorSnapshot ensureAuthor() => $_ensure(1);

  @$pb.TagNumber(3)
  $core.String get text => $_getSZ(2);
  @$pb.TagNumber(3)
  set text($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasText() => $_has(2);
  @$pb.TagNumber(3)
  void clearText() => $_clearField(3);

  @$pb.TagNumber(4)
  $pb.PbList<$1.MediaRef> get media => $_getList(3);

  @$pb.TagNumber(5)
  $0.Timestamp get createdAt => $_getN(4);
  @$pb.TagNumber(5)
  set createdAt($0.Timestamp value) => $_setField(5, value);
  @$pb.TagNumber(5)
  $core.bool hasCreatedAt() => $_has(4);
  @$pb.TagNumber(5)
  void clearCreatedAt() => $_clearField(5);
  @$pb.TagNumber(5)
  $0.Timestamp ensureCreatedAt() => $_ensure(4);

  /// True when the original was deleted or became invisible; render a tombstone.
  @$pb.TagNumber(6)
  $core.bool get unavailable => $_getBF(5);
  @$pb.TagNumber(6)
  set unavailable($core.bool value) => $_setBool(5, value);
  @$pb.TagNumber(6)
  $core.bool hasUnavailable() => $_has(5);
  @$pb.TagNumber(6)
  void clearUnavailable() => $_clearField(6);

  /// The original's disclosure labels, frozen at write time; render them on the embed.
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

  /// The original's effective reply policy, for the viewer hint of a REPOST row.
  @$pb.TagNumber(9)
  ReplyPolicy get replyPolicy => $_getN(8);
  @$pb.TagNumber(9)
  set replyPolicy(ReplyPolicy value) => $_setField(9, value);
  @$pb.TagNumber(9)
  $core.bool hasReplyPolicy() => $_has(8);
  @$pb.TagNumber(9)
  void clearReplyPolicy() => $_clearField(9);

  /// The original's poll as a frozen definition: labels and closes_at, no counts (see Poll). Unset when
  /// the original has no poll, in a tombstone, and when the embed is stripped (EMBED_VIEWER_STATE_PROTECTED).
  @$pb.TagNumber(10)
  Poll get poll => $_getN(9);
  @$pb.TagNumber(10)
  set poll(Poll value) => $_setField(10, value);
  @$pb.TagNumber(10)
  $core.bool hasPoll() => $_has(9);
  @$pb.TagNumber(10)
  void clearPoll() => $_clearField(10);
  @$pb.TagNumber(10)
  Poll ensurePoll() => $_ensure(9);

  @$pb.TagNumber(11)
  ArticlePreview get article => $_getN(10);
  @$pb.TagNumber(11)
  set article(ArticlePreview value) => $_setField(11, value);
  @$pb.TagNumber(11)
  $core.bool hasArticle() => $_has(10);
  @$pb.TagNumber(11)
  void clearArticle() => $_clearField(11);
  @$pb.TagNumber(11)
  ArticlePreview ensureArticle() => $_ensure(10);
}

class Post extends $pb.GeneratedMessage {
  factory Post({
    $core.String? postId,
    $1.AuthorSnapshot? author,
    PostKind? kind,
    $core.String? text,
    $core.Iterable<$1.MediaRef>? media,
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
    $0.Timestamp? createdAt,
    ReplyPolicy? replyPolicy,
    $core.bool? paidPartnership,
    $core.bool? madeWithAi,
    Poll? poll,
    CommunityRef? community,
    ArticlePreview? article,
    BeaconPreview? beacon,
    $fixnum.Int64? shareCount,
    $fixnum.Int64? viewCount,
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
    if (poll != null) result.poll = poll;
    if (community != null) result.community = community;
    if (article != null) result.article = article;
    if (beacon != null) result.beacon = beacon;
    if (shareCount != null) result.shareCount = shareCount;
    if (viewCount != null) result.viewCount = viewCount;
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
    ..aOM<$1.AuthorSnapshot>(2, _omitFieldNames ? '' : 'author',
        subBuilder: $1.AuthorSnapshot.$_createMessage)
    ..aE<PostKind>(3, _omitFieldNames ? '' : 'kind',
        enumValues: PostKind.values)
    ..aOS(4, _omitFieldNames ? '' : 'text')
    ..pPM<$1.MediaRef>(5, _omitFieldNames ? '' : 'media',
        subBuilder: $1.MediaRef.$_createMessage)
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
    ..aOM<$0.Timestamp>(17, _omitFieldNames ? '' : 'createdAt',
        subBuilder: $0.Timestamp.$_createMessage)
    ..aE<ReplyPolicy>(18, _omitFieldNames ? '' : 'replyPolicy',
        enumValues: ReplyPolicy.values)
    ..aOB(19, _omitFieldNames ? '' : 'paidPartnership')
    ..aOB(20, _omitFieldNames ? '' : 'madeWithAi')
    ..aOM<Poll>(21, _omitFieldNames ? '' : 'poll',
        subBuilder: Poll.$_createMessage)
    ..aOM<CommunityRef>(22, _omitFieldNames ? '' : 'community',
        subBuilder: CommunityRef.$_createMessage)
    ..aOM<ArticlePreview>(23, _omitFieldNames ? '' : 'article',
        subBuilder: ArticlePreview.$_createMessage)
    ..aOM<BeaconPreview>(24, _omitFieldNames ? '' : 'beacon',
        subBuilder: BeaconPreview.$_createMessage)
    ..aInt64(25, _omitFieldNames ? '' : 'shareCount')
    ..aInt64(26, _omitFieldNames ? '' : 'viewCount')
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
  $1.AuthorSnapshot get author => $_getN(1);
  @$pb.TagNumber(2)
  set author($1.AuthorSnapshot value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasAuthor() => $_has(1);
  @$pb.TagNumber(2)
  void clearAuthor() => $_clearField(2);
  @$pb.TagNumber(2)
  $1.AuthorSnapshot ensureAuthor() => $_ensure(1);

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
  $pb.PbList<$1.MediaRef> get media => $_getList(4);

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
  $0.Timestamp get createdAt => $_getN(16);
  @$pb.TagNumber(17)
  set createdAt($0.Timestamp value) => $_setField(17, value);
  @$pb.TagNumber(17)
  $core.bool hasCreatedAt() => $_has(16);
  @$pb.TagNumber(17)
  void clearCreatedAt() => $_clearField(17);
  @$pb.TagNumber(17)
  $0.Timestamp ensureCreatedAt() => $_ensure(16);

  /// Effective reply policy; on replies, the one inherited from the conversation. UNSPECIFIED ==
  /// EVERYONE.
  @$pb.TagNumber(18)
  ReplyPolicy get replyPolicy => $_getN(17);
  @$pb.TagNumber(18)
  set replyPolicy(ReplyPolicy value) => $_setField(18, value);
  @$pb.TagNumber(18)
  $core.bool hasReplyPolicy() => $_has(17);
  @$pb.TagNumber(18)
  void clearReplyPolicy() => $_clearField(18);

  /// User-asserted disclosure labels.
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

  /// The post's poll, root posts only; unset otherwise. Redacted per viewer (Poll.results_visible). Unset on a
  /// withheld row (PostView.withheld). Vote with dzeroth.engagement.v1.EngagementService.VotePoll.
  @$pb.TagNumber(21)
  Poll get poll => $_getN(20);
  @$pb.TagNumber(21)
  set poll(Poll value) => $_setField(21, value);
  @$pb.TagNumber(21)
  $core.bool hasPoll() => $_has(20);
  @$pb.TagNumber(21)
  void clearPoll() => $_clearField(21);
  @$pb.TagNumber(21)
  Poll ensurePoll() => $_ensure(20);

  /// The community the post was created in, for the label row. Set only on a root post or quote created
  /// with CreatePostRequest.community_id, while a community moderator has not hidden it and FEATURE_COMMUNITIES is not
  /// globally off (with it globally off community posts render as ordinary posts). Never on a reply, a REPOST row or an
  /// embed. Set on every surface that returns the post (Home, profile, lists, search, GetPost, GetThread, bookmarks),
  /// whatever the viewer's own flag. Unset on a withheld row. The label is not an access boundary: the post is public.
  @$pb.TagNumber(22)
  CommunityRef get community => $_getN(21);
  @$pb.TagNumber(22)
  set community(CommunityRef value) => $_setField(22, value);
  @$pb.TagNumber(22)
  $core.bool hasCommunity() => $_has(21);
  @$pb.TagNumber(22)
  void clearCommunity() => $_clearField(22);
  @$pb.TagNumber(22)
  CommunityRef ensureCommunity() => $_ensure(21);

  @$pb.TagNumber(23)
  ArticlePreview get article => $_getN(22);
  @$pb.TagNumber(23)
  set article(ArticlePreview value) => $_setField(23, value);
  @$pb.TagNumber(23)
  $core.bool hasArticle() => $_has(22);
  @$pb.TagNumber(23)
  void clearArticle() => $_clearField(23);
  @$pb.TagNumber(23)
  ArticlePreview ensureArticle() => $_ensure(22);

  /// The plan this post shares (CreatePostRequest.beacon_id), decided for the viewer of this response (BeaconPreview).
  /// Unset for a post with no plan, for a REPOST or QUOTE row (the card is on the original), and everywhere while
  /// FEATURE_POST_BEACON_EMBED is globally off.
  @$pb.TagNumber(24)
  BeaconPreview get beacon => $_getN(23);
  @$pb.TagNumber(24)
  set beacon(BeaconPreview value) => $_setField(24, value);
  @$pb.TagNumber(24)
  $core.bool hasBeacon() => $_has(23);
  @$pb.TagNumber(24)
  void clearBeacon() => $_clearField(24);
  @$pb.TagNumber(24)
  BeaconPreview ensureBeacon() => $_ensure(23);

  /// How many distinct accounts shared this post (other than its author): sent it in a direct message
  /// (MessagingService.SendMessage shared_post_id) or reported a copy-link / share-sheet share
  /// (dzeroth.engagement.v1.EngagementService.RecordPostShare). Each account counts at most once per post, whatever the
  /// channel and however often. Never says who shared or where. Kept on posts/{id}.shareCount by FieldValue.Increment
  /// with the per-account marker; an account deletion decrements it, like like_count. 0 on a REPOST row (read the
  /// embed's original), on a withheld row, and on posts that predate the field. Clients show it only when
  /// GetMe.enabled_features lists "share_count".
  @$pb.TagNumber(25)
  $fixnum.Int64 get shareCount => $_getI64(24);
  @$pb.TagNumber(25)
  set shareCount($fixnum.Int64 value) => $_setInt64(24, value);
  @$pb.TagNumber(25)
  $core.bool hasShareCount() => $_has(24);
  @$pb.TagNumber(25)
  void clearShareCount() => $_clearField(25);

  /// How many times the post was seen (F1 post views, FEATURE_POST_VIEWS): distinct (viewer, IST day) impressions
  /// reported through dzeroth.engagement.v1.EngagementService.RecordImpressions, the author's own views never counted. Presence is
  /// the visibility signal: the field is SET only when this response's viewer may see the count, and unset (has_view_count
  /// false) otherwise; clients render a count only when it is set. The hybrid rule:
  /// - the author always gets their own count (GetPost: the exact live sum of the counter shards; every other surface: the
  ///   value rolled up into posts/{id}.viewCount by the view rollup, at most about 20 minutes behind);
  /// - anyone else gets the rolled-up count only once it is at least the server's POST_VIEWS_PUBLIC_THRESHOLD (default
  ///   1000) AND the author is not protected; a protected author's count is the author's only, always.
  /// Unset on a REPOST row (read the embed's original), on an embed, on a withheld row, on surfaces that do not decide the
  /// author's protected state, and everywhere while FEATURE_POST_VIEWS is globally off. Never says who viewed. Additive.
  @$pb.TagNumber(26)
  $fixnum.Int64 get viewCount => $_getI64(25);
  @$pb.TagNumber(26)
  set viewCount($fixnum.Int64 value) => $_setInt64(25, value);
  @$pb.TagNumber(26)
  $core.bool hasViewCount() => $_has(25);
  @$pb.TagNumber(26)
  void clearViewCount() => $_clearField(26);
}

/// Bounded summary only. The reader fetches the authorized body separately.
class ArticlePreview extends $pb.GeneratedMessage {
  factory ArticlePreview({
    $core.String? articleId,
    $core.String? title,
    $core.String? excerpt,
    $core.String? coverUrl,
  }) {
    final result = ArticlePreview._();
    if (articleId != null) result.articleId = articleId;
    if (title != null) result.title = title;
    if (excerpt != null) result.excerpt = excerpt;
    if (coverUrl != null) result.coverUrl = coverUrl;
    return result;
  }

  ArticlePreview._();

  factory ArticlePreview.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ArticlePreview()..mergeFromBuffer(data, registry);
  factory ArticlePreview.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ArticlePreview()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ArticlePreview',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.posts.v1'),
      createEmptyInstance: ArticlePreview.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'articleId')
    ..aOS(2, _omitFieldNames ? '' : 'title')
    ..aOS(3, _omitFieldNames ? '' : 'excerpt')
    ..aOS(4, _omitFieldNames ? '' : 'coverUrl')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ArticlePreview clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ArticlePreview copyWith(void Function(ArticlePreview) updates) =>
      super.copyWith((message) => updates(message as ArticlePreview))
          as ArticlePreview;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use ArticlePreview() / ArticlePreview.new instead')
  static ArticlePreview create() => ArticlePreview._();
  static $pb.GeneratedMessage $_createMessage() => ArticlePreview._();
  @$core.override
  ArticlePreview createEmptyInstance() => ArticlePreview._();
  @$core.pragma('dart2js:noInline')
  static ArticlePreview getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<ArticlePreview>(
          ArticlePreview.$_createMessage);
  static ArticlePreview? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get articleId => $_getSZ(0);
  @$pb.TagNumber(1)
  set articleId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasArticleId() => $_has(0);
  @$pb.TagNumber(1)
  void clearArticleId() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get title => $_getSZ(1);
  @$pb.TagNumber(2)
  set title($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasTitle() => $_has(1);
  @$pb.TagNumber(2)
  void clearTitle() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get excerpt => $_getSZ(2);
  @$pb.TagNumber(3)
  set excerpt($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasExcerpt() => $_has(2);
  @$pb.TagNumber(3)
  void clearExcerpt() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.String get coverUrl => $_getSZ(3);
  @$pb.TagNumber(4)
  set coverUrl($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasCoverUrl() => $_has(3);
  @$pb.TagNumber(4)
  void clearCoverUrl() => $_clearField(4);
}

/// The community a post was created in. A snapshot taken at post time: a rename does not rewrite old
/// posts, while the community's own page and feed header show the current name. A tap opens the community
/// (dzeroth.communities.v1.CommunityService.GetCommunity, dzeroth.timeline.v1.TimelineService.GetCommunityTimeline),
/// only when GetMe.enabled_features lists "communities".
class CommunityRef extends $pb.GeneratedMessage {
  factory CommunityRef({
    $core.String? id,
    $core.String? name,
  }) {
    final result = CommunityRef._();
    if (id != null) result.id = id;
    if (name != null) result.name = name;
    return result;
  }

  CommunityRef._();

  factory CommunityRef.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CommunityRef()..mergeFromBuffer(data, registry);
  factory CommunityRef.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CommunityRef()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CommunityRef',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.posts.v1'),
      createEmptyInstance: CommunityRef.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'id')
    ..aOS(2, _omitFieldNames ? '' : 'name')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CommunityRef clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CommunityRef copyWith(void Function(CommunityRef) updates) =>
      super.copyWith((message) => updates(message as CommunityRef))
          as CommunityRef;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use CommunityRef() / CommunityRef.new instead')
  static CommunityRef create() => CommunityRef._();
  static $pb.GeneratedMessage $_createMessage() => CommunityRef._();
  @$core.override
  CommunityRef createEmptyInstance() => CommunityRef._();
  @$core.pragma('dart2js:noInline')
  static CommunityRef getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<CommunityRef>(
          CommunityRef.$_createMessage);
  static CommunityRef? _defaultInstance;

  /// 19-digit Snowflake.
  @$pb.TagNumber(1)
  $core.String get id => $_getSZ(0);
  @$pb.TagNumber(1)
  set id($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasId() => $_has(0);
  @$pb.TagNumber(1)
  void clearId() => $_clearField(1);

  /// The community's name when the post was created (1-30 code points).
  @$pb.TagNumber(2)
  $core.String get name => $_getSZ(1);
  @$pb.TagNumber(2)
  set name($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasName() => $_has(1);
  @$pb.TagNumber(2)
  void clearName() => $_clearField(2);
}

/// The plan a post shares (Post.beacon), always decided for the viewer of this response: when the viewer may see the plan,
/// every field is its live value (a snapshot frozen at create time is never put on the wire); otherwise only beacon_id and
/// unavailable = true are set ("Plan unavailable": a plan that is hidden, deleted, blocked, or a community plan the viewer
/// is no longer a member of). An ENDED or CANCELLED plan is still available: status says so. Producers that do not hydrate
/// plans (search, bookmarks, likes, article posts) emit the unavailable form. Join opens
/// dzeroth.beacons.v1.BeaconService.RequestToJoin, only when GetMe.enabled_features lists "beacons".
class BeaconPreview extends $pb.GeneratedMessage {
  factory BeaconPreview({
    $core.String? beaconId,
    $core.bool? unavailable,
    $core.String? title,
    $2.BeaconActivity? activity,
    $0.Timestamp? startAt,
    $2.BeaconStatus? status,
    $core.String? communityId,
  }) {
    final result = BeaconPreview._();
    if (beaconId != null) result.beaconId = beaconId;
    if (unavailable != null) result.unavailable = unavailable;
    if (title != null) result.title = title;
    if (activity != null) result.activity = activity;
    if (startAt != null) result.startAt = startAt;
    if (status != null) result.status = status;
    if (communityId != null) result.communityId = communityId;
    return result;
  }

  BeaconPreview._();

  factory BeaconPreview.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      BeaconPreview()..mergeFromBuffer(data, registry);
  factory BeaconPreview.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      BeaconPreview()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'BeaconPreview',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.posts.v1'),
      createEmptyInstance: BeaconPreview.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'beaconId')
    ..aOB(2, _omitFieldNames ? '' : 'unavailable')
    ..aOS(3, _omitFieldNames ? '' : 'title')
    ..aE<$2.BeaconActivity>(4, _omitFieldNames ? '' : 'activity',
        enumValues: $2.BeaconActivity.values)
    ..aOM<$0.Timestamp>(5, _omitFieldNames ? '' : 'startAt',
        subBuilder: $0.Timestamp.$_createMessage)
    ..aE<$2.BeaconStatus>(6, _omitFieldNames ? '' : 'status',
        enumValues: $2.BeaconStatus.values)
    ..aOS(7, _omitFieldNames ? '' : 'communityId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BeaconPreview clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BeaconPreview copyWith(void Function(BeaconPreview) updates) =>
      super.copyWith((message) => updates(message as BeaconPreview))
          as BeaconPreview;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use BeaconPreview() / BeaconPreview.new instead')
  static BeaconPreview create() => BeaconPreview._();
  static $pb.GeneratedMessage $_createMessage() => BeaconPreview._();
  @$core.override
  BeaconPreview createEmptyInstance() => BeaconPreview._();
  @$core.pragma('dart2js:noInline')
  static BeaconPreview getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<BeaconPreview>(
          BeaconPreview.$_createMessage);
  static BeaconPreview? _defaultInstance;

  /// 19-digit Snowflake of the plan.
  @$pb.TagNumber(1)
  $core.String get beaconId => $_getSZ(0);
  @$pb.TagNumber(1)
  set beaconId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasBeaconId() => $_has(0);
  @$pb.TagNumber(1)
  void clearBeaconId() => $_clearField(1);

  /// True when the viewer cannot see the plan; every field below is then empty.
  @$pb.TagNumber(2)
  $core.bool get unavailable => $_getBF(1);
  @$pb.TagNumber(2)
  set unavailable($core.bool value) => $_setBool(1, value);
  @$pb.TagNumber(2)
  $core.bool hasUnavailable() => $_has(1);
  @$pb.TagNumber(2)
  void clearUnavailable() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get title => $_getSZ(2);
  @$pb.TagNumber(3)
  set title($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasTitle() => $_has(2);
  @$pb.TagNumber(3)
  void clearTitle() => $_clearField(3);

  @$pb.TagNumber(4)
  $2.BeaconActivity get activity => $_getN(3);
  @$pb.TagNumber(4)
  set activity($2.BeaconActivity value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasActivity() => $_has(3);
  @$pb.TagNumber(4)
  void clearActivity() => $_clearField(4);

  @$pb.TagNumber(5)
  $0.Timestamp get startAt => $_getN(4);
  @$pb.TagNumber(5)
  set startAt($0.Timestamp value) => $_setField(5, value);
  @$pb.TagNumber(5)
  $core.bool hasStartAt() => $_has(4);
  @$pb.TagNumber(5)
  void clearStartAt() => $_clearField(5);
  @$pb.TagNumber(5)
  $0.Timestamp ensureStartAt() => $_ensure(4);

  /// Live: OPEN, FULL, CANCELLED, or ENDED (derived from the clock).
  @$pb.TagNumber(6)
  $2.BeaconStatus get status => $_getN(5);
  @$pb.TagNumber(6)
  set status($2.BeaconStatus value) => $_setField(6, value);
  @$pb.TagNumber(6)
  $core.bool hasStatus() => $_has(5);
  @$pb.TagNumber(6)
  void clearStatus() => $_clearField(6);

  /// The community the plan is scoped to; empty for a public plan.
  @$pb.TagNumber(7)
  $core.String get communityId => $_getSZ(6);
  @$pb.TagNumber(7)
  set communityId($core.String value) => $_setString(6, value);
  @$pb.TagNumber(7)
  $core.bool hasCommunityId() => $_has(6);
  @$pb.TagNumber(7)
  void clearCommunityId() => $_clearField(7);
}

/// A post as seen by the caller. Viewer flags come from userLikes/{uid} (cached 60 s) while
/// FEATURE_ENGAGEMENT or FEATURE_BOOKMARKS is on for the caller (liked / reposted only with engagement, bookmarked_by_viewer with either); otherwise all are false and no userLikes read happens.
/// For a REPOST item the flags describe the original (embedded.post_id): the caller liked / reposted it.
class PostView extends $pb.GeneratedMessage {
  factory PostView({
    Post? post,
    $core.bool? likedByViewer,
    $core.bool? repostedByViewer,
    ReplyPermission? viewerReplyPermission,
    EmbedViewerState? embedViewerState,
    $core.bool? bookmarkedByViewer,
    $core.bool? withheld,
    $core.int? viewerPollChoice,
    $core.bool? viewerPollVoteBlocked,
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
    if (withheld != null) result.withheld = withheld;
    if (viewerPollChoice != null) result.viewerPollChoice = viewerPollChoice;
    if (viewerPollVoteBlocked != null)
      result.viewerPollVoteBlocked = viewerPollVoteBlocked;
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
    ..aOB(7, _omitFieldNames ? '' : 'withheld')
    ..aI(8, _omitFieldNames ? '' : 'viewerPollChoice')
    ..aOB(9, _omitFieldNames ? '' : 'viewerPollVoteBlocked')
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

  /// Whether the caller may reply. Timelines decide it without a lookup for root posts only (EVERYONE, the
  /// viewer is the author, or MENTIONED_ONLY); a REPOST row uses embedded.reply_policy; anything else is UNKNOWN.
  /// A post in a community conversation: GetCommunityTimeline sets ALLOWED or NOT_ALLOWED from the
  /// viewer's role; GetPost and GetThread decide it from the caller's member doc; Home, profile, list and
  /// search timelines answer UNKNOWN (CreatePost decides).
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
  /// or MUTED: they drop such rows. PROTECTED is different: every surface that returns a
  /// QUOTE row, timelines and lists included, keeps the row and sets it, with the embed stripped; so does the caller's
  /// own REPOST on the caller's own profile.
  @$pb.TagNumber(5)
  EmbedViewerState get embedViewerState => $_getN(4);
  @$pb.TagNumber(5)
  set embedViewerState(EmbedViewerState value) => $_setField(5, value);
  @$pb.TagNumber(5)
  $core.bool hasEmbedViewerState() => $_has(4);
  @$pb.TagNumber(5)
  void clearEmbedViewerState() => $_clearField(5);

  /// Whether the caller bookmarked this item; true only for the caller, never another user's state. For a
  /// REPOST row it describes the original (embedded.post_id), like liked_by_viewer. Hydrated from userLikes.bookmarks, which
  /// FEATURE_ENGAGEMENT already reads (cached 60 s; read on its own when only FEATURE_BOOKMARKS is on); absent (false) when neither flag is on for the viewer. Staleness
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

  /// The server stripped this row's post to post_id, kind and the author snapshot because the caller may no longer see
  /// its protected author: no text, media, labels, hashtags, mentions, counts, reply fields,
  /// embed or timestamp. Set only on the caller's own Likes and Bookmarks lists (ListLikedPosts, ListBookmarks), where
  /// liked_by_viewer or bookmarked_by_viewer stays true; render the protected placeholder with the undo action (Unlike
  /// or Remove bookmark). The caller's own REPOST on their own profile uses embed_viewer_state = PROTECTED instead.
  /// False everywhere else.
  @$pb.TagNumber(7)
  $core.bool get withheld => $_getBF(6);
  @$pb.TagNumber(7)
  set withheld($core.bool value) => $_setBool(6, value);
  @$pb.TagNumber(7)
  $core.bool hasWithheld() => $_has(6);
  @$pb.TagNumber(7)
  void clearWithheld() => $_clearField(7);

  /// The caller's own vote in this item's poll: 0 = not voted (or not known: FEATURE_ENGAGEMENT off for
  /// the caller, or the vote is older than the newest 500 the server keeps for the check mark), 1-4 = choice index + 1.
  /// For a REPOST row it describes the original's poll (embedded.post_id), like liked_by_viewer. Hydrated from
  /// userLikes; staleness bound 60 s (the userLikes instance cache). Never another user's vote.
  /// 0 on a withheld row.
  @$pb.TagNumber(8)
  $core.int get viewerPollChoice => $_getIZ(7);
  @$pb.TagNumber(8)
  set viewerPollChoice($core.int value) => $_setSignedInt32(7, value);
  @$pb.TagNumber(8)
  $core.bool hasViewerPollChoice() => $_has(7);
  @$pb.TagNumber(8)
  void clearViewerPollChoice() => $_clearField(8);

  /// True when this item carries a live poll (not closed), the caller is not its author and the caller blocks the author:
  /// VotePoll then answers FAILED_PRECONDITION + TARGET_BLOCKED, so render the choices
  /// disabled ("You blocked @handle. Unblock to vote."). Negative polarity on purpose: false on every other row, on every
  /// producer that does not set it and on older revisions, which is the behaviour before the amendment; the server stays
  /// the authority. Set only where a post by a blocked author is shown directly (GetPost, GetThread, GetUserTimeline of
  /// that author); never on a REPOST row (an embedded poll has no buttons). False on a withheld row.
  @$pb.TagNumber(9)
  $core.bool get viewerPollVoteBlocked => $_getBF(8);
  @$pb.TagNumber(9)
  set viewerPollVoteBlocked($core.bool value) => $_setBool(8, value);
  @$pb.TagNumber(9)
  $core.bool hasViewerPollVoteBlocked() => $_has(8);
  @$pb.TagNumber(9)
  void clearViewerPollVoteBlocked() => $_clearField(9);
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
    PollDraft? poll,
    $core.String? communityId,
    $core.String? beaconId,
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
    if (poll != null) result.poll = poll;
    if (communityId != null) result.communityId = communityId;
    if (beaconId != null) result.beaconId = beaconId;
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
    ..aOM<PollDraft>(10, _omitFieldNames ? '' : 'poll',
        subBuilder: PollDraft.$_createMessage)
    ..aOS(11, _omitFieldNames ? '' : 'communityId')
    ..aOS(12, _omitFieldNames ? '' : 'beaconId')
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

  /// Root posts and quotes only; FEATURE_REPLY_AUDIENCE.
  @$pb.TagNumber(7)
  ReplyPolicy get replyPolicy => $_getN(6);
  @$pb.TagNumber(7)
  set replyPolicy(ReplyPolicy value) => $_setField(7, value);
  @$pb.TagNumber(7)
  $core.bool hasReplyPolicy() => $_has(6);
  @$pb.TagNumber(7)
  void clearReplyPolicy() => $_clearField(7);

  /// Disclosure labels; FEATURE_CONTENT_DISCLOSURE.
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

  /// A poll on a root post; FEATURE_POLLS. Rules in the CreatePost comment.
  @$pb.TagNumber(10)
  PollDraft get poll => $_getN(9);
  @$pb.TagNumber(10)
  set poll(PollDraft value) => $_setField(10, value);
  @$pb.TagNumber(10)
  $core.bool hasPoll() => $_has(9);
  @$pb.TagNumber(10)
  void clearPoll() => $_clearField(10);
  @$pb.TagNumber(10)
  PollDraft ensurePoll() => $_ensure(9);

  /// Post into this community: a 19-digit community id; root posts and quotes only, members only, no
  /// reply_policy other than EVERYONE; FEATURE_COMMUNITIES. "" => an ordinary post. Rules in the CreatePost comment.
  @$pb.TagNumber(11)
  $core.String get communityId => $_getSZ(10);
  @$pb.TagNumber(11)
  set communityId($core.String value) => $_setString(10, value);
  @$pb.TagNumber(11)
  $core.bool hasCommunityId() => $_has(10);
  @$pb.TagNumber(11)
  void clearCommunityId() => $_clearField(11);

  /// Share one of the caller's own OPEN or FULL plans on a root post: a 19-digit beacon id; FEATURE_POST_BEACON_EMBED.
  /// "" => no plan. Rules in the CreatePost comment.
  @$pb.TagNumber(12)
  $core.String get beaconId => $_getSZ(11);
  @$pb.TagNumber(12)
  set beaconId($core.String value) => $_setString(11, value);
  @$pb.TagNumber(12)
  $core.bool hasBeaconId() => $_has(11);
  @$pb.TagNumber(12)
  void clearBeaconId() => $_clearField(12);
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
  /// (deleted, author suspended/blocking, not public). Render a tombstone. Additive.
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

/// A post waiting to be published by the server. Kept 7 days after it reaches a terminal state.
class ScheduledPost extends $pb.GeneratedMessage {
  factory ScheduledPost({
    $core.String? scheduledId,
    $core.String? text,
    $core.Iterable<$1.MediaRef>? media,
    ReplyPolicy? replyPolicy,
    $core.bool? paidPartnership,
    $core.bool? madeWithAi,
    $0.Timestamp? publishAt,
    ScheduledPostStatus? status,
    $core.String? postId,
    ScheduledPostFailure? failure,
    $0.Timestamp? createdAt,
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
    ..pPM<$1.MediaRef>(3, _omitFieldNames ? '' : 'media',
        subBuilder: $1.MediaRef.$_createMessage)
    ..aE<ReplyPolicy>(4, _omitFieldNames ? '' : 'replyPolicy',
        enumValues: ReplyPolicy.values)
    ..aOB(5, _omitFieldNames ? '' : 'paidPartnership')
    ..aOB(6, _omitFieldNames ? '' : 'madeWithAi')
    ..aOM<$0.Timestamp>(7, _omitFieldNames ? '' : 'publishAt',
        subBuilder: $0.Timestamp.$_createMessage)
    ..aE<ScheduledPostStatus>(8, _omitFieldNames ? '' : 'status',
        enumValues: ScheduledPostStatus.values)
    ..aOS(9, _omitFieldNames ? '' : 'postId')
    ..aE<ScheduledPostFailure>(10, _omitFieldNames ? '' : 'failure',
        enumValues: ScheduledPostFailure.values)
    ..aOM<$0.Timestamp>(11, _omitFieldNames ? '' : 'createdAt',
        subBuilder: $0.Timestamp.$_createMessage)
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
  $pb.PbList<$1.MediaRef> get media => $_getList(2);

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
  $0.Timestamp get publishAt => $_getN(6);
  @$pb.TagNumber(7)
  set publishAt($0.Timestamp value) => $_setField(7, value);
  @$pb.TagNumber(7)
  $core.bool hasPublishAt() => $_has(6);
  @$pb.TagNumber(7)
  void clearPublishAt() => $_clearField(7);
  @$pb.TagNumber(7)
  $0.Timestamp ensurePublishAt() => $_ensure(6);

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
  $0.Timestamp get createdAt => $_getN(10);
  @$pb.TagNumber(11)
  set createdAt($0.Timestamp value) => $_setField(11, value);
  @$pb.TagNumber(11)
  $core.bool hasCreatedAt() => $_has(10);
  @$pb.TagNumber(11)
  void clearCreatedAt() => $_clearField(11);
  @$pb.TagNumber(11)
  $0.Timestamp ensureCreatedAt() => $_ensure(10);
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
    $0.Timestamp? publishAt,
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
    ..aOM<$0.Timestamp>(8, _omitFieldNames ? '' : 'publishAt',
        subBuilder: $0.Timestamp.$_createMessage)
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
  $0.Timestamp get publishAt => $_getN(7);
  @$pb.TagNumber(8)
  set publishAt($0.Timestamp value) => $_setField(8, value);
  @$pb.TagNumber(8)
  $core.bool hasPublishAt() => $_has(7);
  @$pb.TagNumber(8)
  void clearPublishAt() => $_clearField(8);
  @$pb.TagNumber(8)
  $0.Timestamp ensurePublishAt() => $_ensure(7);
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

class PublishScheduledPostNowRequest extends $pb.GeneratedMessage {
  factory PublishScheduledPostNowRequest({
    $core.String? idempotencyKey,
    $core.String? scheduledId,
  }) {
    final result = PublishScheduledPostNowRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (scheduledId != null) result.scheduledId = scheduledId;
    return result;
  }

  PublishScheduledPostNowRequest._();

  factory PublishScheduledPostNowRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      PublishScheduledPostNowRequest()..mergeFromBuffer(data, registry);
  factory PublishScheduledPostNowRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      PublishScheduledPostNowRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'PublishScheduledPostNowRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.posts.v1'),
      createEmptyInstance: PublishScheduledPostNowRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'scheduledId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PublishScheduledPostNowRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PublishScheduledPostNowRequest copyWith(
          void Function(PublishScheduledPostNowRequest) updates) =>
      super.copyWith(
              (message) => updates(message as PublishScheduledPostNowRequest))
          as PublishScheduledPostNowRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use PublishScheduledPostNowRequest() / PublishScheduledPostNowRequest.new instead')
  static PublishScheduledPostNowRequest create() =>
      PublishScheduledPostNowRequest._();
  static $pb.GeneratedMessage $_createMessage() =>
      PublishScheduledPostNowRequest._();
  @$core.override
  PublishScheduledPostNowRequest createEmptyInstance() =>
      PublishScheduledPostNowRequest._();
  @$core.pragma('dart2js:noInline')
  static PublishScheduledPostNowRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<PublishScheduledPostNowRequest>(
          PublishScheduledPostNowRequest.$_createMessage);
  static PublishScheduledPostNowRequest? _defaultInstance;

  /// Format-validated (16-64 characters of [A-Za-z0-9_-]); the operation is idempotent by state.
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

class PublishScheduledPostNowResponse extends $pb.GeneratedMessage {
  factory PublishScheduledPostNowResponse({
    ScheduledPost? scheduledPost,
  }) {
    final result = PublishScheduledPostNowResponse._();
    if (scheduledPost != null) result.scheduledPost = scheduledPost;
    return result;
  }

  PublishScheduledPostNowResponse._();

  factory PublishScheduledPostNowResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      PublishScheduledPostNowResponse()..mergeFromBuffer(data, registry);
  factory PublishScheduledPostNowResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      PublishScheduledPostNowResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'PublishScheduledPostNowResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.posts.v1'),
      createEmptyInstance: PublishScheduledPostNowResponse.$_createMessage)
    ..aOM<ScheduledPost>(1, _omitFieldNames ? '' : 'scheduledPost',
        subBuilder: ScheduledPost.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PublishScheduledPostNowResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PublishScheduledPostNowResponse copyWith(
          void Function(PublishScheduledPostNowResponse) updates) =>
      super.copyWith(
              (message) => updates(message as PublishScheduledPostNowResponse))
          as PublishScheduledPostNowResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use PublishScheduledPostNowResponse() / PublishScheduledPostNowResponse.new instead')
  static PublishScheduledPostNowResponse create() =>
      PublishScheduledPostNowResponse._();
  static $pb.GeneratedMessage $_createMessage() =>
      PublishScheduledPostNowResponse._();
  @$core.override
  PublishScheduledPostNowResponse createEmptyInstance() =>
      PublishScheduledPostNowResponse._();
  @$core.pragma('dart2js:noInline')
  static PublishScheduledPostNowResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<PublishScheduledPostNowResponse>(
          PublishScheduledPostNowResponse.$_createMessage);
  static PublishScheduledPostNowResponse? _defaultInstance;

  /// PUBLISHED with post_id set (text and media are cleared once published).
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

class UpdateScheduledPostRequest extends $pb.GeneratedMessage {
  factory UpdateScheduledPostRequest({
    $core.String? idempotencyKey,
    $core.String? scheduledId,
    $core.String? text,
    $0.Timestamp? publishAt,
    ReplyPolicy? replyPolicy,
  }) {
    final result = UpdateScheduledPostRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (scheduledId != null) result.scheduledId = scheduledId;
    if (text != null) result.text = text;
    if (publishAt != null) result.publishAt = publishAt;
    if (replyPolicy != null) result.replyPolicy = replyPolicy;
    return result;
  }

  UpdateScheduledPostRequest._();

  factory UpdateScheduledPostRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UpdateScheduledPostRequest()..mergeFromBuffer(data, registry);
  factory UpdateScheduledPostRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UpdateScheduledPostRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'UpdateScheduledPostRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.posts.v1'),
      createEmptyInstance: UpdateScheduledPostRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'scheduledId')
    ..aOS(3, _omitFieldNames ? '' : 'text')
    ..aOM<$0.Timestamp>(4, _omitFieldNames ? '' : 'publishAt',
        subBuilder: $0.Timestamp.$_createMessage)
    ..aE<ReplyPolicy>(5, _omitFieldNames ? '' : 'replyPolicy',
        enumValues: ReplyPolicy.values)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UpdateScheduledPostRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UpdateScheduledPostRequest copyWith(
          void Function(UpdateScheduledPostRequest) updates) =>
      super.copyWith(
              (message) => updates(message as UpdateScheduledPostRequest))
          as UpdateScheduledPostRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use UpdateScheduledPostRequest() / UpdateScheduledPostRequest.new instead')
  static UpdateScheduledPostRequest create() => UpdateScheduledPostRequest._();
  static $pb.GeneratedMessage $_createMessage() =>
      UpdateScheduledPostRequest._();
  @$core.override
  UpdateScheduledPostRequest createEmptyInstance() =>
      UpdateScheduledPostRequest._();
  @$core.pragma('dart2js:noInline')
  static UpdateScheduledPostRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<UpdateScheduledPostRequest>(
          UpdateScheduledPostRequest.$_createMessage);
  static UpdateScheduledPostRequest? _defaultInstance;

  /// Format-validated (16-64 characters of [A-Za-z0-9_-]); the operation is idempotent by state.
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

  /// CreatePost text rules. Unset keeps the stored text.
  @$pb.TagNumber(3)
  $core.String get text => $_getSZ(2);
  @$pb.TagNumber(3)
  set text($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasText() => $_has(2);
  @$pb.TagNumber(3)
  void clearText() => $_clearField(3);

  /// UTC; truncated to the minute. Unset keeps the stored time.
  @$pb.TagNumber(4)
  $0.Timestamp get publishAt => $_getN(3);
  @$pb.TagNumber(4)
  set publishAt($0.Timestamp value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasPublishAt() => $_has(3);
  @$pb.TagNumber(4)
  void clearPublishAt() => $_clearField(4);
  @$pb.TagNumber(4)
  $0.Timestamp ensurePublishAt() => $_ensure(3);

  /// Unset keeps the stored policy; UNSPECIFIED and EVERYONE both mean "everyone".
  @$pb.TagNumber(5)
  ReplyPolicy get replyPolicy => $_getN(4);
  @$pb.TagNumber(5)
  set replyPolicy(ReplyPolicy value) => $_setField(5, value);
  @$pb.TagNumber(5)
  $core.bool hasReplyPolicy() => $_has(4);
  @$pb.TagNumber(5)
  void clearReplyPolicy() => $_clearField(5);
}

class UpdateScheduledPostResponse extends $pb.GeneratedMessage {
  factory UpdateScheduledPostResponse({
    ScheduledPost? scheduledPost,
  }) {
    final result = UpdateScheduledPostResponse._();
    if (scheduledPost != null) result.scheduledPost = scheduledPost;
    return result;
  }

  UpdateScheduledPostResponse._();

  factory UpdateScheduledPostResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UpdateScheduledPostResponse()..mergeFromBuffer(data, registry);
  factory UpdateScheduledPostResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UpdateScheduledPostResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'UpdateScheduledPostResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.posts.v1'),
      createEmptyInstance: UpdateScheduledPostResponse.$_createMessage)
    ..aOM<ScheduledPost>(1, _omitFieldNames ? '' : 'scheduledPost',
        subBuilder: ScheduledPost.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UpdateScheduledPostResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UpdateScheduledPostResponse copyWith(
          void Function(UpdateScheduledPostResponse) updates) =>
      super.copyWith(
              (message) => updates(message as UpdateScheduledPostResponse))
          as UpdateScheduledPostResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use UpdateScheduledPostResponse() / UpdateScheduledPostResponse.new instead')
  static UpdateScheduledPostResponse create() =>
      UpdateScheduledPostResponse._();
  static $pb.GeneratedMessage $_createMessage() =>
      UpdateScheduledPostResponse._();
  @$core.override
  UpdateScheduledPostResponse createEmptyInstance() =>
      UpdateScheduledPostResponse._();
  @$core.pragma('dart2js:noInline')
  static UpdateScheduledPostResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<UpdateScheduledPostResponse>(
          UpdateScheduledPostResponse.$_createMessage);
  static UpdateScheduledPostResponse? _defaultInstance;

  /// The item after the edit (PENDING, with its text and media).
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
  /// Requires a verified email or a Google/Apple provider. No daily post quota: only the per-minute
  /// CreatePost bucket (10/min/uid per instance) limits how often a user posts.
  /// Not available while the sub-feature's flag is off for the caller: a non-empty reply_to_post_id
  /// (FEATURE_REPLIES), quote_of_post_id (FEATURE_ENGAGEMENT), media_ids / media_alt_texts (FEATURE_MEDIA), a
  /// reply_policy other than UNSPECIFIED (FEATURE_REPLY_AUDIENCE) or paid_partnership / made_with_ai true
  /// (FEATURE_CONTENT_DISCLOSURE) => FAILED_PRECONDITION + FEATURE_DISABLED with metadata["feature"] = "replies" |
  /// "quotes" | "media" | "reply_audience" | "content_disclosure" (first match in that order), before any lookup.
  /// Reply policy: settable on a root post or a quote only (a non-UNSPECIFIED value on a reply =>
  /// VALIDATION field "reply_policy"); FOLLOWING_OF_FOLLOWING and VERIFIED => VALIDATION field "reply_policy" ("not
  /// available yet"). UNSPECIFIED and EVERYONE are stored as absent. It covers the whole conversation: a reply stores
  /// the policy inherited from its parent. A reply into a FOLLOWING or MENTIONED_ONLY conversation is
  /// checked against the conversation root R after the parent visibility check: an unusable R (missing, not public,
  /// hidden, author not ACTIVE, a block in either direction, caller blockedBy overflow, or a quote root whose embedded
  /// author blocks the caller) => NOT_FOUND "post not found"; otherwise R's author always may reply, FOLLOWING needs
  /// R's author to follow the caller (graph cache 60 s), MENTIONED_ONLY needs the caller in R's mentions; else
  /// PERMISSION_DENIED + REPLY_NOT_ALLOWED (metadata["policy"]), with nothing stored under the idempotency key.
  /// Enforcement is not flag-gated.
  /// Disclosure: paid_partnership and made_with_ai are user-asserted labels, never rejected; copied
  /// into the embedded snapshot of quotes and reposts. Clients compare the returned post's reply_policy and labels
  /// with what they sent (UNSPECIFIED == EVERYONE) and warn on a mismatch.
  /// Quotes (plan engagement.md, FEATURE_ENGAGEMENT): quote_of_post_id is a 19-digit post id that must be visible
  /// to the caller by the GetPost rules (else NOT_FOUND "post not found", writing nothing). Quoting a REPOST quotes its
  /// original. A quote needs its own text or at least one image, cannot also set reply_to_post_id (VALIDATION), is
  /// kind QUOTE, a root post for feeds (never a reply), carries an embedded one-level snapshot of the quoted post
  /// frozen at write time, and increments the quoted post's quote_count in the same transaction.
  /// Deleting the quoted post replaces the embed with an unavailable tombstone (async job).
  /// Protected authors: quoting a protected account's post is refused for everyone but that account:
  /// a caller who may not see the post gets NOT_FOUND "post not found" (the visibility check above), and an approved
  /// follower gets FAILED_PRECONDITION + PROTECTED_ACCOUNT; both write nothing. A reply to such a post by an approved
  /// follower is allowed and is public: it shows its own text, never the parent's.
  /// Replies (plan replies-and-threads.md): reply_to_post_id is honoured when FEATURE_REPLIES is on for the caller (else
  /// FEATURE_DISABLED, metadata["feature"]="replies"). The parent must be visible to the caller by the GetPost
  /// rules (missing, deleted, hidden, suspended author or an author who blocks the caller => NOT_FOUND
  /// "post not found", writing nothing). The reply copies the parent's conversation_id, sets reply_to_handle, increments
  /// the parent's reply_count in the same transaction and is never fanned out to the home timeline.
  /// A reply writes the idempotency doc, the post, users.postsCount and the parent's replyCount.
  /// Reply audience: a reply into a restricted conversation (FOLLOWING / MENTIONED_ONLY root) is checked after
  /// the parent visibility check. The root and graph lookups behind it use 60 s caches.
  /// A refusal is PERMISSION_DENIED + ERROR_REASON_REPLY_NOT_ALLOWED with metadata "policy" = "following" | "mentioned_only",
  /// writes nothing and does the same lookups as the allowed path. A conversation root that is unusable for the caller (deleted, hidden, suspended or
  /// deleting author, or one who blocks the caller) is NOT_FOUND "post not found", never REPLY_NOT_ALLOWED.
  /// Media (FEATURE_MEDIA): media_ids are 1-4 distinct READY or READY_UNSCREENED POST images owned by the caller
  /// and not yet attached to a post; any other id (missing, someone else's, an avatar, PENDING, REJECTED, already
  /// used) => FAILED_PRECONDITION + MEDIA_NOT_READY, one answer for every cause. media_alt_texts is empty or
  /// parallel to media_ids, each <= 1,000 characters. A post with at least one image may have empty text. The
  /// image refs (url, thumb_url, size, blurhash, alt) are copied into the post; lists render thumb_url only.
  /// Text: CRLF/CR -> LF, TAB -> space, NFC, trim; empty, control characters other than LF, or bidi
  /// formatting controls (U+202A-U+202E, U+2066-U+2069) => VALIDATION field "text"; <= 280 code points, <= 10
  /// lines. Links are kept as typed and count toward the length (no server rewriting or previews).
  /// Mentions: "@" + handle (3-15 of [A-Za-z0-9_], not preceded by a letter/number/_@#/.:&$+-,
  /// never truncated); first 10 distinct, stored lower-cased as {user_id, handle}. Unknown handles stay plain
  /// text; mentions never depend on the block graph (a user who blocked the author is kept, so the response
  /// cannot reveal the block); mentioning a user the author blocks is allowed.
  /// Hashtags: "#" + 1-50 of letters/marks/numbers/_ (plus ZWJ/ZWNJ inside), >= 1 letter;
  /// lower-cased, first 10 distinct stored; the text is unchanged.
  /// One transaction: idempotency doc read fresh; Create idempotency doc + Create post +
  /// users.postsCount (+ parent replyCount / quoted quoteCount once those ship). The post id (and
  /// created_at) is drawn in each transaction attempt; the transaction has a 5 s deadline.
  /// Replay: idempotency doc exists => return the stored post (the post is read if not cached); a different body =>
  /// INVALID_ARGUMENT + IDEMPOTENCY_KEY_REUSED, writing nothing.
  /// Mention candidates in the text resolve their handles in one batch (at most 10). With n images the media docs are read
  /// in one batch inside the transaction and each gets postId set; a replay re-reads no media. Notifications for
  /// mentions and for the parent or quoted author are written asynchronously.
  /// Polls (FEATURE_POLLS, wire name "polls"): a set `poll` while polls is off for the caller =>
  /// FAILED_PRECONDITION + FEATURE_DISABLED metadata["feature"] = "polls", before any lookup, checked after "content_disclosure"
  /// in the order above. Root posts only, with non-empty text (the question) and no media: a poll together with
  /// media_ids, reply_to_post_id or quote_of_post_id, or with empty text => VALIDATION field "poll", writing nothing. 2-4
  /// choices, each 1-25 code points after the text rules (NFC, no control or bidi formatting characters, trimmed),
  /// distinct after NFC and case folding; mentions and hashtags in choices are not parsed. duration_minutes 5..10080
  /// (7 days). Otherwise VALIDATION field "poll". The server sets closes_at = created_at + duration. The poll is stored
  /// on the post doc itself. requestHash gains a poll suffix only when a poll is present, so a request
  /// without one replays exactly as before. Clients send `poll` only when GetMe.enabled_features lists "polls", and
  /// check that the returned post carries `poll` (an older server drops the field): if not, warn and offer delete.
  /// GIF media (FEATURE_GIF, wire name "gif"): a media id whose media is a GIF while gif is not enabled
  /// for the caller => FAILED_PRECONDITION + FEATURE_DISABLED metadata["feature"] = "gif", after the media reads inside
  /// the transaction (as a MEDIA_NOT_READY refusal), writing nothing. A GIF must be the only media item, else
  /// VALIDATION field "media_ids". MediaRef.content_type is copied from the media doc.
  /// Communities (FEATURE_COMMUNITIES, wire name "communities"; dzeroth.communities.v1 header):
  /// - community_id posts a root post or a quote into that community. A set community_id while communities is off for
  ///   the caller => FAILED_PRECONDITION + FEATURE_DISABLED metadata["feature"] = "communities", before any lookup,
  ///   checked after "polls" in the order above. Not 19 digits => VALIDATION field "community_id". With
  ///   reply_to_post_id => VALIDATION field "community_id" (a reply belongs to its root's conversation). With a
  ///   reply_policy other than UNSPECIFIED or EVERYONE => VALIDATION field "reply_policy" (F8: a community conversation
  ///   is members only and takes no policy of its own). Nothing is written.
  /// - Then, in this order (posts.CommunityGate): a protected caller => FAILED_PRECONDITION + PROTECTED_ACCOUNT, before any lookup
  ///   (F6; the interceptor's profile is held); a missing or SUSPENDED community => NOT_FOUND "community not found"
  ///   (byte-identical for both); an ARCHIVED one => FAILED_PRECONDITION + COMMUNITY_STATE metadata["reason"] =
  ///   "community_archived" (status from the 60 s community cache); inside the transaction the caller's member doc, read
  ///   fresh: BANNED => PERMISSION_DENIED + FORBIDDEN metadata["reason"] = "banned", not a member => "not_member" (a ban
  ///   made on another instance stops the next post at once); then
  ///   the in-memory cap of 20 posts per community per uid per IST day per instance => RATE_LIMITED metadata["limit"] =
  ///   "community_posts_per_community_daily". There is no persisted community post quota. Every refusal writes nothing.
  /// - Blocks with the community's owner or moderators never refuse a post. The post is an ordinary public
  ///   post (F6, F7): it also shows on the author's profile and in followers' Home, with Post.community as its label.
  /// - The post doc gets communityId, community {id, name} (the name from the cached community doc) and the conversation's
  ///   community in the same write. The request hash covers community_id only when it is set, so a request
  ///   without one replays exactly as before; the same key with another community_id => IDEMPOTENCY_KEY_REUSED.
  /// - The community is read through the cache and the member doc fresh in the transaction.
  /// - Clients send community_id only when GetMe.enabled_features lists "communities", and check that the returned post
  ///   carries `community` (an older server drops the field): if not, warn and offer delete.
  /// Replies in a community conversation: members only. Every reply inherits its parent's conversation
  /// community (the parent is already read). While communities is not globally off, and after the existing
  /// reply rules (a block either way => NOT_FOUND): a SUSPENDED community => NOT_FOUND "community not
  /// found"; an ARCHIVED one => COMMUNITY_STATE "community_archived"; a caller who is not a JOINED member (banned
  /// included) => PERMISSION_DENIED + FORBIDDEN metadata["reason"] = "not_member", writing nothing. The member doc is cached
  /// 60 s on this path, so a ban reaches other instances' reply path within 60 s. The community and member doc are cached. With communities globally off, community posts behave as
  /// ordinary posts: no label and no reply gate (the kill switch).
  /// Plan embeds (FEATURE_POST_BEACON_EMBED, wire name "post_beacon_embed"; dzeroth.beacons.v1 header): a set beacon_id
  /// shares one of the caller's own plans on a root post. A set beacon_id while the flag is off for the caller (or no plan
  /// reader is wired) => FAILED_PRECONDITION + FEATURE_DISABLED metadata["feature"] = "post_beacon_embed", before any lookup,
  /// checked after "polls" in the order above (the beacons flag, "beacons", must also be on for the caller). Not 19 digits,
  /// or together with reply_to_post_id, quote_of_post_id or a poll => VALIDATION field "beacon_id". Then, after the community
  /// gate and before mentions: a missing, hidden or someone else's plan => NOT_FOUND "beacon not found" (one message for all,
  /// so no plan leaks); an ENDED or CANCELLED one => FAILED_PRECONDITION metadata["reason"] = "ended" | "cancelled"; a
  /// community plan with a community_id other than its community => VALIDATION field "beacon_id" (a public plan may go in
  /// any post). The post doc stores beaconId and a frozen snapshot (title, activity, start_at, community); the request hash
  /// covers beacon_id only when it is set. Nothing is written on a refusal.
  $async.Future<CreatePostResponse> createPost(
          $pb.ClientContext? ctx, CreatePostRequest request) =>
      _client.invoke<CreatePostResponse>(
          ctx, 'PostService', 'CreatePost', request, CreatePostResponse());

  /// Delete own post. post_id must be 19 digits (else VALIDATION). Only the author's call deletes anything:
  /// another user's post, an unknown id and an already-deleted post all return success and write nothing,
  /// byte-identical, so the call reveals neither existence nor blocks. Replay => success.
  /// Sync: one batch Delete(post, Exists) + users.postsCount -1; a failed Exists precondition (a concurrent
  /// delete won) => success, writing nothing, so the counter is decremented exactly once. Instance caches are evicted
  /// locally; others converge in <= 60 s.
  /// Every deleted post publishes one `post_delete` job after the commit (Pub/Sub, no Firestore access on the
  /// request path). The job (idempotent, resumable) deletes its public image objects and media documents, its
  /// likes and reposts documents (and the REPOST posts docs those created), and replaces the embedded snapshot of
  /// quotes of it with an unavailable tombstone.
  /// Deleting a REPOST post doc is UndoRepost: its reposts/{originalId}_{uid} doc goes in the same batch and the
  /// original's repostCount is decremented best effort after the commit. Deleting a QUOTE decrements the quoted
  /// post's quoteCount best effort, like a reply's parent replyCount.
  $async.Future<DeletePostResponse> deletePost(
          $pb.ClientContext? ctx, DeletePostRequest request) =>
      _client.invoke<DeletePostResponse>(
          ctx, 'PostService', 'DeletePost', request, DeletePostResponse());

  /// A single post. NOT_FOUND ("post not found", byte-identical in every case) if the post is missing or
  /// deleted, hidden by visibility, the author blocks the caller, or the author is SUSPENDED, DELETING or gone.
  /// A caller who blocks or mutes the author still gets the post; the client shows a banner.
  /// Viewer flags are false and userLikes is not read while FEATURE_ENGAGEMENT and FEATURE_BOOKMARKS are both off for the caller;
  /// with either on they come from userLikes/{caller} (cache-first, 60 s): liked / reposted only with engagement, bookmarked_by_viewer with either. A REPOST or QUOTE whose embedded author
  /// blocks the caller is NOT_FOUND like a post by that author.
  /// Protected authors: a post by a protected account is NOT_FOUND (the same bytes) for a caller who is
  /// neither that account nor a follower of it, and so is a REPOST of such a post; a QUOTE of one is returned with
  /// embed_viewer_state = PROTECTED and its embed stripped of text and media. Post.visibility is FOLLOWERS while the
  /// author is protected. Decided from the instance-cached protected-author set.
  /// The caller's profile, the post, the author's status and the caller's graph are instance-cached 60 s; a blocked-by
  /// overflow also consults the author's graph.
  /// viewer_reply_permission: for a root post in a FOLLOWING conversation (viewer not the author) it uses the author's
  /// graph; a reply in a restricted conversation is always UNKNOWN. In a community conversation it is ALLOWED for a
  /// JOINED member and NOT_ALLOWED otherwise (from the caller's member doc, cached 60 s).
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
  /// Protected authors, for a caller who is neither the author nor a follower of it: a focal post by a
  /// protected account is NOT_FOUND; such a parent or root is unset with parent_unavailable / root_unavailable; reply
  /// rows by such an account are dropped (the page may be short); QUOTE embeds as in GetPost.
  /// Community moderation: a reply that a community's owner or a moderator hid
  /// (CommunityService.HideCommunityPost) is dropped from the page for every caller but its author (the page may be
  /// short), and as the parent it is unset with parent_unavailable = true; as the focal post it is returned as GetPost
  /// returns it, and the replies under it stay. A hidden root is unaffected. This holds whatever the state of
  /// FEATURE_COMMUNITIES.
  /// page_size: default 10 (first page), clamped to 1..30. Opaque page_token bound to
  /// the caller and the focal post.
  /// viewer_reply_permission: UNKNOWN when root_unavailable; otherwise computed from the root (for a FOLLOWING
  /// conversation, the root author's graph). In a community conversation ALLOWED for a JOINED member and NOT_ALLOWED
  /// otherwise (the caller's member doc).
  $async.Future<GetThreadResponse> getThread(
          $pb.ClientContext? ctx, GetThreadRequest request) =>
      _client.invoke<GetThreadResponse>(
          ctx, 'PostService', 'GetThread', request, GetThreadResponse());

  /// Scheduled posts. All three need FEATURE_POSTS. SchedulePost also needs FEATURE_SCHEDULED_POSTS on for the
  /// caller; ListScheduledPosts and CancelScheduledPost only need it not globally off, so a caller outside the allowlist or
  /// percent bucket can still list and cancel what they already scheduled. Otherwise FAILED_PRECONDITION +
  /// FEATURE_DISABLED (metadata["feature"] = "scheduled_posts" for the latter), before any lookup. They
  /// only ever touch users/{caller}/scheduled; another user's id is NOT_FOUND like an unknown id. They share the
  /// CreatePost rate-limit bucket. A published post is created by the server sweep (Cloud Scheduler, every 5 min),
  /// up to ~5 min after publish_at; an item more than 6 h late is FAILED EXPIRED instead of published.
  ///
  /// Polls and scheduled posts are not combined: this request has no poll field. GIF media are refused
  /// here: VALIDATION field "media_ids".
  /// Community posts are not scheduled: community_id is not accepted, so this request has no community_id
  /// field and a scheduled post is always an ordinary post. The composer hides its audience picker in schedule mode.
  /// Schedule a root post (no reply, quote or poll) with the CreatePost text and media rules, plus the media,
  /// reply_audience and content_disclosure sub-feature checks and a verified email, as CreatePost. publish_at is
  /// truncated to the whole minute (UTC) and must be within [now + 2 min, now + 60 d] by server time, else VALIDATION
  /// field "publish_at". Media are validated (owned, READY or READY_UNSCREENED, unattached) but not reserved: an image
  /// used elsewhere before publish fails the item MEDIA_UNAVAILABLE; it stays reachable by its public URL until then.
  /// Idempotency: the doc id is derived from (caller, idempotency_key); a replay returns the stored item (even after
  /// the lead time passed or a cap filled), a different effective body => IDEMPOTENCY_KEY_REUSED. A replay of a
  /// PUBLISHED, CANCELLED or FAILED item returns it without text or media.
  /// A call that gets a cap error (LIMIT_REACHED) may be a near-simultaneous duplicate of a call that just
  /// succeeded: keep the same idempotency_key and retry after any such error, and the retry returns the stored item.
  /// Caps: 25 pending (soft: counted outside the transaction, so concurrent calls can overshoot it by the number in
  /// flight) => LIMIT_REACHED metadata["limit"] = "scheduled_pending"; 3 pending within +/-4 min of publish_at (exact:
  /// counted inside the transaction, so concurrent calls cannot exceed it; a near-simultaneous duplicate that finds the
  /// window full is answered with the stored item) => LIMIT_REACHED "scheduled_window". There is no daily schedule quota and no daily posts quota at publish.
  /// The transaction reads quotas/{uid} and rewrites it unchanged (counting nothing) so racing schedules by one user
  /// conflict and the window cap stays exact.
  /// A replay and a refusal at the pending or window cap write nothing.
  $async.Future<SchedulePostResponse> schedulePost(
          $pb.ClientContext? ctx, SchedulePostRequest request) =>
      _client.invoke<SchedulePostResponse>(
          ctx, 'PostService', 'SchedulePost', request, SchedulePostResponse());

  /// The caller's PENDING and FAILED scheduled posts, publish_at ascending. page_size 0 => 20, clamped to 50; opaque
  /// page_token bound to the caller.
  $async.Future<ListScheduledPostsResponse> listScheduledPosts(
          $pb.ClientContext? ctx, ListScheduledPostsRequest request) =>
      _client.invoke<ListScheduledPostsResponse>(ctx, 'PostService',
          'ListScheduledPosts', request, ListScheduledPostsResponse());

  /// Cancel a PENDING item, or dismiss a FAILED one; returns the item's current state without text or media.
  /// Idempotent by state: an item already PUBLISHED (too late, not an error) or CANCELLED is returned unchanged, writing
  /// nothing. scheduled_id must match ^[0-9a-f]{32}$ (else VALIDATION); unknown => NOT_FOUND. idempotency_key is
  /// format-validated (VALIDATION when malformed) but not stored.
  /// Terminal items expire by TTL after SCHEDULED_TERMINAL_TTL (default 7 days).
  $async.Future<CancelScheduledPostResponse> cancelScheduledPost(
          $pb.ClientContext? ctx, CancelScheduledPostRequest request) =>
      _client.invoke<CancelScheduledPostResponse>(ctx, 'PostService',
          'CancelScheduledPost', request, CancelScheduledPostResponse());

  /// Publish a PENDING scheduled post immediately ("Post now"). Needs FEATURE_POSTS and FEATURE_SCHEDULED_POSTS on for
  /// the caller (FAILED_PRECONDITION + FEATURE_DISABLED, metadata["feature"] = "scheduled_posts"); shares the CreatePost
  /// rate-limit bucket. It runs the sweep's publish transaction (same code path), which re-reads the item as PENDING, so
  /// a race with the sweep or a cancel publishes at most once. The response is the item PUBLISHED with post_id. Idempotent
  /// by state: an item already PUBLISHED (a retry, or the sweep won) is returned unchanged. A CANCELLED item, or a FAILED
  /// one, is FAILED_PRECONDITION; if the publish transaction itself retires the item (media no longer available, account
  /// restricted) the response is the FAILED item. scheduled_id must match ^[0-9a-f]{32}$ (else VALIDATION); unknown =>
  /// NOT_FOUND. idempotency_key is format-validated (VALIDATION when malformed) but not stored.
  $async.Future<PublishScheduledPostNowResponse> publishScheduledPostNow(
          $pb.ClientContext? ctx, PublishScheduledPostNowRequest request) =>
      _client.invoke<PublishScheduledPostNowResponse>(
          ctx,
          'PostService',
          'PublishScheduledPostNow',
          request,
          PublishScheduledPostNowResponse());

  /// Edit a PENDING scheduled post. Needs FEATURE_POSTS and FEATURE_SCHEDULED_POSTS on for the caller. Only the fields
  /// that are set change; at least one must be set (else VALIDATION). text follows the CreatePost rules (a post that
  /// carries media may have empty text), publish_at the SchedulePost rules (truncated to the minute, within [now + 2 min,
  /// now + 60 d], and the +/-4 min window cap, LIMIT_REACHED "scheduled_window"), reply_policy the CreatePost rules
  /// (needs FEATURE_REPLY_AUDIENCE). Media and the labels are not editable. An item that is not PENDING (published,
  /// cancelled, failed) or whose stored publish_at is less than 60 s away is FAILED_PRECONDITION; unknown =>
  /// NOT_FOUND. Idempotent by state: an edit whose values already equal the stored ones writes nothing and returns the
  /// item. idempotency_key is format-validated but not stored. Shares the CreatePost rate-limit bucket.
  $async.Future<UpdateScheduledPostResponse> updateScheduledPost(
          $pb.ClientContext? ctx, UpdateScheduledPostRequest request) =>
      _client.invoke<UpdateScheduledPostResponse>(ctx, 'PostService',
          'UpdateScheduledPost', request, UpdateScheduledPostResponse());
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
