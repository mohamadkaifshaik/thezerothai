// This is a generated file - do not edit.
//
// Generated from dzeroth/common/v1/common.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

/// What a pinned Home tab shows. A new kind is additive: a client that does not know a kind hides that tab.
class HomeTabKind extends $pb.ProtobufEnum {
  static const HomeTabKind HOME_TAB_KIND_UNSPECIFIED =
      HomeTabKind._(0, _omitEnumNames ? '' : 'HOME_TAB_KIND_UNSPECIFIED');

  /// A list (dzeroth.lists.v1, FEATURE_LISTS). The tab reads TimelineService.GetListTimeline.
  static const HomeTabKind HOME_TAB_KIND_LIST =
      HomeTabKind._(1, _omitEnumNames ? '' : 'HOME_TAB_KIND_LIST');

  /// A community (dzeroth.communities.v1, FEATURE_COMMUNITIES). The tab reads
  /// TimelineService.GetCommunityTimeline. Any ACTIVE or ARCHIVED community may be pinned, member or not (communities
  /// are public); leaving a community does not unpin it. GetMe omits these tabs while FEATURE_COMMUNITIES is off for the
  /// caller and keeps them in storage. Until GetCommunityTimeline ships, SetHomeTabs answers VALIDATION
  /// "tabs" for it and GetMe never returns it.
  static const HomeTabKind HOME_TAB_KIND_COMMUNITY =
      HomeTabKind._(2, _omitEnumNames ? '' : 'HOME_TAB_KIND_COMMUNITY');

  static const $core.List<HomeTabKind> values = <HomeTabKind>[
    HOME_TAB_KIND_UNSPECIFIED,
    HOME_TAB_KIND_LIST,
    HOME_TAB_KIND_COMMUNITY,
  ];

  static final $core.List<HomeTabKind?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 2);
  static HomeTabKind? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const HomeTabKind._(super.value, super.name);
}

class ErrorReason extends $pb.ProtobufEnum {
  static const ErrorReason ERROR_REASON_UNSPECIFIED =
      ErrorReason._(0, _omitEnumNames ? '' : 'ERROR_REASON_UNSPECIFIED');

  /// INVALID_ARGUMENT: input failed validation; metadata["field"] names the field.
  static const ErrorReason ERROR_REASON_VALIDATION =
      ErrorReason._(1, _omitEnumNames ? '' : 'ERROR_REASON_VALIDATION');

  /// RESOURCE_EXHAUSTED: short-window per-user/IP token bucket (in memory), or a per-instance in-memory daily cap.
  /// Daily caps set metadata["limit"] (e.g. "graph_mutation_daily", "messages_daily", "profile_update_daily") and a
  /// retry_after that runs to the next IST midnight.
  static const ErrorReason ERROR_REASON_RATE_LIMITED =
      ErrorReason._(2, _omitEnumNames ? '' : 'ERROR_REASON_RATE_LIMITED');

  /// RESOURCE_EXHAUSTED: a persisted per-user daily quota, metadata["quota"] names it. Only two quota counters
  /// remain: "reports" (ReportContent) and "dmNew" (new direct-message conversations); SendMessage reports the
  /// second as LIMIT_REACHED "dm_new_daily", so ReportContent is the only RPC that answers this today. Every other
  /// daily limit answers RATE_LIMITED. The value stays in the enum for clients that still send or match it.
  static const ErrorReason ERROR_REASON_QUOTA_EXCEEDED =
      ErrorReason._(3, _omitEnumNames ? '' : 'ERROR_REASON_QUOTA_EXCEEDED');

  /// UNAVAILABLE: the platform is in degraded mode (readonly or nomedia). Show a banner; do NOT auto-retry.
  static const ErrorReason ERROR_REASON_DEGRADED_MODE =
      ErrorReason._(4, _omitEnumNames ? '' : 'ERROR_REASON_DEGRADED_MODE');

  /// UNAUTHENTICATED: missing/invalid Firebase App Check token.
  static const ErrorReason ERROR_REASON_APP_CHECK_REQUIRED =
      ErrorReason._(5, _omitEnumNames ? '' : 'ERROR_REASON_APP_CHECK_REQUIRED');

  /// FAILED_PRECONDITION: caller has a Firebase account but has not called CreateProfile yet.
  static const ErrorReason ERROR_REASON_PROFILE_REQUIRED =
      ErrorReason._(6, _omitEnumNames ? '' : 'ERROR_REASON_PROFILE_REQUIRED');

  /// FAILED_PRECONDITION: email must be verified (or Google/Apple sign-in used) before this action.
  static const ErrorReason ERROR_REASON_EMAIL_NOT_VERIFIED =
      ErrorReason._(7, _omitEnumNames ? '' : 'ERROR_REASON_EMAIL_NOT_VERIFIED');

  /// ALREADY_EXISTS: handle is taken.
  static const ErrorReason ERROR_REASON_HANDLE_TAKEN =
      ErrorReason._(8, _omitEnumNames ? '' : 'ERROR_REASON_HANDLE_TAKEN');

  /// FAILED_PRECONDITION: a fixed cap was reached (e.g. following 5,000 accounts). Also VotePoll when the caller has
  /// already changed this vote POLL_VOTE_CHANGES_MAX times: metadata["limit"] =
  /// "poll_vote_changes" and metadata["choice"] = the stored choice as a 0-based index.
  static const ErrorReason ERROR_REASON_LIMIT_REACHED =
      ErrorReason._(9, _omitEnumNames ? '' : 'ERROR_REASON_LIMIT_REACHED');

  /// FAILED_PRECONDITION: referenced media is not READY or not owned by the caller.
  static const ErrorReason ERROR_REASON_MEDIA_NOT_READY =
      ErrorReason._(10, _omitEnumNames ? '' : 'ERROR_REASON_MEDIA_NOT_READY');

  /// INVALID_ARGUMENT: the same idempotency_key was reused with a different request body.
  static const ErrorReason ERROR_REASON_IDEMPOTENCY_KEY_REUSED = ErrorReason._(
      11, _omitEnumNames ? '' : 'ERROR_REASON_IDEMPOTENCY_KEY_REUSED');

  /// PERMISSION_DENIED: the account is suspended or pending deletion.
  static const ErrorReason ERROR_REASON_ACCOUNT_RESTRICTED = ErrorReason._(
      12, _omitEnumNames ? '' : 'ERROR_REASON_ACCOUNT_RESTRICTED');

  /// FAILED_PRECONDITION: the caller blocks the target (e.g. Follow). Unblock first; never auto-unblocked.
  /// Also EngagementService.VotePoll when the caller blocks the poll's author: refused for a
  /// cast, a change and a replay; the vote already cast is kept and counted.
  static const ErrorReason ERROR_REASON_TARGET_BLOCKED =
      ErrorReason._(13, _omitEnumNames ? '' : 'ERROR_REASON_TARGET_BLOCKED');

  /// FAILED_PRECONDITION: the feature is not enabled for this caller (server feature flag, or not built yet). Hide the
  /// feature and refresh GetMe.enabled_features; do not retry.
  /// metadata["feature"], when set, names a sub-feature (e.g. "replies", "quotes", "media"): hide only that one.
  /// When absent, the whole feature behind the called service is off.
  static const ErrorReason ERROR_REASON_FEATURE_DISABLED =
      ErrorReason._(14, _omitEnumNames ? '' : 'ERROR_REASON_FEATURE_DISABLED');

  /// FAILED_PRECONDITION: the action needs a recent sign-in (DeleteAccount and RequestAccountExport: ID token auth_time older than
  /// ACCOUNT_DELETE_REAUTH_MAX_AGE, or missing). Ask the user to sign in again to continue, then retry once with the
  /// same idempotency_key; do not loop.
  static const ErrorReason ERROR_REASON_REAUTH_REQUIRED =
      ErrorReason._(15, _omitEnumNames ? '' : 'ERROR_REASON_REAUTH_REQUIRED');

  /// PERMISSION_DENIED: the conversation's reply policy does not include the caller. metadata["policy"]
  /// names the conversation's policy. Only returned once the conversation root is visible to the caller;
  /// an unusable root (deleted, hidden, a block in either direction) answers NOT_FOUND instead. Do not retry; show
  /// the policy label.
  static const ErrorReason ERROR_REASON_REPLY_NOT_ALLOWED =
      ErrorReason._(16, _omitEnumNames ? '' : 'ERROR_REASON_REPLY_NOT_ALLOWED');

  /// FAILED_PRECONDITION: the account's posts are protected. Returned for ListFollowers or ListFollowing of
  /// a protected account to a non-follower, and for a repost or quote of a protected account's post. Do not retry.
  static const ErrorReason ERROR_REASON_PROTECTED_ACCOUNT =
      ErrorReason._(17, _omitEnumNames ? '' : 'ERROR_REASON_PROTECTED_ACCOUNT');

  /// FAILED_PRECONDITION: this account cannot be messaged. One reason with identical bytes for a block in
  /// either direction, a recipient with messaging off, a recipient who is gone or not ACTIVE, and a conversation whose
  /// peer deleted the account, so it reveals no more than GetProfile's NOT_FOUND. Do not retry; show "You can't
  /// message this account".
  static const ErrorReason ERROR_REASON_CANNOT_MESSAGE =
      ErrorReason._(18, _omitEnumNames ? '' : 'ERROR_REASON_CANNOT_MESSAGE');

  /// FAILED_PRECONDITION: the poll has closed (server time is the authority). Refresh the post (GetPost)
  /// and show its final results; do not retry.
  static const ErrorReason ERROR_REASON_POLL_CLOSED =
      ErrorReason._(19, _omitEnumNames ? '' : 'ERROR_REASON_POLL_CLOSED');

  /// FAILED_PRECONDITION: the caller already voted in this poll with another choice and the request did not name that vote
  /// in expected_choice. A vote is changeable until the poll closes,
  /// so this is now only a stale or missing expected_choice (an older client, a second device, a late retry).
  /// metadata["choice"] is the caller's own stored choice as a 0-based index (decimal). Call VotePoll once more with
  /// that choice (or, with a current expected_choice, to change it): a vote with the same choice is not an error, it returns the current state with results
  /// and writes nothing.
  static const ErrorReason ERROR_REASON_ALREADY_VOTED =
      ErrorReason._(20, _omitEnumNames ? '' : 'ERROR_REASON_ALREADY_VOTED');

  /// PERMISSION_DENIED: the caller's role does not allow this action (communities.v1 header). Never sent for
  /// an account suspension (that is ACCOUNT_RESTRICTED). metadata["reason"] names why: "banned", "not_member",
  /// "not_moderator", "not_owner" or "not_creator". Do not retry; show a fixed message per reason ("not_member" on a
  /// reply: "Only members can reply"). A client built before this value sees UNSPECIFIED and falls back to the
  /// PERMISSION_DENIED code mapping, a generic "restricted" message. The only path an older client can reach is a reply
  /// in a community conversation (CreatePost), since that gate runs whenever communities is not globally off.
  static const ErrorReason ERROR_REASON_FORBIDDEN =
      ErrorReason._(21, _omitEnumNames ? '' : 'ERROR_REASON_FORBIDDEN');

  /// FAILED_PRECONDITION: the action conflicts with the community's state or a role held in it (communities.v1 header).
  /// metadata["reason"] is "owner" (the owner cannot leave), "moderator" (remove the moderator role before a ban)
  /// or "community_archived" (an ARCHIVED community is read-only). Do not retry. A client built before this value sees
  /// UNSPECIFIED and falls back to the FAILED_PRECONDITION code mapping; it can reach this value only on a reply in an
  /// ARCHIVED community's conversation (CreatePost).
  static const ErrorReason ERROR_REASON_COMMUNITY_STATE =
      ErrorReason._(22, _omitEnumNames ? '' : 'ERROR_REASON_COMMUNITY_STATE');

  static const $core.List<ErrorReason> values = <ErrorReason>[
    ERROR_REASON_UNSPECIFIED,
    ERROR_REASON_VALIDATION,
    ERROR_REASON_RATE_LIMITED,
    ERROR_REASON_QUOTA_EXCEEDED,
    ERROR_REASON_DEGRADED_MODE,
    ERROR_REASON_APP_CHECK_REQUIRED,
    ERROR_REASON_PROFILE_REQUIRED,
    ERROR_REASON_EMAIL_NOT_VERIFIED,
    ERROR_REASON_HANDLE_TAKEN,
    ERROR_REASON_LIMIT_REACHED,
    ERROR_REASON_MEDIA_NOT_READY,
    ERROR_REASON_IDEMPOTENCY_KEY_REUSED,
    ERROR_REASON_ACCOUNT_RESTRICTED,
    ERROR_REASON_TARGET_BLOCKED,
    ERROR_REASON_FEATURE_DISABLED,
    ERROR_REASON_REAUTH_REQUIRED,
    ERROR_REASON_REPLY_NOT_ALLOWED,
    ERROR_REASON_PROTECTED_ACCOUNT,
    ERROR_REASON_CANNOT_MESSAGE,
    ERROR_REASON_POLL_CLOSED,
    ERROR_REASON_ALREADY_VOTED,
    ERROR_REASON_FORBIDDEN,
    ERROR_REASON_COMMUNITY_STATE,
  ];

  static final $core.List<ErrorReason?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 22);
  static ErrorReason? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const ErrorReason._(super.value, super.name);
}

const $core.bool _omitEnumNames =
    $core.bool.fromEnvironment('protobuf.omit_enum_names');
