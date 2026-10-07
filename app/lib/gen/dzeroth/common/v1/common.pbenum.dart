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

class ErrorReason extends $pb.ProtobufEnum {
  static const ErrorReason ERROR_REASON_UNSPECIFIED =
      ErrorReason._(0, _omitEnumNames ? '' : 'ERROR_REASON_UNSPECIFIED');

  /// INVALID_ARGUMENT: input failed validation; metadata["field"] names the field.
  static const ErrorReason ERROR_REASON_VALIDATION =
      ErrorReason._(1, _omitEnumNames ? '' : 'ERROR_REASON_VALIDATION');

  /// RESOURCE_EXHAUSTED: short-window per-user/IP token bucket (in memory), or an in-memory daily cap. Daily caps
  /// set metadata["limit"] (e.g. "read_budget_daily": the per-uid daily Firestore read budget, ADR-0010 D5;
  /// "check_handle_daily"; "account_ops_daily": the 20 calls/day shared by DeleteAccount, RequestAccountExport and
  /// GetAccountExport) and a retry_after that runs to the next IST midnight.
  /// metadata["limit"] = "read_budget_inflight" is TRANSIENT (ADR-0010 D5 A1): the budget is not spent, another call
  /// of the same user is in flight near the cap. retry_after is 1 s; retry ONCE, silently, and show an error only
  /// if the retry also fails.
  static const ErrorReason ERROR_REASON_RATE_LIMITED =
      ErrorReason._(2, _omitEnumNames ? '' : 'ERROR_REASON_RATE_LIMITED');

  /// RESOURCE_EXHAUSTED: per-user daily quota (posts, follows, uploads...); metadata["quota"] names it.
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

  /// FAILED_PRECONDITION: a fixed cap was reached (e.g. following 5,000 accounts).
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

  /// FAILED_PRECONDITION: the caller blocks the target (e.g. Follow). Unblock first; never auto-unblocked (ADR-0008).
  static const ErrorReason ERROR_REASON_TARGET_BLOCKED =
      ErrorReason._(13, _omitEnumNames ? '' : 'ERROR_REASON_TARGET_BLOCKED');

  /// FAILED_PRECONDITION: the feature is not enabled for this caller (server feature flag, or not built yet, e.g.
  /// follow requests). Hide the feature and refresh GetMe.enabled_features; do not retry (ADR-0008 D6).
  /// metadata["feature"], when set, names a sub-feature (e.g. "replies", "quotes", "media"): hide only that one
  /// (ADR-0010 D2). When absent, the whole feature behind the called service is off.
  static const ErrorReason ERROR_REASON_FEATURE_DISABLED =
      ErrorReason._(14, _omitEnumNames ? '' : 'ERROR_REASON_FEATURE_DISABLED');

  /// FAILED_PRECONDITION: the action needs a recent sign-in (e.g. DeleteAccount: ID token auth_time older than
  /// ACCOUNT_DELETE_REAUTH_MAX_AGE, or missing). Ask the user to sign in again to continue, then retry once with the
  /// same idempotency_key; do not loop.
  static const ErrorReason ERROR_REASON_REAUTH_REQUIRED =
      ErrorReason._(15, _omitEnumNames ? '' : 'ERROR_REASON_REAUTH_REQUIRED');

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
  ];

  static final $core.List<ErrorReason?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 15);
  static ErrorReason? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const ErrorReason._(super.value, super.name);
}

const $core.bool _omitEnumNames =
    $core.bool.fromEnvironment('protobuf.omit_enum_names');
