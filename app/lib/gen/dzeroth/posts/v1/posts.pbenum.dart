// This is a generated file - do not edit.
//
// Generated from dzeroth/posts/v1/posts.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

class PostKind extends $pb.ProtobufEnum {
  static const PostKind POST_KIND_UNSPECIFIED =
      PostKind._(0, _omitEnumNames ? '' : 'POST_KIND_UNSPECIFIED');
  static const PostKind POST_KIND_POST =
      PostKind._(1, _omitEnumNames ? '' : 'POST_KIND_POST');
  static const PostKind POST_KIND_REPLY =
      PostKind._(2, _omitEnumNames ? '' : 'POST_KIND_REPLY');
  static const PostKind POST_KIND_QUOTE =
      PostKind._(3, _omitEnumNames ? '' : 'POST_KIND_QUOTE');

  /// Created by EngagementService.RepostPost (P5); stored as a post doc authored by the reposter, with an
  /// embedded snapshot of the original, so pull timelines include it with no extra query. Its own counters stay 0:
  /// like, repost and quote actions apply to embedded.post_id, the original.
  static const PostKind POST_KIND_REPOST =
      PostKind._(4, _omitEnumNames ? '' : 'POST_KIND_REPOST');

  static const $core.List<PostKind> values = <PostKind>[
    POST_KIND_UNSPECIFIED,
    POST_KIND_POST,
    POST_KIND_REPLY,
    POST_KIND_QUOTE,
    POST_KIND_REPOST,
  ];

  static final $core.List<PostKind?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 4);
  static PostKind? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const PostKind._(super.value, super.name);
}

class Visibility extends $pb.ProtobufEnum {
  static const Visibility VISIBILITY_UNSPECIFIED =
      Visibility._(0, _omitEnumNames ? '' : 'VISIBILITY_UNSPECIFIED');
  static const Visibility VISIBILITY_PUBLIC =
      Visibility._(1, _omitEnumNames ? '' : 'VISIBILITY_PUBLIC');

  /// Author is a private account: only approved followers and the author.
  static const Visibility VISIBILITY_FOLLOWERS =
      Visibility._(2, _omitEnumNames ? '' : 'VISIBILITY_FOLLOWERS');

  static const $core.List<Visibility> values = <Visibility>[
    VISIBILITY_UNSPECIFIED,
    VISIBILITY_PUBLIC,
    VISIBILITY_FOLLOWERS,
  ];

  static final $core.List<Visibility?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 2);
  static Visibility? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const Visibility._(super.value, super.name);
}

/// Who may reply in a conversation (ADR-0021 D2). Set on the first post of a conversation (a root post or a quote);
/// replies carry the effective policy inherited from their parent. The conversation root's author may always reply.
class ReplyPolicy extends $pb.ProtobufEnum {
  /// Same as EVERYONE. Every post written before ADR-0021 has it.
  static const ReplyPolicy REPLY_POLICY_UNSPECIFIED =
      ReplyPolicy._(0, _omitEnumNames ? '' : 'REPLY_POLICY_UNSPECIFIED');
  static const ReplyPolicy REPLY_POLICY_EVERYONE =
      ReplyPolicy._(1, _omitEnumNames ? '' : 'REPLY_POLICY_EVERYONE');

  /// Accounts the conversation root's author follows.
  static const ReplyPolicy REPLY_POLICY_FOLLOWING =
      ReplyPolicy._(2, _omitEnumNames ? '' : 'REPLY_POLICY_FOLLOWING');

  /// Accounts mentioned in the conversation root.
  static const ReplyPolicy REPLY_POLICY_MENTIONED_ONLY =
      ReplyPolicy._(3, _omitEnumNames ? '' : 'REPLY_POLICY_MENTIONED_ONLY');

  /// Not available yet: rejected with VALIDATION field "reply_policy". Declared (not reserved) so a later ADR can
  /// enable it without a new value.
  static const ReplyPolicy REPLY_POLICY_FOLLOWING_OF_FOLLOWING = ReplyPolicy._(
      4, _omitEnumNames ? '' : 'REPLY_POLICY_FOLLOWING_OF_FOLLOWING');

  /// Not available yet: rejected with VALIDATION field "reply_policy".
  static const ReplyPolicy REPLY_POLICY_VERIFIED =
      ReplyPolicy._(5, _omitEnumNames ? '' : 'REPLY_POLICY_VERIFIED');

  static const $core.List<ReplyPolicy> values = <ReplyPolicy>[
    REPLY_POLICY_UNSPECIFIED,
    REPLY_POLICY_EVERYONE,
    REPLY_POLICY_FOLLOWING,
    REPLY_POLICY_MENTIONED_ONLY,
    REPLY_POLICY_FOLLOWING_OF_FOLLOWING,
    REPLY_POLICY_VERIFIED,
  ];

  static final $core.List<ReplyPolicy?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 5);
  static ReplyPolicy? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const ReplyPolicy._(super.value, super.name);
}

/// Whether the viewer may reply, as far as the server can tell without extra reads (ADR-0021 D2). Advisory only:
/// CreatePost decides.
class ReplyPermission extends $pb.ProtobufEnum {
  /// An older server that does not compute it: treat as allowed.
  static const ReplyPermission REPLY_PERMISSION_UNSPECIFIED = ReplyPermission._(
      0, _omitEnumNames ? '' : 'REPLY_PERMISSION_UNSPECIFIED');
  static const ReplyPermission REPLY_PERMISSION_ALLOWED =
      ReplyPermission._(1, _omitEnumNames ? '' : 'REPLY_PERMISSION_ALLOWED');
  static const ReplyPermission REPLY_PERMISSION_NOT_ALLOWED = ReplyPermission._(
      2, _omitEnumNames ? '' : 'REPLY_PERMISSION_NOT_ALLOWED');

  /// Not decided (e.g. a reply row in a restricted conversation, a FOLLOWING root in a timeline): show the policy
  /// label and let CreatePost decide.
  static const ReplyPermission REPLY_PERMISSION_UNKNOWN =
      ReplyPermission._(3, _omitEnumNames ? '' : 'REPLY_PERMISSION_UNKNOWN');

  static const $core.List<ReplyPermission> values = <ReplyPermission>[
    REPLY_PERMISSION_UNSPECIFIED,
    REPLY_PERMISSION_ALLOWED,
    REPLY_PERMISSION_NOT_ALLOWED,
    REPLY_PERMISSION_UNKNOWN,
  ];

  static final $core.List<ReplyPermission?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 3);
  static ReplyPermission? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const ReplyPermission._(super.value, super.name);
}

/// Lifecycle of a scheduled post (ADR-0021 D4).
class ScheduledPostStatus extends $pb.ProtobufEnum {
  static const ScheduledPostStatus SCHEDULED_POST_STATUS_UNSPECIFIED =
      ScheduledPostStatus._(
          0, _omitEnumNames ? '' : 'SCHEDULED_POST_STATUS_UNSPECIFIED');

  /// Waiting for publish_at.
  static const ScheduledPostStatus SCHEDULED_POST_STATUS_PENDING =
      ScheduledPostStatus._(
          1, _omitEnumNames ? '' : 'SCHEDULED_POST_STATUS_PENDING');

  /// Published as post_id. Text and media are no longer returned.
  static const ScheduledPostStatus SCHEDULED_POST_STATUS_PUBLISHED =
      ScheduledPostStatus._(
          2, _omitEnumNames ? '' : 'SCHEDULED_POST_STATUS_PUBLISHED');

  /// Cancelled by the user, or the account was being deleted at publish time. Text and media are no longer returned.
  static const ScheduledPostStatus SCHEDULED_POST_STATUS_CANCELLED =
      ScheduledPostStatus._(
          3, _omitEnumNames ? '' : 'SCHEDULED_POST_STATUS_CANCELLED');

  /// Not published; see failure. Keeps text and media so the client can offer "reschedule" (a new SchedulePost).
  static const ScheduledPostStatus SCHEDULED_POST_STATUS_FAILED =
      ScheduledPostStatus._(
          4, _omitEnumNames ? '' : 'SCHEDULED_POST_STATUS_FAILED');

  static const $core.List<ScheduledPostStatus> values = <ScheduledPostStatus>[
    SCHEDULED_POST_STATUS_UNSPECIFIED,
    SCHEDULED_POST_STATUS_PENDING,
    SCHEDULED_POST_STATUS_PUBLISHED,
    SCHEDULED_POST_STATUS_CANCELLED,
    SCHEDULED_POST_STATUS_FAILED,
  ];

  static final $core.List<ScheduledPostStatus?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 4);
  static ScheduledPostStatus? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const ScheduledPostStatus._(super.value, super.name);
}

/// Why a scheduled post was not published (status FAILED).
class ScheduledPostFailure extends $pb.ProtobufEnum {
  static const ScheduledPostFailure SCHEDULED_POST_FAILURE_UNSPECIFIED =
      ScheduledPostFailure._(
          0, _omitEnumNames ? '' : 'SCHEDULED_POST_FAILURE_UNSPECIFIED');

  /// An image was missing, used by another post, or no longer READY at publish time.
  static const ScheduledPostFailure SCHEDULED_POST_FAILURE_MEDIA_UNAVAILABLE =
      ScheduledPostFailure._(
          1, _omitEnumNames ? '' : 'SCHEDULED_POST_FAILURE_MEDIA_UNAVAILABLE');

  /// The posts daily quota was used up at publish time.
  static const ScheduledPostFailure SCHEDULED_POST_FAILURE_QUOTA_EXCEEDED =
      ScheduledPostFailure._(
          2, _omitEnumNames ? '' : 'SCHEDULED_POST_FAILURE_QUOTA_EXCEEDED');

  /// The account was suspended at publish time. Unsuspension does not revive the item.
  static const ScheduledPostFailure SCHEDULED_POST_FAILURE_ACCOUNT_RESTRICTED =
      ScheduledPostFailure._(
          3, _omitEnumNames ? '' : 'SCHEDULED_POST_FAILURE_ACCOUNT_RESTRICTED');

  /// The text no longer passes the post rules.
  static const ScheduledPostFailure SCHEDULED_POST_FAILURE_INVALID_CONTENT =
      ScheduledPostFailure._(
          4, _omitEnumNames ? '' : 'SCHEDULED_POST_FAILURE_INVALID_CONTENT');

  /// Not published within 6 h of publish_at (e.g. after an outage).
  static const ScheduledPostFailure SCHEDULED_POST_FAILURE_EXPIRED =
      ScheduledPostFailure._(
          5, _omitEnumNames ? '' : 'SCHEDULED_POST_FAILURE_EXPIRED');

  /// Repeated server errors.
  static const ScheduledPostFailure SCHEDULED_POST_FAILURE_INTERNAL =
      ScheduledPostFailure._(
          6, _omitEnumNames ? '' : 'SCHEDULED_POST_FAILURE_INTERNAL');

  /// Written by a newer server version that this one cannot publish.
  static const ScheduledPostFailure SCHEDULED_POST_FAILURE_UNSUPPORTED =
      ScheduledPostFailure._(
          7, _omitEnumNames ? '' : 'SCHEDULED_POST_FAILURE_UNSUPPORTED');

  static const $core.List<ScheduledPostFailure> values = <ScheduledPostFailure>[
    SCHEDULED_POST_FAILURE_UNSPECIFIED,
    SCHEDULED_POST_FAILURE_MEDIA_UNAVAILABLE,
    SCHEDULED_POST_FAILURE_QUOTA_EXCEEDED,
    SCHEDULED_POST_FAILURE_ACCOUNT_RESTRICTED,
    SCHEDULED_POST_FAILURE_INVALID_CONTENT,
    SCHEDULED_POST_FAILURE_EXPIRED,
    SCHEDULED_POST_FAILURE_INTERNAL,
    SCHEDULED_POST_FAILURE_UNSUPPORTED,
  ];

  static final $core.List<ScheduledPostFailure?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 7);
  static ScheduledPostFailure? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const ScheduledPostFailure._(super.value, super.name);
}

const $core.bool _omitEnumNames =
    $core.bool.fromEnvironment('protobuf.omit_enum_names');
