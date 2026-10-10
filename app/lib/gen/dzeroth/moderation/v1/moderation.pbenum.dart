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

  static const $core.List<ReportTargetType> values = <ReportTargetType>[
    REPORT_TARGET_TYPE_UNSPECIFIED,
    REPORT_TARGET_TYPE_POST,
    REPORT_TARGET_TYPE_ACCOUNT,
  ];

  static final $core.List<ReportTargetType?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 2);
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
