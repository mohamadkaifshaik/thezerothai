// This is a generated file - do not edit.
//
// Generated from dzeroth/communities/v1/communities.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

/// The caller's role in a community. Returned as viewer_role and CommunityMember.role; the client never
/// infers one. A new value is additive: a client that does not know a value treats it as NONE.
class CommunityRole extends $pb.ProtobufEnum {
  /// Not computed (an older server): treat as NONE.
  static const CommunityRole COMMUNITY_ROLE_UNSPECIFIED =
      CommunityRole._(0, _omitEnumNames ? '' : 'COMMUNITY_ROLE_UNSPECIFIED');

  /// The community's owner (always a JOINED member).
  static const CommunityRole COMMUNITY_ROLE_OWNER =
      CommunityRole._(1, _omitEnumNames ? '' : 'COMMUNITY_ROLE_OWNER');

  /// An appointed moderator (always a JOINED member, never the owner).
  static const CommunityRole COMMUNITY_ROLE_MODERATOR =
      CommunityRole._(2, _omitEnumNames ? '' : 'COMMUNITY_ROLE_MODERATOR');

  /// A JOINED member who holds no role.
  static const CommunityRole COMMUNITY_ROLE_MEMBER =
      CommunityRole._(3, _omitEnumNames ? '' : 'COMMUNITY_ROLE_MEMBER');

  /// Banned from this community: may read it, may not join, post or reply.
  static const CommunityRole COMMUNITY_ROLE_BANNED =
      CommunityRole._(4, _omitEnumNames ? '' : 'COMMUNITY_ROLE_BANNED');

  /// Anyone else (not a member, not banned).
  static const CommunityRole COMMUNITY_ROLE_NONE =
      CommunityRole._(5, _omitEnumNames ? '' : 'COMMUNITY_ROLE_NONE');

  static const $core.List<CommunityRole> values = <CommunityRole>[
    COMMUNITY_ROLE_UNSPECIFIED,
    COMMUNITY_ROLE_OWNER,
    COMMUNITY_ROLE_MODERATOR,
    COMMUNITY_ROLE_MEMBER,
    COMMUNITY_ROLE_BANNED,
    COMMUNITY_ROLE_NONE,
  ];

  static final $core.List<CommunityRole?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 5);
  static CommunityRole? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const CommunityRole._(super.value, super.name);
}

class CommunityStatus extends $pb.ProtobufEnum {
  static const CommunityStatus COMMUNITY_STATUS_UNSPECIFIED = CommunityStatus._(
      0, _omitEnumNames ? '' : 'COMMUNITY_STATUS_UNSPECIFIED');
  static const CommunityStatus COMMUNITY_STATUS_ACTIVE =
      CommunityStatus._(1, _omitEnumNames ? '' : 'COMMUNITY_STATUS_ACTIVE');

  /// Read-only, out of the directory, still readable (header comment).
  static const CommunityStatus COMMUNITY_STATUS_ARCHIVED =
      CommunityStatus._(2, _omitEnumNames ? '' : 'COMMUNITY_STATUS_ARCHIVED');

  /// Taken offline by the platform. Only its owner ever receives it (GetCommunity, ListMyCommunities).
  static const CommunityStatus COMMUNITY_STATUS_SUSPENDED =
      CommunityStatus._(3, _omitEnumNames ? '' : 'COMMUNITY_STATUS_SUSPENDED');

  static const $core.List<CommunityStatus> values = <CommunityStatus>[
    COMMUNITY_STATUS_UNSPECIFIED,
    COMMUNITY_STATUS_ACTIVE,
    COMMUNITY_STATUS_ARCHIVED,
    COMMUNITY_STATUS_SUSPENDED,
  ];

  static final $core.List<CommunityStatus?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 3);
  static CommunityStatus? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const CommunityStatus._(super.value, super.name);
}

/// Who may read a community (F6). PUBLIC is the only value at Stage 0; restricted or private communities need their own
/// ADR (a members-only filter on every read path) and would add a value here.
class CommunityVisibility extends $pb.ProtobufEnum {
  static const CommunityVisibility COMMUNITY_VISIBILITY_UNSPECIFIED =
      CommunityVisibility._(
          0, _omitEnumNames ? '' : 'COMMUNITY_VISIBILITY_UNSPECIFIED');
  static const CommunityVisibility COMMUNITY_VISIBILITY_PUBLIC =
      CommunityVisibility._(
          1, _omitEnumNames ? '' : 'COMMUNITY_VISIBILITY_PUBLIC');

  static const $core.List<CommunityVisibility> values = <CommunityVisibility>[
    COMMUNITY_VISIBILITY_UNSPECIFIED,
    COMMUNITY_VISIBILITY_PUBLIC,
  ];

  static final $core.List<CommunityVisibility?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 1);
  static CommunityVisibility? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const CommunityVisibility._(super.value, super.name);
}

/// Which rows ListCommunityMembers returns. Named after the member doc's state, not a role.
class CommunityMemberFilter extends $pb.ProtobufEnum {
  /// Same as JOINED.
  static const CommunityMemberFilter COMMUNITY_MEMBER_FILTER_UNSPECIFIED =
      CommunityMemberFilter._(
          0, _omitEnumNames ? '' : 'COMMUNITY_MEMBER_FILTER_UNSPECIFIED');

  /// JOINED members, the owner and moderators included.
  static const CommunityMemberFilter COMMUNITY_MEMBER_FILTER_JOINED =
      CommunityMemberFilter._(
          1, _omitEnumNames ? '' : 'COMMUNITY_MEMBER_FILTER_JOINED');

  /// Banned users. Owner and moderators only.
  static const CommunityMemberFilter COMMUNITY_MEMBER_FILTER_BANNED =
      CommunityMemberFilter._(
          2, _omitEnumNames ? '' : 'COMMUNITY_MEMBER_FILTER_BANNED');

  static const $core.List<CommunityMemberFilter> values =
      <CommunityMemberFilter>[
    COMMUNITY_MEMBER_FILTER_UNSPECIFIED,
    COMMUNITY_MEMBER_FILTER_JOINED,
    COMMUNITY_MEMBER_FILTER_BANNED,
  ];

  static final $core.List<CommunityMemberFilter?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 2);
  static CommunityMemberFilter? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const CommunityMemberFilter._(super.value, super.name);
}

/// What SetMemberRole does to its target.
class MemberRoleAction extends $pb.ProtobufEnum {
  static const MemberRoleAction MEMBER_ROLE_ACTION_UNSPECIFIED =
      MemberRoleAction._(
          0, _omitEnumNames ? '' : 'MEMBER_ROLE_ACTION_UNSPECIFIED');

  /// Owner or moderator; the target is a plain member or a non-member.
  static const MemberRoleAction MEMBER_ROLE_ACTION_BAN =
      MemberRoleAction._(1, _omitEnumNames ? '' : 'MEMBER_ROLE_ACTION_BAN');

  /// Owner or moderator; deletes the ban record.
  static const MemberRoleAction MEMBER_ROLE_ACTION_UNBAN =
      MemberRoleAction._(2, _omitEnumNames ? '' : 'MEMBER_ROLE_ACTION_UNBAN');

  /// Owner only; the target is a JOINED member.
  static const MemberRoleAction MEMBER_ROLE_ACTION_MAKE_MODERATOR =
      MemberRoleAction._(
          3, _omitEnumNames ? '' : 'MEMBER_ROLE_ACTION_MAKE_MODERATOR');

  /// Owner only; the moderator stays a member.
  static const MemberRoleAction MEMBER_ROLE_ACTION_REMOVE_MODERATOR =
      MemberRoleAction._(
          4, _omitEnumNames ? '' : 'MEMBER_ROLE_ACTION_REMOVE_MODERATOR');

  static const $core.List<MemberRoleAction> values = <MemberRoleAction>[
    MEMBER_ROLE_ACTION_UNSPECIFIED,
    MEMBER_ROLE_ACTION_BAN,
    MEMBER_ROLE_ACTION_UNBAN,
    MEMBER_ROLE_ACTION_MAKE_MODERATOR,
    MEMBER_ROLE_ACTION_REMOVE_MODERATOR,
  ];

  static final $core.List<MemberRoleAction?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 4);
  static MemberRoleAction? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const MemberRoleAction._(super.value, super.name);
}

/// One moderation-log action. A new value is additive: a client that does not know one shows a generic
/// "Moderation action".
class ModerationLogAction extends $pb.ProtobufEnum {
  static const ModerationLogAction MODERATION_LOG_ACTION_UNSPECIFIED =
      ModerationLogAction._(
          0, _omitEnumNames ? '' : 'MODERATION_LOG_ACTION_UNSPECIFIED');

  /// A post or a reply was hidden from the community view (post_id set).
  static const ModerationLogAction MODERATION_LOG_ACTION_HIDE =
      ModerationLogAction._(
          1, _omitEnumNames ? '' : 'MODERATION_LOG_ACTION_HIDE');

  /// A hidden post or reply was restored (post_id set). With the platform as actor (ModerationLogEntry.actor) and
  /// post_id "": one bulk restore by `opsctl community restore-hidden`, one entry per run however many posts it
  /// restored.
  static const ModerationLogAction MODERATION_LOG_ACTION_RESTORE =
      ModerationLogAction._(
          2, _omitEnumNames ? '' : 'MODERATION_LOG_ACTION_RESTORE');

  /// target was banned.
  static const ModerationLogAction MODERATION_LOG_ACTION_BAN =
      ModerationLogAction._(
          3, _omitEnumNames ? '' : 'MODERATION_LOG_ACTION_BAN');

  /// target was unbanned.
  static const ModerationLogAction MODERATION_LOG_ACTION_UNBAN =
      ModerationLogAction._(
          4, _omitEnumNames ? '' : 'MODERATION_LOG_ACTION_UNBAN');

  /// target was made a moderator.
  static const ModerationLogAction MODERATION_LOG_ACTION_MAKE_MODERATOR =
      ModerationLogAction._(
          5, _omitEnumNames ? '' : 'MODERATION_LOG_ACTION_MAKE_MODERATOR');

  /// target's moderator role was removed.
  static const ModerationLogAction MODERATION_LOG_ACTION_REMOVE_MODERATOR =
      ModerationLogAction._(
          6, _omitEnumNames ? '' : 'MODERATION_LOG_ACTION_REMOVE_MODERATOR');

  /// The owner edited the name, description or rules.
  static const ModerationLogAction MODERATION_LOG_ACTION_EDIT =
      ModerationLogAction._(
          7, _omitEnumNames ? '' : 'MODERATION_LOG_ACTION_EDIT');

  /// The actor, a moderator, left the community.
  static const ModerationLogAction MODERATION_LOG_ACTION_MODERATOR_LEFT =
      ModerationLogAction._(
          8, _omitEnumNames ? '' : 'MODERATION_LOG_ACTION_MODERATOR_LEFT');

  /// Ownership moved to target after the owner deleted the account (actor_deleted), or the community was archived on
  /// the owner's request with no new owner (target unset, target_deleted false).
  static const ModerationLogAction MODERATION_LOG_ACTION_OWNER_HANDOVER =
      ModerationLogAction._(
          9, _omitEnumNames ? '' : 'MODERATION_LOG_ACTION_OWNER_HANDOVER');

  static const $core.List<ModerationLogAction> values = <ModerationLogAction>[
    MODERATION_LOG_ACTION_UNSPECIFIED,
    MODERATION_LOG_ACTION_HIDE,
    MODERATION_LOG_ACTION_RESTORE,
    MODERATION_LOG_ACTION_BAN,
    MODERATION_LOG_ACTION_UNBAN,
    MODERATION_LOG_ACTION_MAKE_MODERATOR,
    MODERATION_LOG_ACTION_REMOVE_MODERATOR,
    MODERATION_LOG_ACTION_EDIT,
    MODERATION_LOG_ACTION_MODERATOR_LEFT,
    MODERATION_LOG_ACTION_OWNER_HANDOVER,
  ];

  static final $core.List<ModerationLogAction?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 9);
  static ModerationLogAction? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const ModerationLogAction._(super.value, super.name);
}

const $core.bool _omitEnumNames =
    $core.bool.fromEnvironment('protobuf.omit_enum_names');
