// This is a generated file - do not edit.
//
// Generated from dzeroth/moderation/v1/moderation.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

class ReportTargetType extends $pb.ProtobufEnum {
  static const ReportTargetType REPORT_TARGET_TYPE_UNSPECIFIED =
      ReportTargetType._(
          0, _omitEnumNames ? '' : 'REPORT_TARGET_TYPE_UNSPECIFIED');
  static const ReportTargetType REPORT_TARGET_TYPE_POST =
      ReportTargetType._(1, _omitEnumNames ? '' : 'REPORT_TARGET_TYPE_POST');
  static const ReportTargetType REPORT_TARGET_TYPE_ACCOUNT =
      ReportTargetType._(2, _omitEnumNames ? '' : 'REPORT_TARGET_TYPE_ACCOUNT');

  /// A direct message. target_id = "<convId>:<msgId>": the conversation id and the message id, 32
  /// lower-case hex each, joined by ":". Only a participant may report, and only the peer's message (own => VALIDATION
  /// "target_id"). The evidence is that one message's text, the sender's handle and its time; nothing else from the
  /// conversation. Needs FEATURE_MESSAGING not globally off; the existing reports quota applies.
  static const ReportTargetType REPORT_TARGET_TYPE_MESSAGE =
      ReportTargetType._(3, _omitEnumNames ? '' : 'REPORT_TARGET_TYPE_MESSAGE');

  /// A list. target_id = the list id (19 digits). Only a list the caller may see can be
  /// reported; a private, hidden, missing or blocking-owner list is the one NOT_FOUND "list not found", and the caller's own
  /// list => VALIDATION "target_id". The evidence is the owner's handle, the list's name and description and its creation
  /// time (no member id), kept in the report document with the post evidence's retention. Needs FEATURE_LISTS not globally
  /// off; the existing reports quota applies.
  static const ReportTargetType REPORT_TARGET_TYPE_LIST =
      ReportTargetType._(4, _omitEnumNames ? '' : 'REPORT_TARGET_TYPE_LIST');

  /// A community. target_id = the community id (19 digits, else VALIDATION "target_id"). A missing or
  /// SUSPENDED community is the one NOT_FOUND "community not found"; an ARCHIVED one is reportable; the caller's own
  /// community (the caller is its owner) => VALIDATION "target_id". A block with the owner does not refuse it (the
  /// community is public). The evidence is the owner's handle (empty for an ownerless ARCHIVED community), the
  /// community's name, description and rules and its creation time (no member id, no child doc), kept in the report
  /// document with the post evidence's retention. Reports of posts in a community use REPORT_TARGET_TYPE_POST; they go to
  /// the platform only, never to the community's moderators. Needs FEATURE_COMMUNITIES not globally off (else
  /// FAILED_PRECONDITION + FEATURE_DISABLED, metadata["feature"] = "communities", before any lookup); the existing reports quota
  /// applies.
  static const ReportTargetType REPORT_TARGET_TYPE_COMMUNITY =
      ReportTargetType._(
          5, _omitEnumNames ? '' : 'REPORT_TARGET_TYPE_COMMUNITY');

  /// A beacon (plan). target_id = the beacon id (19 digits, else VALIDATION "target_id"). Who may see the beacon may
  /// report it: a missing or hidden beacon, one whose organiser is gone, one in a community the caller is not a JOINED
  /// member of, and one whose organiser has a block with the caller are all the one NOT_FOUND "beacon not found" (a
  /// CANCELLED or ENDED beacon is still reportable); the caller's own beacon (the caller is its organiser) => VALIDATION "target_id". The
  /// evidence is the organiser's handle, the beacon's title, details and venue and its creation time (no participant id,
  /// no child doc), kept in the report document with the post evidence's retention. Needs FEATURE_BEACONS not globally off
  /// (else FAILED_PRECONDITION + FEATURE_DISABLED, metadata["feature"] = "beacons", before any lookup); the existing
  /// reports quota applies. Takedown is `opsctl beacon hide` (resolves the report TAKEDOWN).
  static const ReportTargetType REPORT_TARGET_TYPE_BEACON =
      ReportTargetType._(6, _omitEnumNames ? '' : 'REPORT_TARGET_TYPE_BEACON');

  static const $core.List<ReportTargetType> values = <ReportTargetType>[
    REPORT_TARGET_TYPE_UNSPECIFIED,
    REPORT_TARGET_TYPE_POST,
    REPORT_TARGET_TYPE_ACCOUNT,
    REPORT_TARGET_TYPE_MESSAGE,
    REPORT_TARGET_TYPE_LIST,
    REPORT_TARGET_TYPE_COMMUNITY,
    REPORT_TARGET_TYPE_BEACON,
  ];

  static final $core.List<ReportTargetType?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 6);
  static ReportTargetType? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const ReportTargetType._(super.value, super.name);
}

/// Reasons shown in the client sheet. Values are never renumbered or reused (buf breaking).
class ReportReason extends $pb.ProtobufEnum {
  static const ReportReason REPORT_REASON_UNSPECIFIED =
      ReportReason._(0, _omitEnumNames ? '' : 'REPORT_REASON_UNSPECIFIED');
  static const ReportReason REPORT_REASON_SPAM =
      ReportReason._(1, _omitEnumNames ? '' : 'REPORT_REASON_SPAM');
  static const ReportReason REPORT_REASON_HARASSMENT =
      ReportReason._(2, _omitEnumNames ? '' : 'REPORT_REASON_HARASSMENT');
  static const ReportReason REPORT_REASON_HATE =
      ReportReason._(3, _omitEnumNames ? '' : 'REPORT_REASON_HATE');
  static const ReportReason REPORT_REASON_VIOLENCE =
      ReportReason._(4, _omitEnumNames ? '' : 'REPORT_REASON_VIOLENCE');
  static const ReportReason REPORT_REASON_SEXUAL =
      ReportReason._(5, _omitEnumNames ? '' : 'REPORT_REASON_SEXUAL');
  static const ReportReason REPORT_REASON_SELF_HARM =
      ReportReason._(6, _omitEnumNames ? '' : 'REPORT_REASON_SELF_HARM');
  static const ReportReason REPORT_REASON_ILLEGAL =
      ReportReason._(7, _omitEnumNames ? '' : 'REPORT_REASON_ILLEGAL');
  static const ReportReason REPORT_REASON_IMPERSONATION =
      ReportReason._(8, _omitEnumNames ? '' : 'REPORT_REASON_IMPERSONATION');
  static const ReportReason REPORT_REASON_OTHER =
      ReportReason._(9, _omitEnumNames ? '' : 'REPORT_REASON_OTHER');

  static const $core.List<ReportReason> values = <ReportReason>[
    REPORT_REASON_UNSPECIFIED,
    REPORT_REASON_SPAM,
    REPORT_REASON_HARASSMENT,
    REPORT_REASON_HATE,
    REPORT_REASON_VIOLENCE,
    REPORT_REASON_SEXUAL,
    REPORT_REASON_SELF_HARM,
    REPORT_REASON_ILLEGAL,
    REPORT_REASON_IMPERSONATION,
    REPORT_REASON_OTHER,
  ];

  static final $core.List<ReportReason?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 9);
  static ReportReason? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const ReportReason._(super.value, super.name);
}

const $core.bool _omitEnumNames =
    $core.bool.fromEnvironment('protobuf.omit_enum_names');
