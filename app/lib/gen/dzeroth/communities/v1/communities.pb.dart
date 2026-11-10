// This is a generated file - do not edit.
//
// Generated from dzeroth/communities/v1/communities.proto.

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

import '../../common/v1/common.pb.dart' as $2;
import '../../graph/v1/graph.pb.dart' as $1;
import 'communities.pbenum.dart';

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

export 'communities.pbenum.dart';

/// One community rule, shown numbered in the community's About.
class CommunityRule extends $pb.GeneratedMessage {
  factory CommunityRule({
    $core.String? title,
    $core.String? text,
  }) {
    final result = CommunityRule._();
    if (title != null) result.title = title;
    if (text != null) result.text = text;
    return result;
  }

  CommunityRule._();

  factory CommunityRule.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CommunityRule()..mergeFromBuffer(data, registry);
  factory CommunityRule.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CommunityRule()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CommunityRule',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.communities.v1'),
      createEmptyInstance: CommunityRule.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'title')
    ..aOS(2, _omitFieldNames ? '' : 'text')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CommunityRule clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CommunityRule copyWith(void Function(CommunityRule) updates) =>
      super.copyWith((message) => updates(message as CommunityRule))
          as CommunityRule;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use CommunityRule() / CommunityRule.new instead')
  static CommunityRule create() => CommunityRule._();
  static $pb.GeneratedMessage $_createMessage() => CommunityRule._();
  @$core.override
  CommunityRule createEmptyInstance() => CommunityRule._();
  @$core.pragma('dart2js:noInline')
  static CommunityRule getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<CommunityRule>(
          CommunityRule.$_createMessage);
  static CommunityRule? _defaultInstance;

  /// 1-60 code points, single line.
  @$pb.TagNumber(1)
  $core.String get title => $_getSZ(0);
  @$pb.TagNumber(1)
  set title($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasTitle() => $_has(0);
  @$pb.TagNumber(1)
  void clearTitle() => $_clearField(1);

  /// 0-300 code points, the bio rules.
  @$pb.TagNumber(2)
  $core.String get text => $_getSZ(1);
  @$pb.TagNumber(2)
  set text($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasText() => $_has(1);
  @$pb.TagNumber(2)
  void clearText() => $_clearField(2);
}

/// A full replacement set of rules for UpdateCommunity. A message, so "leave the rules unchanged" (unset) differs from
/// "remove every rule" (set, empty).
class CommunityRuleList extends $pb.GeneratedMessage {
  factory CommunityRuleList({
    $core.Iterable<CommunityRule>? rules,
  }) {
    final result = CommunityRuleList._();
    if (rules != null) result.rules.addAll(rules);
    return result;
  }

  CommunityRuleList._();

  factory CommunityRuleList.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CommunityRuleList()..mergeFromBuffer(data, registry);
  factory CommunityRuleList.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CommunityRuleList()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CommunityRuleList',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.communities.v1'),
      createEmptyInstance: CommunityRuleList.$_createMessage)
    ..pPM<CommunityRule>(1, _omitFieldNames ? '' : 'rules',
        subBuilder: CommunityRule.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CommunityRuleList clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CommunityRuleList copyWith(void Function(CommunityRuleList) updates) =>
      super.copyWith((message) => updates(message as CommunityRuleList))
          as CommunityRuleList;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use CommunityRuleList() / CommunityRuleList.new instead')
  static CommunityRuleList create() => CommunityRuleList._();
  static $pb.GeneratedMessage $_createMessage() => CommunityRuleList._();
  @$core.override
  CommunityRuleList createEmptyInstance() => CommunityRuleList._();
  @$core.pragma('dart2js:noInline')
  static CommunityRuleList getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<CommunityRuleList>(
          CommunityRuleList.$_createMessage);
  static CommunityRuleList? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<CommunityRule> get rules => $_getList(0);
}

/// A community's header, built from the community doc and the caller's role without an extra lookup, so every surface returns
/// the same shape: GetCommunity, ListCommunities, ListMyCommunities, the mutations and the GetCommunityTimeline header.
/// Rules, the owner and the moderators need profile lookups and come only with GetCommunity (and the rules
/// with CreateCommunity and UpdateCommunity).
class Community extends $pb.GeneratedMessage {
  factory Community({
    $core.String? communityId,
    $core.String? name,
    $core.String? description,
    $fixnum.Int64? memberCount,
    CommunityStatus? status,
    CommunityVisibility? visibility,
    CommunityRole? viewerRole,
    $0.Timestamp? createdAt,
  }) {
    final result = Community._();
    if (communityId != null) result.communityId = communityId;
    if (name != null) result.name = name;
    if (description != null) result.description = description;
    if (memberCount != null) result.memberCount = memberCount;
    if (status != null) result.status = status;
    if (visibility != null) result.visibility = visibility;
    if (viewerRole != null) result.viewerRole = viewerRole;
    if (createdAt != null) result.createdAt = createdAt;
    return result;
  }

  Community._();

  factory Community.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Community()..mergeFromBuffer(data, registry);
  factory Community.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Community()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Community',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.communities.v1'),
      createEmptyInstance: Community.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'communityId')
    ..aOS(2, _omitFieldNames ? '' : 'name')
    ..aOS(3, _omitFieldNames ? '' : 'description')
    ..aInt64(4, _omitFieldNames ? '' : 'memberCount')
    ..aE<CommunityStatus>(5, _omitFieldNames ? '' : 'status',
        enumValues: CommunityStatus.values)
    ..aE<CommunityVisibility>(6, _omitFieldNames ? '' : 'visibility',
        enumValues: CommunityVisibility.values)
    ..aE<CommunityRole>(7, _omitFieldNames ? '' : 'viewerRole',
        enumValues: CommunityRole.values)
    ..aOM<$0.Timestamp>(8, _omitFieldNames ? '' : 'createdAt',
        subBuilder: $0.Timestamp.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Community clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Community copyWith(void Function(Community) updates) =>
      super.copyWith((message) => updates(message as Community)) as Community;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Community() / Community.new instead')
  static Community create() => Community._();
  static $pb.GeneratedMessage $_createMessage() => Community._();
  @$core.override
  Community createEmptyInstance() => Community._();
  @$core.pragma('dart2js:noInline')
  static Community getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Community>(Community.$_createMessage);
  static Community? _defaultInstance;

  /// 19-digit Snowflake.
  @$pb.TagNumber(1)
  $core.String get communityId => $_getSZ(0);
  @$pb.TagNumber(1)
  set communityId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasCommunityId() => $_has(0);
  @$pb.TagNumber(1)
  void clearCommunityId() => $_clearField(1);

  /// The current name (1-30 code points). Post labels keep the name the post was created with.
  @$pb.TagNumber(2)
  $core.String get name => $_getSZ(1);
  @$pb.TagNumber(2)
  set name($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasName() => $_has(1);
  @$pb.TagNumber(2)
  void clearName() => $_clearField(2);

  /// 0-160 code points.
  @$pb.TagNumber(3)
  $core.String get description => $_getSZ(2);
  @$pb.TagNumber(3)
  set description($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasDescription() => $_has(2);
  @$pb.TagNumber(3)
  void clearDescription() => $_clearField(3);

  /// JOINED members, the owner and moderators included; banned users never count. Up to 60 s stale (the community
  /// instance cache; JoinCommunity never reads the doc).
  @$pb.TagNumber(4)
  $fixnum.Int64 get memberCount => $_getI64(3);
  @$pb.TagNumber(4)
  set memberCount($fixnum.Int64 value) => $_setInt64(3, value);
  @$pb.TagNumber(4)
  $core.bool hasMemberCount() => $_has(3);
  @$pb.TagNumber(4)
  void clearMemberCount() => $_clearField(4);

  @$pb.TagNumber(5)
  CommunityStatus get status => $_getN(4);
  @$pb.TagNumber(5)
  set status(CommunityStatus value) => $_setField(5, value);
  @$pb.TagNumber(5)
  $core.bool hasStatus() => $_has(4);
  @$pb.TagNumber(5)
  void clearStatus() => $_clearField(5);

  @$pb.TagNumber(6)
  CommunityVisibility get visibility => $_getN(5);
  @$pb.TagNumber(6)
  set visibility(CommunityVisibility value) => $_setField(6, value);
  @$pb.TagNumber(6)
  $core.bool hasVisibility() => $_has(5);
  @$pb.TagNumber(6)
  void clearVisibility() => $_clearField(6);

  /// The caller's role in this community.
  @$pb.TagNumber(7)
  CommunityRole get viewerRole => $_getN(6);
  @$pb.TagNumber(7)
  set viewerRole(CommunityRole value) => $_setField(7, value);
  @$pb.TagNumber(7)
  $core.bool hasViewerRole() => $_has(6);
  @$pb.TagNumber(7)
  void clearViewerRole() => $_clearField(7);

  @$pb.TagNumber(8)
  $0.Timestamp get createdAt => $_getN(7);
  @$pb.TagNumber(8)
  set createdAt($0.Timestamp value) => $_setField(8, value);
  @$pb.TagNumber(8)
  $core.bool hasCreatedAt() => $_has(7);
  @$pb.TagNumber(8)
  void clearCreatedAt() => $_clearField(8);
  @$pb.TagNumber(8)
  $0.Timestamp ensureCreatedAt() => $_ensure(7);
}

/// One row of a community's member page.
class CommunityMember extends $pb.GeneratedMessage {
  factory CommunityMember({
    $1.UserListItem? user,
    CommunityRole? role,
  }) {
    final result = CommunityMember._();
    if (user != null) result.user = user;
    if (role != null) result.role = role;
    return result;
  }

  CommunityMember._();

  factory CommunityMember.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CommunityMember()..mergeFromBuffer(data, registry);
  factory CommunityMember.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CommunityMember()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CommunityMember',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.communities.v1'),
      createEmptyInstance: CommunityMember.$_createMessage)
    ..aOM<$1.UserListItem>(1, _omitFieldNames ? '' : 'user',
        subBuilder: $1.UserListItem.$_createMessage)
    ..aE<CommunityRole>(2, _omitFieldNames ? '' : 'role',
        enumValues: CommunityRole.values)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CommunityMember clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CommunityMember copyWith(void Function(CommunityMember) updates) =>
      super.copyWith((message) => updates(message as CommunityMember))
          as CommunityMember;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use CommunityMember() / CommunityMember.new instead')
  static CommunityMember create() => CommunityMember._();
  static $pb.GeneratedMessage $_createMessage() => CommunityMember._();
  @$core.override
  CommunityMember createEmptyInstance() => CommunityMember._();
  @$core.pragma('dart2js:noInline')
  static CommunityMember getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<CommunityMember>(
          CommunityMember.$_createMessage);
  static CommunityMember? _defaultInstance;

  /// Live row (identity.Directory, up to 60 s stale) with the caller's relationship; since = joinedAt for a JOINED
  /// member, bannedAt for a banned user.
  @$pb.TagNumber(1)
  $1.UserListItem get user => $_getN(0);
  @$pb.TagNumber(1)
  set user($1.UserListItem value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasUser() => $_has(0);
  @$pb.TagNumber(1)
  void clearUser() => $_clearField(1);
  @$pb.TagNumber(1)
  $1.UserListItem ensureUser() => $_ensure(0);

  /// OWNER, MODERATOR or MEMBER on the JOINED page; BANNED on the BANNED page.
  @$pb.TagNumber(2)
  CommunityRole get role => $_getN(1);
  @$pb.TagNumber(2)
  set role(CommunityRole value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasRole() => $_has(1);
  @$pb.TagNumber(2)
  void clearRole() => $_clearField(2);
}

/// One moderation-log entry. Never names a post's author.
class ModerationLogEntry extends $pb.GeneratedMessage {
  factory ModerationLogEntry({
    $fixnum.Int64? seq,
    $0.Timestamp? at,
    ModerationLogAction? action,
    $2.AuthorSnapshot? actor,
    $core.bool? actorDeleted,
    $2.AuthorSnapshot? target,
    $core.bool? targetDeleted,
    $core.String? postId,
  }) {
    final result = ModerationLogEntry._();
    if (seq != null) result.seq = seq;
    if (at != null) result.at = at;
    if (action != null) result.action = action;
    if (actor != null) result.actor = actor;
    if (actorDeleted != null) result.actorDeleted = actorDeleted;
    if (target != null) result.target = target;
    if (targetDeleted != null) result.targetDeleted = targetDeleted;
    if (postId != null) result.postId = postId;
    return result;
  }

  ModerationLogEntry._();

  factory ModerationLogEntry.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ModerationLogEntry()..mergeFromBuffer(data, registry);
  factory ModerationLogEntry.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ModerationLogEntry()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ModerationLogEntry',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.communities.v1'),
      createEmptyInstance: ModerationLogEntry.$_createMessage)
    ..aInt64(1, _omitFieldNames ? '' : 'seq')
    ..aOM<$0.Timestamp>(2, _omitFieldNames ? '' : 'at',
        subBuilder: $0.Timestamp.$_createMessage)
    ..aE<ModerationLogAction>(3, _omitFieldNames ? '' : 'action',
        enumValues: ModerationLogAction.values)
    ..aOM<$2.AuthorSnapshot>(4, _omitFieldNames ? '' : 'actor',
        subBuilder: $2.AuthorSnapshot.$_createMessage)
    ..aOB(5, _omitFieldNames ? '' : 'actorDeleted')
    ..aOM<$2.AuthorSnapshot>(6, _omitFieldNames ? '' : 'target',
        subBuilder: $2.AuthorSnapshot.$_createMessage)
    ..aOB(7, _omitFieldNames ? '' : 'targetDeleted')
    ..aOS(8, _omitFieldNames ? '' : 'postId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ModerationLogEntry clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ModerationLogEntry copyWith(void Function(ModerationLogEntry) updates) =>
      super.copyWith((message) => updates(message as ModerationLogEntry))
          as ModerationLogEntry;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use ModerationLogEntry() / ModerationLogEntry.new instead')
  static ModerationLogEntry create() => ModerationLogEntry._();
  static $pb.GeneratedMessage $_createMessage() => ModerationLogEntry._();
  @$core.override
  ModerationLogEntry createEmptyInstance() => ModerationLogEntry._();
  @$core.pragma('dart2js:noInline')
  static ModerationLogEntry getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ModerationLogEntry>(
          ModerationLogEntry.$_createMessage);
  static ModerationLogEntry? _defaultInstance;

  /// Increases by one per entry in this community; the page cursor carries it.
  @$pb.TagNumber(1)
  $fixnum.Int64 get seq => $_getI64(0);
  @$pb.TagNumber(1)
  set seq($fixnum.Int64 value) => $_setInt64(0, value);
  @$pb.TagNumber(1)
  $core.bool hasSeq() => $_has(0);
  @$pb.TagNumber(1)
  void clearSeq() => $_clearField(1);

  /// Server time of the action.
  @$pb.TagNumber(2)
  $0.Timestamp get at => $_getN(1);
  @$pb.TagNumber(2)
  set at($0.Timestamp value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasAt() => $_has(1);
  @$pb.TagNumber(2)
  void clearAt() => $_clearField(2);
  @$pb.TagNumber(2)
  $0.Timestamp ensureAt() => $_ensure(1);

  @$pb.TagNumber(3)
  ModerationLogAction get action => $_getN(2);
  @$pb.TagNumber(3)
  set action(ModerationLogAction value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasAction() => $_has(2);
  @$pb.TagNumber(3)
  void clearAction() => $_clearField(3);

  /// Who acted: a live row (identity.Directory, up to 60 s stale; is_private unset). Unset when actor_deleted. Unset
  /// with actor_deleted false: the platform acted (opsctl); render it as the platform,
  /// never as a person.
  @$pb.TagNumber(4)
  $2.AuthorSnapshot get actor => $_getN(3);
  @$pb.TagNumber(4)
  set actor($2.AuthorSnapshot value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasActor() => $_has(3);
  @$pb.TagNumber(4)
  void clearActor() => $_clearField(4);
  @$pb.TagNumber(4)
  $2.AuthorSnapshot ensureActor() => $_ensure(3);

  /// True when the actor deleted the account: render "Deleted account".
  @$pb.TagNumber(5)
  $core.bool get actorDeleted => $_getBF(4);
  @$pb.TagNumber(5)
  set actorDeleted($core.bool value) => $_setBool(4, value);
  @$pb.TagNumber(5)
  $core.bool hasActorDeleted() => $_has(4);
  @$pb.TagNumber(5)
  void clearActorDeleted() => $_clearField(5);

  /// The user acted on: set for BAN, UNBAN, MAKE_MODERATOR, REMOVE_MODERATOR and OWNER_HANDOVER (the new owner); a live
  /// row like actor. Unset when target_deleted, and for an OWNER_HANDOVER that archived the community.
  @$pb.TagNumber(6)
  $2.AuthorSnapshot get target => $_getN(5);
  @$pb.TagNumber(6)
  set target($2.AuthorSnapshot value) => $_setField(6, value);
  @$pb.TagNumber(6)
  $core.bool hasTarget() => $_has(5);
  @$pb.TagNumber(6)
  void clearTarget() => $_clearField(6);
  @$pb.TagNumber(6)
  $2.AuthorSnapshot ensureTarget() => $_ensure(5);

  /// True when the target deleted the account: render "Deleted account".
  @$pb.TagNumber(7)
  $core.bool get targetDeleted => $_getBF(6);
  @$pb.TagNumber(7)
  set targetDeleted($core.bool value) => $_setBool(6, value);
  @$pb.TagNumber(7)
  $core.bool hasTargetDeleted() => $_has(6);
  @$pb.TagNumber(7)
  void clearTargetDeleted() => $_clearField(7);

  /// The post or reply hidden or restored (HIDE, RESTORE); "" otherwise, and for the platform's bulk RESTORE.
  @$pb.TagNumber(8)
  $core.String get postId => $_getSZ(7);
  @$pb.TagNumber(8)
  set postId($core.String value) => $_setString(7, value);
  @$pb.TagNumber(8)
  $core.bool hasPostId() => $_has(7);
  @$pb.TagNumber(8)
  void clearPostId() => $_clearField(8);
}

class CreateCommunityRequest extends $pb.GeneratedMessage {
  factory CreateCommunityRequest({
    $core.String? idempotencyKey,
    $core.String? name,
    $core.String? description,
    $core.Iterable<CommunityRule>? rules,
  }) {
    final result = CreateCommunityRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (name != null) result.name = name;
    if (description != null) result.description = description;
    if (rules != null) result.rules.addAll(rules);
    return result;
  }

  CreateCommunityRequest._();

  factory CreateCommunityRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CreateCommunityRequest()..mergeFromBuffer(data, registry);
  factory CreateCommunityRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CreateCommunityRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CreateCommunityRequest',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.communities.v1'),
      createEmptyInstance: CreateCommunityRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'name')
    ..aOS(3, _omitFieldNames ? '' : 'description')
    ..pPM<CommunityRule>(4, _omitFieldNames ? '' : 'rules',
        subBuilder: CommunityRule.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateCommunityRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateCommunityRequest copyWith(
          void Function(CreateCommunityRequest) updates) =>
      super.copyWith((message) => updates(message as CreateCommunityRequest))
          as CreateCommunityRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use CreateCommunityRequest() / CreateCommunityRequest.new instead')
  static CreateCommunityRequest create() => CreateCommunityRequest._();
  static $pb.GeneratedMessage $_createMessage() => CreateCommunityRequest._();
  @$core.override
  CreateCommunityRequest createEmptyInstance() => CreateCommunityRequest._();
  @$core.pragma('dart2js:noInline')
  static CreateCommunityRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<CreateCommunityRequest>(
          CreateCommunityRequest.$_createMessage);
  static CreateCommunityRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  /// 1-30 code points after NFC and trim.
  @$pb.TagNumber(2)
  $core.String get name => $_getSZ(1);
  @$pb.TagNumber(2)
  set name($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasName() => $_has(1);
  @$pb.TagNumber(2)
  void clearName() => $_clearField(2);

  /// 0-160 code points after NFC and trim.
  @$pb.TagNumber(3)
  $core.String get description => $_getSZ(2);
  @$pb.TagNumber(3)
  set description($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasDescription() => $_has(2);
  @$pb.TagNumber(3)
  void clearDescription() => $_clearField(3);

  /// At most 10, in display order.
  @$pb.TagNumber(4)
  $pb.PbList<CommunityRule> get rules => $_getList(3);
}

class CreateCommunityResponse extends $pb.GeneratedMessage {
  factory CreateCommunityResponse({
    Community? community,
    $core.Iterable<CommunityRule>? rules,
  }) {
    final result = CreateCommunityResponse._();
    if (community != null) result.community = community;
    if (rules != null) result.rules.addAll(rules);
    return result;
  }

  CreateCommunityResponse._();

  factory CreateCommunityResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CreateCommunityResponse()..mergeFromBuffer(data, registry);
  factory CreateCommunityResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CreateCommunityResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CreateCommunityResponse',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.communities.v1'),
      createEmptyInstance: CreateCommunityResponse.$_createMessage)
    ..aOM<Community>(1, _omitFieldNames ? '' : 'community',
        subBuilder: Community.$_createMessage)
    ..pPM<CommunityRule>(2, _omitFieldNames ? '' : 'rules',
        subBuilder: CommunityRule.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateCommunityResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateCommunityResponse copyWith(
          void Function(CreateCommunityResponse) updates) =>
      super.copyWith((message) => updates(message as CreateCommunityResponse))
          as CreateCommunityResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use CreateCommunityResponse() / CreateCommunityResponse.new instead')
  static CreateCommunityResponse create() => CreateCommunityResponse._();
  static $pb.GeneratedMessage $_createMessage() => CreateCommunityResponse._();
  @$core.override
  CreateCommunityResponse createEmptyInstance() => CreateCommunityResponse._();
  @$core.pragma('dart2js:noInline')
  static CreateCommunityResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<CreateCommunityResponse>(
          CreateCommunityResponse.$_createMessage);
  static CreateCommunityResponse? _defaultInstance;

  @$pb.TagNumber(1)
  Community get community => $_getN(0);
  @$pb.TagNumber(1)
  set community(Community value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasCommunity() => $_has(0);
  @$pb.TagNumber(1)
  void clearCommunity() => $_clearField(1);
  @$pb.TagNumber(1)
  Community ensureCommunity() => $_ensure(0);

  /// The stored rules, after the text rules.
  @$pb.TagNumber(2)
  $pb.PbList<CommunityRule> get rules => $_getList(1);
}

class UpdateCommunityRequest extends $pb.GeneratedMessage {
  factory UpdateCommunityRequest({
    $core.String? idempotencyKey,
    $core.String? communityId,
    $core.String? name,
    $core.String? description,
    CommunityRuleList? rules,
  }) {
    final result = UpdateCommunityRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (communityId != null) result.communityId = communityId;
    if (name != null) result.name = name;
    if (description != null) result.description = description;
    if (rules != null) result.rules = rules;
    return result;
  }

  UpdateCommunityRequest._();

  factory UpdateCommunityRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UpdateCommunityRequest()..mergeFromBuffer(data, registry);
  factory UpdateCommunityRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UpdateCommunityRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'UpdateCommunityRequest',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.communities.v1'),
      createEmptyInstance: UpdateCommunityRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'communityId')
    ..aOS(3, _omitFieldNames ? '' : 'name')
    ..aOS(4, _omitFieldNames ? '' : 'description')
    ..aOM<CommunityRuleList>(5, _omitFieldNames ? '' : 'rules',
        subBuilder: CommunityRuleList.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UpdateCommunityRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UpdateCommunityRequest copyWith(
          void Function(UpdateCommunityRequest) updates) =>
      super.copyWith((message) => updates(message as UpdateCommunityRequest))
          as UpdateCommunityRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use UpdateCommunityRequest() / UpdateCommunityRequest.new instead')
  static UpdateCommunityRequest create() => UpdateCommunityRequest._();
  static $pb.GeneratedMessage $_createMessage() => UpdateCommunityRequest._();
  @$core.override
  UpdateCommunityRequest createEmptyInstance() => UpdateCommunityRequest._();
  @$core.pragma('dart2js:noInline')
  static UpdateCommunityRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<UpdateCommunityRequest>(
          UpdateCommunityRequest.$_createMessage);
  static UpdateCommunityRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get communityId => $_getSZ(1);
  @$pb.TagNumber(2)
  set communityId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasCommunityId() => $_has(1);
  @$pb.TagNumber(2)
  void clearCommunityId() => $_clearField(2);

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

  /// Set => replaces every rule (an empty list removes them all); unset => the rules stay.
  @$pb.TagNumber(5)
  CommunityRuleList get rules => $_getN(4);
  @$pb.TagNumber(5)
  set rules(CommunityRuleList value) => $_setField(5, value);
  @$pb.TagNumber(5)
  $core.bool hasRules() => $_has(4);
  @$pb.TagNumber(5)
  void clearRules() => $_clearField(5);
  @$pb.TagNumber(5)
  CommunityRuleList ensureRules() => $_ensure(4);
}

class UpdateCommunityResponse extends $pb.GeneratedMessage {
  factory UpdateCommunityResponse({
    Community? community,
    $core.Iterable<CommunityRule>? rules,
  }) {
    final result = UpdateCommunityResponse._();
    if (community != null) result.community = community;
    if (rules != null) result.rules.addAll(rules);
    return result;
  }

  UpdateCommunityResponse._();

  factory UpdateCommunityResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UpdateCommunityResponse()..mergeFromBuffer(data, registry);
  factory UpdateCommunityResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UpdateCommunityResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'UpdateCommunityResponse',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.communities.v1'),
      createEmptyInstance: UpdateCommunityResponse.$_createMessage)
    ..aOM<Community>(1, _omitFieldNames ? '' : 'community',
        subBuilder: Community.$_createMessage)
    ..pPM<CommunityRule>(2, _omitFieldNames ? '' : 'rules',
        subBuilder: CommunityRule.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UpdateCommunityResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UpdateCommunityResponse copyWith(
          void Function(UpdateCommunityResponse) updates) =>
      super.copyWith((message) => updates(message as UpdateCommunityResponse))
          as UpdateCommunityResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use UpdateCommunityResponse() / UpdateCommunityResponse.new instead')
  static UpdateCommunityResponse create() => UpdateCommunityResponse._();
  static $pb.GeneratedMessage $_createMessage() => UpdateCommunityResponse._();
  @$core.override
  UpdateCommunityResponse createEmptyInstance() => UpdateCommunityResponse._();
  @$core.pragma('dart2js:noInline')
  static UpdateCommunityResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<UpdateCommunityResponse>(
          UpdateCommunityResponse.$_createMessage);
  static UpdateCommunityResponse? _defaultInstance;

  @$pb.TagNumber(1)
  Community get community => $_getN(0);
  @$pb.TagNumber(1)
  set community(Community value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasCommunity() => $_has(0);
  @$pb.TagNumber(1)
  void clearCommunity() => $_clearField(1);
  @$pb.TagNumber(1)
  Community ensureCommunity() => $_ensure(0);

  /// The stored rules after the update.
  @$pb.TagNumber(2)
  $pb.PbList<CommunityRule> get rules => $_getList(1);
}

class GetCommunityRequest extends $pb.GeneratedMessage {
  factory GetCommunityRequest({
    $core.String? communityId,
  }) {
    final result = GetCommunityRequest._();
    if (communityId != null) result.communityId = communityId;
    return result;
  }

  GetCommunityRequest._();

  factory GetCommunityRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetCommunityRequest()..mergeFromBuffer(data, registry);
  factory GetCommunityRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetCommunityRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetCommunityRequest',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.communities.v1'),
      createEmptyInstance: GetCommunityRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'communityId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetCommunityRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetCommunityRequest copyWith(void Function(GetCommunityRequest) updates) =>
      super.copyWith((message) => updates(message as GetCommunityRequest))
          as GetCommunityRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core
      .Deprecated('Use GetCommunityRequest() / GetCommunityRequest.new instead')
  static GetCommunityRequest create() => GetCommunityRequest._();
  static $pb.GeneratedMessage $_createMessage() => GetCommunityRequest._();
  @$core.override
  GetCommunityRequest createEmptyInstance() => GetCommunityRequest._();
  @$core.pragma('dart2js:noInline')
  static GetCommunityRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<GetCommunityRequest>(
          GetCommunityRequest.$_createMessage);
  static GetCommunityRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get communityId => $_getSZ(0);
  @$pb.TagNumber(1)
  set communityId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasCommunityId() => $_has(0);
  @$pb.TagNumber(1)
  void clearCommunityId() => $_clearField(1);
}

class GetCommunityResponse extends $pb.GeneratedMessage {
  factory GetCommunityResponse({
    Community? community,
    $core.Iterable<CommunityRule>? rules,
    $1.UserListItem? owner,
    $core.Iterable<$1.UserListItem>? moderators,
  }) {
    final result = GetCommunityResponse._();
    if (community != null) result.community = community;
    if (rules != null) result.rules.addAll(rules);
    if (owner != null) result.owner = owner;
    if (moderators != null) result.moderators.addAll(moderators);
    return result;
  }

  GetCommunityResponse._();

  factory GetCommunityResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetCommunityResponse()..mergeFromBuffer(data, registry);
  factory GetCommunityResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetCommunityResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetCommunityResponse',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.communities.v1'),
      createEmptyInstance: GetCommunityResponse.$_createMessage)
    ..aOM<Community>(1, _omitFieldNames ? '' : 'community',
        subBuilder: Community.$_createMessage)
    ..pPM<CommunityRule>(2, _omitFieldNames ? '' : 'rules',
        subBuilder: CommunityRule.$_createMessage)
    ..aOM<$1.UserListItem>(3, _omitFieldNames ? '' : 'owner',
        subBuilder: $1.UserListItem.$_createMessage)
    ..pPM<$1.UserListItem>(4, _omitFieldNames ? '' : 'moderators',
        subBuilder: $1.UserListItem.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetCommunityResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetCommunityResponse copyWith(void Function(GetCommunityResponse) updates) =>
      super.copyWith((message) => updates(message as GetCommunityResponse))
          as GetCommunityResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use GetCommunityResponse() / GetCommunityResponse.new instead')
  static GetCommunityResponse create() => GetCommunityResponse._();
  static $pb.GeneratedMessage $_createMessage() => GetCommunityResponse._();
  @$core.override
  GetCommunityResponse createEmptyInstance() => GetCommunityResponse._();
  @$core.pragma('dart2js:noInline')
  static GetCommunityResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<GetCommunityResponse>(
          GetCommunityResponse.$_createMessage);
  static GetCommunityResponse? _defaultInstance;

  @$pb.TagNumber(1)
  Community get community => $_getN(0);
  @$pb.TagNumber(1)
  set community(Community value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasCommunity() => $_has(0);
  @$pb.TagNumber(1)
  void clearCommunity() => $_clearField(1);
  @$pb.TagNumber(1)
  Community ensureCommunity() => $_ensure(0);

  /// In display order; the community's About numbers them.
  @$pb.TagNumber(2)
  $pb.PbList<CommunityRule> get rules => $_getList(1);

  /// Unset when the community has no owner (ARCHIVED, F12) or the owner is not ACTIVE. since is unset.
  @$pb.TagNumber(3)
  $1.UserListItem get owner => $_getN(2);
  @$pb.TagNumber(3)
  set owner($1.UserListItem value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasOwner() => $_has(2);
  @$pb.TagNumber(3)
  void clearOwner() => $_clearField(3);
  @$pb.TagNumber(3)
  $1.UserListItem ensureOwner() => $_ensure(2);

  /// At most 10, in appointment order (the first is the longest serving); never the owner. since is unset.
  @$pb.TagNumber(4)
  $pb.PbList<$1.UserListItem> get moderators => $_getList(3);
}

class ListCommunitiesRequest extends $pb.GeneratedMessage {
  factory ListCommunitiesRequest({
    $core.int? pageSize,
    $core.String? pageToken,
  }) {
    final result = ListCommunitiesRequest._();
    if (pageSize != null) result.pageSize = pageSize;
    if (pageToken != null) result.pageToken = pageToken;
    return result;
  }

  ListCommunitiesRequest._();

  factory ListCommunitiesRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListCommunitiesRequest()..mergeFromBuffer(data, registry);
  factory ListCommunitiesRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListCommunitiesRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListCommunitiesRequest',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.communities.v1'),
      createEmptyInstance: ListCommunitiesRequest.$_createMessage)
    ..aI(1, _omitFieldNames ? '' : 'pageSize')
    ..aOS(2, _omitFieldNames ? '' : 'pageToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListCommunitiesRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListCommunitiesRequest copyWith(
          void Function(ListCommunitiesRequest) updates) =>
      super.copyWith((message) => updates(message as ListCommunitiesRequest))
          as ListCommunitiesRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ListCommunitiesRequest() / ListCommunitiesRequest.new instead')
  static ListCommunitiesRequest create() => ListCommunitiesRequest._();
  static $pb.GeneratedMessage $_createMessage() => ListCommunitiesRequest._();
  @$core.override
  ListCommunitiesRequest createEmptyInstance() => ListCommunitiesRequest._();
  @$core.pragma('dart2js:noInline')
  static ListCommunitiesRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListCommunitiesRequest>(
          ListCommunitiesRequest.$_createMessage);
  static ListCommunitiesRequest? _defaultInstance;

  /// Ignored at Stage 0 (the directory is one response of at most 50).
  @$pb.TagNumber(1)
  $core.int get pageSize => $_getIZ(0);
  @$pb.TagNumber(1)
  set pageSize($core.int value) => $_setSignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasPageSize() => $_has(0);
  @$pb.TagNumber(1)
  void clearPageSize() => $_clearField(1);

  /// Must be "" at Stage 0.
  @$pb.TagNumber(2)
  $core.String get pageToken => $_getSZ(1);
  @$pb.TagNumber(2)
  set pageToken($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasPageToken() => $_has(1);
  @$pb.TagNumber(2)
  void clearPageToken() => $_clearField(2);
}

class ListCommunitiesResponse extends $pb.GeneratedMessage {
  factory ListCommunitiesResponse({
    $core.Iterable<Community>? communities,
    $core.String? nextPageToken,
  }) {
    final result = ListCommunitiesResponse._();
    if (communities != null) result.communities.addAll(communities);
    if (nextPageToken != null) result.nextPageToken = nextPageToken;
    return result;
  }

  ListCommunitiesResponse._();

  factory ListCommunitiesResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListCommunitiesResponse()..mergeFromBuffer(data, registry);
  factory ListCommunitiesResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListCommunitiesResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListCommunitiesResponse',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.communities.v1'),
      createEmptyInstance: ListCommunitiesResponse.$_createMessage)
    ..pPM<Community>(1, _omitFieldNames ? '' : 'communities',
        subBuilder: Community.$_createMessage)
    ..aOS(2, _omitFieldNames ? '' : 'nextPageToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListCommunitiesResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListCommunitiesResponse copyWith(
          void Function(ListCommunitiesResponse) updates) =>
      super.copyWith((message) => updates(message as ListCommunitiesResponse))
          as ListCommunitiesResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ListCommunitiesResponse() / ListCommunitiesResponse.new instead')
  static ListCommunitiesResponse create() => ListCommunitiesResponse._();
  static $pb.GeneratedMessage $_createMessage() => ListCommunitiesResponse._();
  @$core.override
  ListCommunitiesResponse createEmptyInstance() => ListCommunitiesResponse._();
  @$core.pragma('dart2js:noInline')
  static ListCommunitiesResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListCommunitiesResponse>(
          ListCommunitiesResponse.$_createMessage);
  static ListCommunitiesResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<Community> get communities => $_getList(0);

  /// Always "" at Stage 0.
  @$pb.TagNumber(2)
  $core.String get nextPageToken => $_getSZ(1);
  @$pb.TagNumber(2)
  set nextPageToken($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasNextPageToken() => $_has(1);
  @$pb.TagNumber(2)
  void clearNextPageToken() => $_clearField(2);
}

class ListMyCommunitiesRequest extends $pb.GeneratedMessage {
  factory ListMyCommunitiesRequest({
    $core.int? pageSize,
    $core.String? pageToken,
  }) {
    final result = ListMyCommunitiesRequest._();
    if (pageSize != null) result.pageSize = pageSize;
    if (pageToken != null) result.pageToken = pageToken;
    return result;
  }

  ListMyCommunitiesRequest._();

  factory ListMyCommunitiesRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListMyCommunitiesRequest()..mergeFromBuffer(data, registry);
  factory ListMyCommunitiesRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListMyCommunitiesRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListMyCommunitiesRequest',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.communities.v1'),
      createEmptyInstance: ListMyCommunitiesRequest.$_createMessage)
    ..aI(1, _omitFieldNames ? '' : 'pageSize')
    ..aOS(2, _omitFieldNames ? '' : 'pageToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListMyCommunitiesRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListMyCommunitiesRequest copyWith(
          void Function(ListMyCommunitiesRequest) updates) =>
      super.copyWith((message) => updates(message as ListMyCommunitiesRequest))
          as ListMyCommunitiesRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ListMyCommunitiesRequest() / ListMyCommunitiesRequest.new instead')
  static ListMyCommunitiesRequest create() => ListMyCommunitiesRequest._();
  static $pb.GeneratedMessage $_createMessage() => ListMyCommunitiesRequest._();
  @$core.override
  ListMyCommunitiesRequest createEmptyInstance() =>
      ListMyCommunitiesRequest._();
  @$core.pragma('dart2js:noInline')
  static ListMyCommunitiesRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListMyCommunitiesRequest>(
          ListMyCommunitiesRequest.$_createMessage);
  static ListMyCommunitiesRequest? _defaultInstance;

  /// Ignored at Stage 0 (one response of at most 50).
  @$pb.TagNumber(1)
  $core.int get pageSize => $_getIZ(0);
  @$pb.TagNumber(1)
  set pageSize($core.int value) => $_setSignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasPageSize() => $_has(0);
  @$pb.TagNumber(1)
  void clearPageSize() => $_clearField(1);

  /// Must be "" at Stage 0.
  @$pb.TagNumber(2)
  $core.String get pageToken => $_getSZ(1);
  @$pb.TagNumber(2)
  set pageToken($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasPageToken() => $_has(1);
  @$pb.TagNumber(2)
  void clearPageToken() => $_clearField(2);
}

class ListMyCommunitiesResponse extends $pb.GeneratedMessage {
  factory ListMyCommunitiesResponse({
    $core.Iterable<Community>? communities,
    $core.bool? canCreate,
    $core.String? nextPageToken,
  }) {
    final result = ListMyCommunitiesResponse._();
    if (communities != null) result.communities.addAll(communities);
    if (canCreate != null) result.canCreate = canCreate;
    if (nextPageToken != null) result.nextPageToken = nextPageToken;
    return result;
  }

  ListMyCommunitiesResponse._();

  factory ListMyCommunitiesResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListMyCommunitiesResponse()..mergeFromBuffer(data, registry);
  factory ListMyCommunitiesResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListMyCommunitiesResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListMyCommunitiesResponse',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.communities.v1'),
      createEmptyInstance: ListMyCommunitiesResponse.$_createMessage)
    ..pPM<Community>(1, _omitFieldNames ? '' : 'communities',
        subBuilder: Community.$_createMessage)
    ..aOB(2, _omitFieldNames ? '' : 'canCreate')
    ..aOS(3, _omitFieldNames ? '' : 'nextPageToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListMyCommunitiesResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListMyCommunitiesResponse copyWith(
          void Function(ListMyCommunitiesResponse) updates) =>
      super.copyWith((message) => updates(message as ListMyCommunitiesResponse))
          as ListMyCommunitiesResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ListMyCommunitiesResponse() / ListMyCommunitiesResponse.new instead')
  static ListMyCommunitiesResponse create() => ListMyCommunitiesResponse._();
  static $pb.GeneratedMessage $_createMessage() =>
      ListMyCommunitiesResponse._();
  @$core.override
  ListMyCommunitiesResponse createEmptyInstance() =>
      ListMyCommunitiesResponse._();
  @$core.pragma('dart2js:noInline')
  static ListMyCommunitiesResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListMyCommunitiesResponse>(
          ListMyCommunitiesResponse.$_createMessage);
  static ListMyCommunitiesResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<Community> get communities => $_getList(0);

  /// True when the caller may call CreateCommunity (COMMUNITY_CREATORS, F1). Show "Create a Community" only then.
  @$pb.TagNumber(2)
  $core.bool get canCreate => $_getBF(1);
  @$pb.TagNumber(2)
  set canCreate($core.bool value) => $_setBool(1, value);
  @$pb.TagNumber(2)
  $core.bool hasCanCreate() => $_has(1);
  @$pb.TagNumber(2)
  void clearCanCreate() => $_clearField(2);

  /// Always "" at Stage 0.
  @$pb.TagNumber(3)
  $core.String get nextPageToken => $_getSZ(2);
  @$pb.TagNumber(3)
  set nextPageToken($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasNextPageToken() => $_has(2);
  @$pb.TagNumber(3)
  void clearNextPageToken() => $_clearField(3);
}

class JoinCommunityRequest extends $pb.GeneratedMessage {
  factory JoinCommunityRequest({
    $core.String? idempotencyKey,
    $core.String? communityId,
  }) {
    final result = JoinCommunityRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (communityId != null) result.communityId = communityId;
    return result;
  }

  JoinCommunityRequest._();

  factory JoinCommunityRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      JoinCommunityRequest()..mergeFromBuffer(data, registry);
  factory JoinCommunityRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      JoinCommunityRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'JoinCommunityRequest',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.communities.v1'),
      createEmptyInstance: JoinCommunityRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'communityId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  JoinCommunityRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  JoinCommunityRequest copyWith(void Function(JoinCommunityRequest) updates) =>
      super.copyWith((message) => updates(message as JoinCommunityRequest))
          as JoinCommunityRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use JoinCommunityRequest() / JoinCommunityRequest.new instead')
  static JoinCommunityRequest create() => JoinCommunityRequest._();
  static $pb.GeneratedMessage $_createMessage() => JoinCommunityRequest._();
  @$core.override
  JoinCommunityRequest createEmptyInstance() => JoinCommunityRequest._();
  @$core.pragma('dart2js:noInline')
  static JoinCommunityRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<JoinCommunityRequest>(
          JoinCommunityRequest.$_createMessage);
  static JoinCommunityRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get communityId => $_getSZ(1);
  @$pb.TagNumber(2)
  set communityId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasCommunityId() => $_has(1);
  @$pb.TagNumber(2)
  void clearCommunityId() => $_clearField(2);
}

class JoinCommunityResponse extends $pb.GeneratedMessage {
  factory JoinCommunityResponse({
    Community? community,
  }) {
    final result = JoinCommunityResponse._();
    if (community != null) result.community = community;
    return result;
  }

  JoinCommunityResponse._();

  factory JoinCommunityResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      JoinCommunityResponse()..mergeFromBuffer(data, registry);
  factory JoinCommunityResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      JoinCommunityResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'JoinCommunityResponse',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.communities.v1'),
      createEmptyInstance: JoinCommunityResponse.$_createMessage)
    ..aOM<Community>(1, _omitFieldNames ? '' : 'community',
        subBuilder: Community.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  JoinCommunityResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  JoinCommunityResponse copyWith(
          void Function(JoinCommunityResponse) updates) =>
      super.copyWith((message) => updates(message as JoinCommunityResponse))
          as JoinCommunityResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use JoinCommunityResponse() / JoinCommunityResponse.new instead')
  static JoinCommunityResponse create() => JoinCommunityResponse._();
  static $pb.GeneratedMessage $_createMessage() => JoinCommunityResponse._();
  @$core.override
  JoinCommunityResponse createEmptyInstance() => JoinCommunityResponse._();
  @$core.pragma('dart2js:noInline')
  static JoinCommunityResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<JoinCommunityResponse>(
          JoinCommunityResponse.$_createMessage);
  static JoinCommunityResponse? _defaultInstance;

  @$pb.TagNumber(1)
  Community get community => $_getN(0);
  @$pb.TagNumber(1)
  set community(Community value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasCommunity() => $_has(0);
  @$pb.TagNumber(1)
  void clearCommunity() => $_clearField(1);
  @$pb.TagNumber(1)
  Community ensureCommunity() => $_ensure(0);
}

class LeaveCommunityRequest extends $pb.GeneratedMessage {
  factory LeaveCommunityRequest({
    $core.String? idempotencyKey,
    $core.String? communityId,
  }) {
    final result = LeaveCommunityRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (communityId != null) result.communityId = communityId;
    return result;
  }

  LeaveCommunityRequest._();

  factory LeaveCommunityRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      LeaveCommunityRequest()..mergeFromBuffer(data, registry);
  factory LeaveCommunityRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      LeaveCommunityRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'LeaveCommunityRequest',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.communities.v1'),
      createEmptyInstance: LeaveCommunityRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'communityId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  LeaveCommunityRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  LeaveCommunityRequest copyWith(
          void Function(LeaveCommunityRequest) updates) =>
      super.copyWith((message) => updates(message as LeaveCommunityRequest))
          as LeaveCommunityRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use LeaveCommunityRequest() / LeaveCommunityRequest.new instead')
  static LeaveCommunityRequest create() => LeaveCommunityRequest._();
  static $pb.GeneratedMessage $_createMessage() => LeaveCommunityRequest._();
  @$core.override
  LeaveCommunityRequest createEmptyInstance() => LeaveCommunityRequest._();
  @$core.pragma('dart2js:noInline')
  static LeaveCommunityRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<LeaveCommunityRequest>(
          LeaveCommunityRequest.$_createMessage);
  static LeaveCommunityRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get communityId => $_getSZ(1);
  @$pb.TagNumber(2)
  set communityId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasCommunityId() => $_has(1);
  @$pb.TagNumber(2)
  void clearCommunityId() => $_clearField(2);
}

class LeaveCommunityResponse extends $pb.GeneratedMessage {
  factory LeaveCommunityResponse({
    Community? community,
  }) {
    final result = LeaveCommunityResponse._();
    if (community != null) result.community = community;
    return result;
  }

  LeaveCommunityResponse._();

  factory LeaveCommunityResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      LeaveCommunityResponse()..mergeFromBuffer(data, registry);
  factory LeaveCommunityResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      LeaveCommunityResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'LeaveCommunityResponse',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.communities.v1'),
      createEmptyInstance: LeaveCommunityResponse.$_createMessage)
    ..aOM<Community>(1, _omitFieldNames ? '' : 'community',
        subBuilder: Community.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  LeaveCommunityResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  LeaveCommunityResponse copyWith(
          void Function(LeaveCommunityResponse) updates) =>
      super.copyWith((message) => updates(message as LeaveCommunityResponse))
          as LeaveCommunityResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use LeaveCommunityResponse() / LeaveCommunityResponse.new instead')
  static LeaveCommunityResponse create() => LeaveCommunityResponse._();
  static $pb.GeneratedMessage $_createMessage() => LeaveCommunityResponse._();
  @$core.override
  LeaveCommunityResponse createEmptyInstance() => LeaveCommunityResponse._();
  @$core.pragma('dart2js:noInline')
  static LeaveCommunityResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<LeaveCommunityResponse>(
          LeaveCommunityResponse.$_createMessage);
  static LeaveCommunityResponse? _defaultInstance;

  @$pb.TagNumber(1)
  Community get community => $_getN(0);
  @$pb.TagNumber(1)
  set community(Community value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasCommunity() => $_has(0);
  @$pb.TagNumber(1)
  void clearCommunity() => $_clearField(1);
  @$pb.TagNumber(1)
  Community ensureCommunity() => $_ensure(0);
}

class ListCommunityMembersRequest extends $pb.GeneratedMessage {
  factory ListCommunityMembersRequest({
    $core.String? communityId,
    CommunityMemberFilter? filter,
    $core.int? pageSize,
    $core.String? pageToken,
  }) {
    final result = ListCommunityMembersRequest._();
    if (communityId != null) result.communityId = communityId;
    if (filter != null) result.filter = filter;
    if (pageSize != null) result.pageSize = pageSize;
    if (pageToken != null) result.pageToken = pageToken;
    return result;
  }

  ListCommunityMembersRequest._();

  factory ListCommunityMembersRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListCommunityMembersRequest()..mergeFromBuffer(data, registry);
  factory ListCommunityMembersRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListCommunityMembersRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListCommunityMembersRequest',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.communities.v1'),
      createEmptyInstance: ListCommunityMembersRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'communityId')
    ..aE<CommunityMemberFilter>(2, _omitFieldNames ? '' : 'filter',
        enumValues: CommunityMemberFilter.values)
    ..aI(3, _omitFieldNames ? '' : 'pageSize')
    ..aOS(4, _omitFieldNames ? '' : 'pageToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListCommunityMembersRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListCommunityMembersRequest copyWith(
          void Function(ListCommunityMembersRequest) updates) =>
      super.copyWith(
              (message) => updates(message as ListCommunityMembersRequest))
          as ListCommunityMembersRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ListCommunityMembersRequest() / ListCommunityMembersRequest.new instead')
  static ListCommunityMembersRequest create() =>
      ListCommunityMembersRequest._();
  static $pb.GeneratedMessage $_createMessage() =>
      ListCommunityMembersRequest._();
  @$core.override
  ListCommunityMembersRequest createEmptyInstance() =>
      ListCommunityMembersRequest._();
  @$core.pragma('dart2js:noInline')
  static ListCommunityMembersRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListCommunityMembersRequest>(
          ListCommunityMembersRequest.$_createMessage);
  static ListCommunityMembersRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get communityId => $_getSZ(0);
  @$pb.TagNumber(1)
  set communityId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasCommunityId() => $_has(0);
  @$pb.TagNumber(1)
  void clearCommunityId() => $_clearField(1);

  /// UNSPECIFIED => JOINED.
  @$pb.TagNumber(2)
  CommunityMemberFilter get filter => $_getN(1);
  @$pb.TagNumber(2)
  set filter(CommunityMemberFilter value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasFilter() => $_has(1);
  @$pb.TagNumber(2)
  void clearFilter() => $_clearField(2);

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

class ListCommunityMembersResponse extends $pb.GeneratedMessage {
  factory ListCommunityMembersResponse({
    $core.Iterable<CommunityMember>? members,
    $core.String? nextPageToken,
  }) {
    final result = ListCommunityMembersResponse._();
    if (members != null) result.members.addAll(members);
    if (nextPageToken != null) result.nextPageToken = nextPageToken;
    return result;
  }

  ListCommunityMembersResponse._();

  factory ListCommunityMembersResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListCommunityMembersResponse()..mergeFromBuffer(data, registry);
  factory ListCommunityMembersResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListCommunityMembersResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListCommunityMembersResponse',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.communities.v1'),
      createEmptyInstance: ListCommunityMembersResponse.$_createMessage)
    ..pPM<CommunityMember>(1, _omitFieldNames ? '' : 'members',
        subBuilder: CommunityMember.$_createMessage)
    ..aOS(2, _omitFieldNames ? '' : 'nextPageToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListCommunityMembersResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListCommunityMembersResponse copyWith(
          void Function(ListCommunityMembersResponse) updates) =>
      super.copyWith(
              (message) => updates(message as ListCommunityMembersResponse))
          as ListCommunityMembersResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ListCommunityMembersResponse() / ListCommunityMembersResponse.new instead')
  static ListCommunityMembersResponse create() =>
      ListCommunityMembersResponse._();
  static $pb.GeneratedMessage $_createMessage() =>
      ListCommunityMembersResponse._();
  @$core.override
  ListCommunityMembersResponse createEmptyInstance() =>
      ListCommunityMembersResponse._();
  @$core.pragma('dart2js:noInline')
  static ListCommunityMembersResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListCommunityMembersResponse>(
          ListCommunityMembersResponse.$_createMessage);
  static ListCommunityMembersResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<CommunityMember> get members => $_getList(0);

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

class HideCommunityPostRequest extends $pb.GeneratedMessage {
  factory HideCommunityPostRequest({
    $core.String? idempotencyKey,
    $core.String? communityId,
    $core.String? postId,
  }) {
    final result = HideCommunityPostRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (communityId != null) result.communityId = communityId;
    if (postId != null) result.postId = postId;
    return result;
  }

  HideCommunityPostRequest._();

  factory HideCommunityPostRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      HideCommunityPostRequest()..mergeFromBuffer(data, registry);
  factory HideCommunityPostRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      HideCommunityPostRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'HideCommunityPostRequest',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.communities.v1'),
      createEmptyInstance: HideCommunityPostRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'communityId')
    ..aOS(3, _omitFieldNames ? '' : 'postId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  HideCommunityPostRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  HideCommunityPostRequest copyWith(
          void Function(HideCommunityPostRequest) updates) =>
      super.copyWith((message) => updates(message as HideCommunityPostRequest))
          as HideCommunityPostRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use HideCommunityPostRequest() / HideCommunityPostRequest.new instead')
  static HideCommunityPostRequest create() => HideCommunityPostRequest._();
  static $pb.GeneratedMessage $_createMessage() => HideCommunityPostRequest._();
  @$core.override
  HideCommunityPostRequest createEmptyInstance() =>
      HideCommunityPostRequest._();
  @$core.pragma('dart2js:noInline')
  static HideCommunityPostRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<HideCommunityPostRequest>(
          HideCommunityPostRequest.$_createMessage);
  static HideCommunityPostRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get communityId => $_getSZ(1);
  @$pb.TagNumber(2)
  set communityId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasCommunityId() => $_has(1);
  @$pb.TagNumber(2)
  void clearCommunityId() => $_clearField(2);

  /// 19-digit post id of a root post or quote created into this community.
  @$pb.TagNumber(3)
  $core.String get postId => $_getSZ(2);
  @$pb.TagNumber(3)
  set postId($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasPostId() => $_has(2);
  @$pb.TagNumber(3)
  void clearPostId() => $_clearField(3);
}

class HideCommunityPostResponse extends $pb.GeneratedMessage {
  factory HideCommunityPostResponse() => HideCommunityPostResponse._();

  HideCommunityPostResponse._();

  factory HideCommunityPostResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      HideCommunityPostResponse()..mergeFromBuffer(data, registry);
  factory HideCommunityPostResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      HideCommunityPostResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'HideCommunityPostResponse',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.communities.v1'),
      createEmptyInstance: HideCommunityPostResponse.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  HideCommunityPostResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  HideCommunityPostResponse copyWith(
          void Function(HideCommunityPostResponse) updates) =>
      super.copyWith((message) => updates(message as HideCommunityPostResponse))
          as HideCommunityPostResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use HideCommunityPostResponse() / HideCommunityPostResponse.new instead')
  static HideCommunityPostResponse create() => HideCommunityPostResponse._();
  static $pb.GeneratedMessage $_createMessage() =>
      HideCommunityPostResponse._();
  @$core.override
  HideCommunityPostResponse createEmptyInstance() =>
      HideCommunityPostResponse._();
  @$core.pragma('dart2js:noInline')
  static HideCommunityPostResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<HideCommunityPostResponse>(
          HideCommunityPostResponse.$_createMessage);
  static HideCommunityPostResponse? _defaultInstance;
}

class RestoreCommunityPostRequest extends $pb.GeneratedMessage {
  factory RestoreCommunityPostRequest({
    $core.String? idempotencyKey,
    $core.String? communityId,
    $core.String? postId,
  }) {
    final result = RestoreCommunityPostRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (communityId != null) result.communityId = communityId;
    if (postId != null) result.postId = postId;
    return result;
  }

  RestoreCommunityPostRequest._();

  factory RestoreCommunityPostRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RestoreCommunityPostRequest()..mergeFromBuffer(data, registry);
  factory RestoreCommunityPostRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RestoreCommunityPostRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RestoreCommunityPostRequest',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.communities.v1'),
      createEmptyInstance: RestoreCommunityPostRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'communityId')
    ..aOS(3, _omitFieldNames ? '' : 'postId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RestoreCommunityPostRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RestoreCommunityPostRequest copyWith(
          void Function(RestoreCommunityPostRequest) updates) =>
      super.copyWith(
              (message) => updates(message as RestoreCommunityPostRequest))
          as RestoreCommunityPostRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use RestoreCommunityPostRequest() / RestoreCommunityPostRequest.new instead')
  static RestoreCommunityPostRequest create() =>
      RestoreCommunityPostRequest._();
  static $pb.GeneratedMessage $_createMessage() =>
      RestoreCommunityPostRequest._();
  @$core.override
  RestoreCommunityPostRequest createEmptyInstance() =>
      RestoreCommunityPostRequest._();
  @$core.pragma('dart2js:noInline')
  static RestoreCommunityPostRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<RestoreCommunityPostRequest>(
          RestoreCommunityPostRequest.$_createMessage);
  static RestoreCommunityPostRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get communityId => $_getSZ(1);
  @$pb.TagNumber(2)
  set communityId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasCommunityId() => $_has(1);
  @$pb.TagNumber(2)
  void clearCommunityId() => $_clearField(2);

  /// 19-digit post id.
  @$pb.TagNumber(3)
  $core.String get postId => $_getSZ(2);
  @$pb.TagNumber(3)
  set postId($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasPostId() => $_has(2);
  @$pb.TagNumber(3)
  void clearPostId() => $_clearField(3);
}

class RestoreCommunityPostResponse extends $pb.GeneratedMessage {
  factory RestoreCommunityPostResponse() => RestoreCommunityPostResponse._();

  RestoreCommunityPostResponse._();

  factory RestoreCommunityPostResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RestoreCommunityPostResponse()..mergeFromBuffer(data, registry);
  factory RestoreCommunityPostResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RestoreCommunityPostResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RestoreCommunityPostResponse',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.communities.v1'),
      createEmptyInstance: RestoreCommunityPostResponse.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RestoreCommunityPostResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RestoreCommunityPostResponse copyWith(
          void Function(RestoreCommunityPostResponse) updates) =>
      super.copyWith(
              (message) => updates(message as RestoreCommunityPostResponse))
          as RestoreCommunityPostResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use RestoreCommunityPostResponse() / RestoreCommunityPostResponse.new instead')
  static RestoreCommunityPostResponse create() =>
      RestoreCommunityPostResponse._();
  static $pb.GeneratedMessage $_createMessage() =>
      RestoreCommunityPostResponse._();
  @$core.override
  RestoreCommunityPostResponse createEmptyInstance() =>
      RestoreCommunityPostResponse._();
  @$core.pragma('dart2js:noInline')
  static RestoreCommunityPostResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<RestoreCommunityPostResponse>(
          RestoreCommunityPostResponse.$_createMessage);
  static RestoreCommunityPostResponse? _defaultInstance;
}

class SetMemberRoleRequest extends $pb.GeneratedMessage {
  factory SetMemberRoleRequest({
    $core.String? idempotencyKey,
    $core.String? communityId,
    $core.String? userId,
    MemberRoleAction? action,
  }) {
    final result = SetMemberRoleRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (communityId != null) result.communityId = communityId;
    if (userId != null) result.userId = userId;
    if (action != null) result.action = action;
    return result;
  }

  SetMemberRoleRequest._();

  factory SetMemberRoleRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SetMemberRoleRequest()..mergeFromBuffer(data, registry);
  factory SetMemberRoleRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SetMemberRoleRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'SetMemberRoleRequest',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.communities.v1'),
      createEmptyInstance: SetMemberRoleRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'communityId')
    ..aOS(3, _omitFieldNames ? '' : 'userId')
    ..aE<MemberRoleAction>(4, _omitFieldNames ? '' : 'action',
        enumValues: MemberRoleAction.values)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SetMemberRoleRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SetMemberRoleRequest copyWith(void Function(SetMemberRoleRequest) updates) =>
      super.copyWith((message) => updates(message as SetMemberRoleRequest))
          as SetMemberRoleRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use SetMemberRoleRequest() / SetMemberRoleRequest.new instead')
  static SetMemberRoleRequest create() => SetMemberRoleRequest._();
  static $pb.GeneratedMessage $_createMessage() => SetMemberRoleRequest._();
  @$core.override
  SetMemberRoleRequest createEmptyInstance() => SetMemberRoleRequest._();
  @$core.pragma('dart2js:noInline')
  static SetMemberRoleRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<SetMemberRoleRequest>(
          SetMemberRoleRequest.$_createMessage);
  static SetMemberRoleRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get communityId => $_getSZ(1);
  @$pb.TagNumber(2)
  set communityId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasCommunityId() => $_has(1);
  @$pb.TagNumber(2)
  void clearCommunityId() => $_clearField(2);

  /// The target user.
  @$pb.TagNumber(3)
  $core.String get userId => $_getSZ(2);
  @$pb.TagNumber(3)
  set userId($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasUserId() => $_has(2);
  @$pb.TagNumber(3)
  void clearUserId() => $_clearField(3);

  @$pb.TagNumber(4)
  MemberRoleAction get action => $_getN(3);
  @$pb.TagNumber(4)
  set action(MemberRoleAction value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasAction() => $_has(3);
  @$pb.TagNumber(4)
  void clearAction() => $_clearField(4);
}

class SetMemberRoleResponse extends $pb.GeneratedMessage {
  factory SetMemberRoleResponse({
    CommunityRole? role,
    Community? community,
  }) {
    final result = SetMemberRoleResponse._();
    if (role != null) result.role = role;
    if (community != null) result.community = community;
    return result;
  }

  SetMemberRoleResponse._();

  factory SetMemberRoleResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SetMemberRoleResponse()..mergeFromBuffer(data, registry);
  factory SetMemberRoleResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SetMemberRoleResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'SetMemberRoleResponse',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.communities.v1'),
      createEmptyInstance: SetMemberRoleResponse.$_createMessage)
    ..aE<CommunityRole>(1, _omitFieldNames ? '' : 'role',
        enumValues: CommunityRole.values)
    ..aOM<Community>(2, _omitFieldNames ? '' : 'community',
        subBuilder: Community.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SetMemberRoleResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SetMemberRoleResponse copyWith(
          void Function(SetMemberRoleResponse) updates) =>
      super.copyWith((message) => updates(message as SetMemberRoleResponse))
          as SetMemberRoleResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use SetMemberRoleResponse() / SetMemberRoleResponse.new instead')
  static SetMemberRoleResponse create() => SetMemberRoleResponse._();
  static $pb.GeneratedMessage $_createMessage() => SetMemberRoleResponse._();
  @$core.override
  SetMemberRoleResponse createEmptyInstance() => SetMemberRoleResponse._();
  @$core.pragma('dart2js:noInline')
  static SetMemberRoleResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<SetMemberRoleResponse>(
          SetMemberRoleResponse.$_createMessage);
  static SetMemberRoleResponse? _defaultInstance;

  /// The target's role after the call (BANNED, NONE after an unban, MODERATOR or MEMBER).
  @$pb.TagNumber(1)
  CommunityRole get role => $_getN(0);
  @$pb.TagNumber(1)
  set role(CommunityRole value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasRole() => $_has(0);
  @$pb.TagNumber(1)
  void clearRole() => $_clearField(1);

  /// The header after the call (member_count changes on a ban).
  @$pb.TagNumber(2)
  Community get community => $_getN(1);
  @$pb.TagNumber(2)
  set community(Community value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasCommunity() => $_has(1);
  @$pb.TagNumber(2)
  void clearCommunity() => $_clearField(2);
  @$pb.TagNumber(2)
  Community ensureCommunity() => $_ensure(1);
}

class ListModerationLogRequest extends $pb.GeneratedMessage {
  factory ListModerationLogRequest({
    $core.String? communityId,
    $core.int? pageSize,
    $core.String? pageToken,
  }) {
    final result = ListModerationLogRequest._();
    if (communityId != null) result.communityId = communityId;
    if (pageSize != null) result.pageSize = pageSize;
    if (pageToken != null) result.pageToken = pageToken;
    return result;
  }

  ListModerationLogRequest._();

  factory ListModerationLogRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListModerationLogRequest()..mergeFromBuffer(data, registry);
  factory ListModerationLogRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListModerationLogRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListModerationLogRequest',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.communities.v1'),
      createEmptyInstance: ListModerationLogRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'communityId')
    ..aI(2, _omitFieldNames ? '' : 'pageSize')
    ..aOS(3, _omitFieldNames ? '' : 'pageToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListModerationLogRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListModerationLogRequest copyWith(
          void Function(ListModerationLogRequest) updates) =>
      super.copyWith((message) => updates(message as ListModerationLogRequest))
          as ListModerationLogRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ListModerationLogRequest() / ListModerationLogRequest.new instead')
  static ListModerationLogRequest create() => ListModerationLogRequest._();
  static $pb.GeneratedMessage $_createMessage() => ListModerationLogRequest._();
  @$core.override
  ListModerationLogRequest createEmptyInstance() =>
      ListModerationLogRequest._();
  @$core.pragma('dart2js:noInline')
  static ListModerationLogRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListModerationLogRequest>(
          ListModerationLogRequest.$_createMessage);
  static ListModerationLogRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get communityId => $_getSZ(0);
  @$pb.TagNumber(1)
  set communityId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasCommunityId() => $_has(0);
  @$pb.TagNumber(1)
  void clearCommunityId() => $_clearField(1);

  /// 0 => 25; max 25 (clamped).
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

class ListModerationLogResponse extends $pb.GeneratedMessage {
  factory ListModerationLogResponse({
    $core.Iterable<ModerationLogEntry>? entries,
    $core.String? nextPageToken,
  }) {
    final result = ListModerationLogResponse._();
    if (entries != null) result.entries.addAll(entries);
    if (nextPageToken != null) result.nextPageToken = nextPageToken;
    return result;
  }

  ListModerationLogResponse._();

  factory ListModerationLogResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListModerationLogResponse()..mergeFromBuffer(data, registry);
  factory ListModerationLogResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListModerationLogResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListModerationLogResponse',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.communities.v1'),
      createEmptyInstance: ListModerationLogResponse.$_createMessage)
    ..pPM<ModerationLogEntry>(1, _omitFieldNames ? '' : 'entries',
        subBuilder: ModerationLogEntry.$_createMessage)
    ..aOS(2, _omitFieldNames ? '' : 'nextPageToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListModerationLogResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListModerationLogResponse copyWith(
          void Function(ListModerationLogResponse) updates) =>
      super.copyWith((message) => updates(message as ListModerationLogResponse))
          as ListModerationLogResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ListModerationLogResponse() / ListModerationLogResponse.new instead')
  static ListModerationLogResponse create() => ListModerationLogResponse._();
  static $pb.GeneratedMessage $_createMessage() =>
      ListModerationLogResponse._();
  @$core.override
  ListModerationLogResponse createEmptyInstance() =>
      ListModerationLogResponse._();
  @$core.pragma('dart2js:noInline')
  static ListModerationLogResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListModerationLogResponse>(
          ListModerationLogResponse.$_createMessage);
  static ListModerationLogResponse? _defaultInstance;

  /// Newest first.
  @$pb.TagNumber(1)
  $pb.PbList<ModerationLogEntry> get entries => $_getList(0);

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

class CommunityServiceApi {
  final $pb.RpcClient _client;

  CommunityServiceApi(this._client);

  /// Create a community owned by the caller, who becomes its first member. Needs the caller in COMMUNITY_CREATORS,
  /// checked first (FORBIDDEN "not_creator", before any lookup), then the text rules. No daily cap: the
  /// owned cap is exact and lifetime (there is no delete).
  /// One transaction: idempotency doc, the caller's communityMemberships (the owned and joined caps), then Create
  /// communities/{id} with a fresh Snowflake id (status ACTIVE, visibility PUBLIC, memberCount 1), the owner's member
  /// doc (JOINED) and the memberships doc (owned and joined += id). At COMMUNITIES_MAX_OWNED (2) => LIMIT_REACHED
  /// "communities_owned"; at COMMUNITIES_MAX_JOINED (50) => LIMIT_REACHED "communities_joined"; both write nothing.
  $async.Future<CreateCommunityResponse> createCommunity(
          $pb.ClientContext? ctx, CreateCommunityRequest request) =>
      _client.invoke<CreateCommunityResponse>(ctx, 'CommunityService',
          'CreateCommunity', request, CreateCommunityResponse());

  /// Change a community's name, description or rules. While creation is allowlisted (always at Stage 0) the caller must
  /// be in COMMUNITY_CREATORS, checked first: else FORBIDDEN "not_creator", before any lookup and writing nothing,
  /// whoever owns the community (an owner by hand-over keeps every other owner power).
  /// Then owner only: anyone else => FORBIDDEN "not_owner"; ARCHIVED => COMMUNITY_STATE "community_archived". Only the
  /// fields that are set change; the text rules are CreateCommunity's.
  /// A rename does not rewrite the label of earlier posts (Post.community is a snapshot at post time); the community's
  /// own page and feed header show the current name.
  /// One transaction: idempotency doc, the community (fresh), the owner's memberships (modlogged), then the community
  /// with an EDIT moderation-log entry. A request that changes nothing writes only the idempotency doc.
  $async.Future<UpdateCommunityResponse> updateCommunity(
          $pb.ClientContext? ctx, UpdateCommunityRequest request) =>
      _client.invoke<UpdateCommunityResponse>(ctx, 'CommunityService',
          'UpdateCommunity', request, UpdateCommunityResponse());

  /// One community: the header, its rules, its owner and its moderators. NOT_FOUND for every cause in Status (a SUSPENDED
  /// community is shown to its owner only). viewer_role comes from the community doc and the caller's member doc.
  /// owner and moderators are live rows (identity.Directory, up to 60 s stale) with the caller's relationship to each
  /// (from the caller's graph); every role holder is shown to every viewer whatever the blocks (D7).
  /// A role holder whose account is not ACTIVE is left out for every viewer.
  /// Cached: the community doc 60 s per instance (CACHE_COMMUNITIES_ENTRIES), the member doc 60 s
  /// (CACHE_COMMUNITY_MEMBERS_ENTRIES), profiles through identity.Directory.
  $async.Future<GetCommunityResponse> getCommunity(
          $pb.ClientContext? ctx, GetCommunityRequest request) =>
      _client.invoke<GetCommunityResponse>(ctx, 'CommunityService',
          'GetCommunity', request, GetCommunityResponse());

  /// The directory (F10): the ACTIVE communities with the most members, at most 50, by member_count descending (ties
  /// by id descending). Query `communities ORDER BY memberCount DESC, __name__ DESC LIMIT 50` on the automatic index;
  /// non-ACTIVE rows are dropped in memory, so the list may hold fewer than 50. No categories, no search. No block
  /// filtering (D7). viewer_role per row comes from the caller's communityMemberships and each doc's moderatorIds.
  /// Not paged at Stage 0: every row comes back in one response, whatever page_size is, and next_page_token is "". A
  /// non-empty page_token => VALIDATION "page_token", before any lookup.
  /// Cached: one shared directory entry per instance, 5 min; the caller's memberships 60 s.
  $async.Future<ListCommunitiesResponse> listCommunities(
          $pb.ClientContext? ctx, ListCommunitiesRequest request) =>
      _client.invoke<ListCommunitiesResponse>(ctx, 'CommunityService',
          'ListCommunities', request, ListCommunitiesResponse());

  /// The caller's communities: every community the caller is a JOINED member of (owned and moderated ones included),
  /// most recently joined first, read from communityMemberships/{caller} and the community docs (cache-first). ARCHIVED
  /// ones are included with status ARCHIVED. SUSPENDED ones are left out, except the caller's own (status SUSPENDED).
  /// Communities the caller is banned from are not listed. can_create: the caller is in COMMUNITY_CREATORS (config, no lookup); the owned cap is CreateCommunity's to answer.
  /// Not paged at Stage 0 (at most COMMUNITIES_MAX_JOINED, 50): one response, next_page_token "", whatever page_size
  /// is; a non-empty page_token => VALIDATION "page_token".
  $async.Future<ListMyCommunitiesResponse> listMyCommunities(
          $pb.ClientContext? ctx, ListMyCommunitiesRequest request) =>
      _client.invoke<ListMyCommunitiesResponse>(ctx, 'CommunityService',
          'ListMyCommunities', request, ListMyCommunitiesResponse());

  /// Join a community. A block in either direction with the owner or a moderator does not refuse it (D7). A protected
  /// account may join (F6). BANNED => FORBIDDEN "banned", writing nothing; ARCHIVED => COMMUNITY_STATE "community_archived".
  /// Already a member (owner and moderators included) => success, the idempotency doc only.
  /// One transaction: idempotency doc, the caller's member doc, the caller's communityMemberships (the joined cap,
  /// exact), then the member doc (JOINED), memberships (joined += id) and a blind Increment
  /// of memberCount. The transaction never reads the community doc (its status comes from the 60 s cache),
  /// so a join burst cannot abort other joins on a read lock; member_count in the response may lag by up to 60 s.
  /// At COMMUNITIES_MAX_JOINED (50) => LIMIT_REACHED "communities_joined".
  $async.Future<JoinCommunityResponse> joinCommunity(
          $pb.ClientContext? ctx, JoinCommunityRequest request) =>
      _client.invoke<JoinCommunityResponse>(ctx, 'CommunityService',
          'JoinCommunity', request, JoinCommunityResponse());

  /// Leave a community. The owner => COMMUNITY_STATE "owner", writing nothing. A moderator also leaves moderator_ids, logged as
  /// MODERATOR_LEFT. Not a member (a banned user included: the ban stays) => success, the idempotency doc only.
  /// Allowed in an ARCHIVED community. Leaving does not unpin a Home tab of the community.
  /// One transaction: idempotency doc, the member doc, the caller's memberships (+ the community fresh for a moderator),
  /// then delete the member doc, memberships (joined -= id), memberCount -1 (for a moderator the community write that
  /// also removes the id and appends the log entry), idempotency.
  $async.Future<LeaveCommunityResponse> leaveCommunity(
          $pb.ClientContext? ctx, LeaveCommunityRequest request) =>
      _client.invoke<LeaveCommunityResponse>(ctx, 'CommunityService',
          'LeaveCommunity', request, LeaveCommunityResponse());

  /// A community's member page. filter JOINED (or UNSPECIFIED): its members, owner and moderators included, most recently
  /// joined first (`communityMembers ORDER BY joinedAt DESC, __name__ DESC`, the presence of joinedAt is the filter).
  /// filter BANNED: its banned users, most recently banned first (`ORDER BY bannedAt DESC, __name__ DESC`), for the
  /// owner and moderators only, else FORBIDDEN "not_moderator" after the community read. Both run on the automatic
  /// index (D3). filter MODERATORS: the owner and the moderators (at most 1 + COMMUNITY_MAX_MODERATORS rows, read from the
  /// community document and one batch read of their member docs; no query, no index), owner first then moderators by
  /// user id, for the owner and moderators only, else FORBIDDEN "not_moderator" after the community read; a listed user
  /// whose member doc is not JOINED is left out. Any other filter value => VALIDATION "filter" (after the flag gate,
  /// before any lookup). Each row carries the user's role and UserListItem.since = joinedAt (JOINED, MODERATORS) or
  /// bannedAt (BANNED).
  /// Rows whose account is not ACTIVE are left out, and so are the D7 drops for the caller (header comment: a block
  /// either way drops the row unless the caller is the owner or a moderator, who see every member; a muted member is
  /// shown). A protected member (user.is_private) is left out for a caller who is not the owner, a moderator, that
  /// member or an approved follower of it (a pending request is not approval); a protected owner or moderator is
  /// always listed, and member_count still counts every member. So a page may be
  /// short while next_page_token is set: keep following it. user.is_private is set (live row).
  /// Paging: page_size 0 => 20, max 50 (clamped); page_token is sealed, bound to the caller, the community and the
  /// effective filter (UNSPECIFIED and JOINED bind the same), and expires after 24 h (expired, foreign or tampered =>
  /// VALIDATION "page_token", before any lookup).
  $async.Future<ListCommunityMembersResponse> listCommunityMembers(
          $pb.ClientContext? ctx, ListCommunityMembersRequest request) =>
      _client.invoke<ListCommunityMembersResponse>(ctx, 'CommunityService',
          'ListCommunityMembers', request, ListCommunityMembersResponse());

  /// Hide a post from this community's view, or a reply from its conversations.
  /// Owner or moderator, else FORBIDDEN "not_moderator"; ARCHIVED => COMMUNITY_STATE "community_archived".
  /// post_id must be a root post created into this community (Post.community.id == community_id) or a reply at any
  /// depth of a conversation whose root was. Anything else (a reply in another community's conversation or in one with
  /// no community, a REPOST, a missing post) and a post or reply the platform removed (taken down, or hidden with its
  /// suspended author) => NOT_FOUND "post not found", writing nothing; so a hide and restore can never erase a platform
  /// removal (L-2). A moderator who is not the owner cannot act on a post or reply whose author is the owner or
  /// another moderator now => FORBIDDEN "not_owner", writing nothing; the owner acts on every one, a moderator on their own and
  /// on everyone else's (F16).
  /// A root post leaves the community's feed and loses its label on every surface. A reply leaves the community's
  /// threads: GetThread drops it for every caller but its author, and as a parent returns it unavailable. Both stay on
  /// the author's profile, in search and on a direct link (GetPost), with their likes and reposts, and a hide is never
  /// a takedown. Already hidden => success, the idempotency doc only. A block either way does not refuse it
  /// (F14).
  /// One transaction (posts.CommunityModerator): idempotency doc, the community (fresh), the actor's memberships, the
  /// post (fresh), then the post (field-level: communityHidden and the hide time set; a root also loses communityId),
  /// the community (a HIDE log entry, at most 100 kept; for a root also recentRemovals += {post, now}, at most 50 kept;
  /// a reply adds no recentRemovals entry) and idempotency. Feeds on this instance drop a root at once; other devices
  /// drop it at their next refresh (GetCommunityTimeline removed_ids, within 60 s). A device keeps a reply in a thread
  /// it already loaded until it loads the thread again.
  $async.Future<HideCommunityPostResponse> hideCommunityPost(
          $pb.ClientContext? ctx, HideCommunityPostRequest request) =>
      _client.invoke<HideCommunityPostResponse>(ctx, 'CommunityService',
          'HideCommunityPost', request, HideCommunityPostResponse());

  /// Restore a post or reply a moderator hid in this community: the reverse of HideCommunityPost, with the same roles,
  /// rules (the F16 "not_owner" and the platform-removal NOT_FOUND included) and errors. A root re-enters the
  /// community's feed and gets its label back; its recentRemovals entry is deleted, so it is never listed in
  /// removed_ids (a device that dropped it gets it back at its next cold open). A reply returns to GetThread for every
  /// caller. A post that is not hidden => success, the idempotency doc only. A RESTORE log entry is appended.
  $async.Future<RestoreCommunityPostResponse> restoreCommunityPost(
          $pb.ClientContext? ctx, RestoreCommunityPostRequest request) =>
      _client.invoke<RestoreCommunityPostResponse>(ctx, 'CommunityService',
          'RestoreCommunityPost', request, RestoreCommunityPostResponse());

  /// Change one user's standing in a community. user_id: [A-Za-z0-9-]{1,128}; a target that is missing or
  /// not ACTIVE => NOT_FOUND "user not found", whatever the blocks (F14). ARCHIVED => COMMUNITY_STATE
  /// "community_archived".
  /// - BAN, UNBAN: owner or moderator, else FORBIDDEN "not_moderator". The target must be a plain member or a non-member
  ///   (a ban of a raider who already left is allowed): a moderator target => COMMUNITY_STATE "moderator" for the owner
  ///   (remove the role first) and FORBIDDEN "not_owner" for a moderator; the owner as target => FORBIDDEN "not_owner"
  ///   for a moderator and VALIDATION "user_id" for the owner (themselves). A ban makes the member doc BANNED, moves the
  ///   community from the target's joined to banned and lowers memberCount by 1 if the target was JOINED; it never hides
  ///   earlier posts. UNBAN deletes the record; the user may join again.
  /// - MAKE_MODERATOR, REMOVE_MODERATOR: the owner only, else FORBIDDEN "not_owner". The target must be a JOINED member
  ///   other than the owner, else VALIDATION "user_id". At COMMUNITY_MAX_MODERATORS (10) => LIMIT_REACHED
  ///   "community_moderators". Moderators are kept in appointment order (the first is the longest serving, F12).
  /// A request that changes nothing (a repeated ban, an unban of a user not banned, appointing a moderator again)
  /// writes the idempotency doc only. Every change appends one log entry (BAN, UNBAN, MAKE_MODERATOR,
  /// REMOVE_MODERATOR) naming the actor and the target, and adds the community to both users' memberships modlogged.
  /// action UNSPECIFIED => VALIDATION "action".
  /// One transaction: idempotency doc, the community (fresh), the target's member doc and memberships, the actor's
  /// memberships; the target's profile through identity.Directory.
  $async.Future<SetMemberRoleResponse> setMemberRole(
          $pb.ClientContext? ctx, SetMemberRoleRequest request) =>
      _client.invoke<SetMemberRoleResponse>(ctx, 'CommunityService',
          'SetMemberRole', request, SetMemberRoleResponse());

  /// The community's moderation log, newest first: what the owner and moderators did. Owner and moderators
  /// only, else FORBIDDEN "not_moderator". The community keeps its newest COMMUNITY_MODLOG_MAX (100) entries, so older
  /// ones are gone. Entries never name a post's author; a user who deleted the account reads as actor_deleted or
  /// target_deleted (the action and time stay); an entry written by the platform has no actor and actor_deleted false
  /// (ModerationLogEntry.actor).
  /// Paging: page_size 0 => 25, max 25 (clamped); page_token is sealed, bound to the caller and the community, carries
  /// the last seq returned, and expires after 24 h (expired, foreign or tampered => VALIDATION "page_token", before any lookup).
  $async.Future<ListModerationLogResponse> listModerationLog(
          $pb.ClientContext? ctx, ListModerationLogRequest request) =>
      _client.invoke<ListModerationLogResponse>(ctx, 'CommunityService',
          'ListModerationLog', request, ListModerationLogResponse());
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
