// This is a generated file - do not edit.
//
// Generated from dzeroth/identity/v1/identity.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

class AccountStatus extends $pb.ProtobufEnum {
  static const AccountStatus ACCOUNT_STATUS_UNSPECIFIED =
      AccountStatus._(0, _omitEnumNames ? '' : 'ACCOUNT_STATUS_UNSPECIFIED');
  static const AccountStatus ACCOUNT_STATUS_ACTIVE =
      AccountStatus._(1, _omitEnumNames ? '' : 'ACCOUNT_STATUS_ACTIVE');
  static const AccountStatus ACCOUNT_STATUS_SUSPENDED =
      AccountStatus._(2, _omitEnumNames ? '' : 'ACCOUNT_STATUS_SUSPENDED');
  static const AccountStatus ACCOUNT_STATUS_DELETING =
      AccountStatus._(3, _omitEnumNames ? '' : 'ACCOUNT_STATUS_DELETING');

  static const $core.List<AccountStatus> values = <AccountStatus>[
    ACCOUNT_STATUS_UNSPECIFIED,
    ACCOUNT_STATUS_ACTIVE,
    ACCOUNT_STATUS_SUSPENDED,
    ACCOUNT_STATUS_DELETING,
  ];

  static final $core.List<AccountStatus?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 3);
  static AccountStatus? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const AccountStatus._(super.value, super.name);
}

/// Who may start a direct message with an account. Existing accepted conversations always keep working.
class DmPolicy extends $pb.ProtobufEnum {
  /// Same as EVERYONE_REQUESTS. Every account created before the setting existed has it.
  static const DmPolicy DM_POLICY_UNSPECIFIED =
      DmPolicy._(0, _omitEnumNames ? '' : 'DM_POLICY_UNSPECIFIED');

  /// Anyone can message; a sender the account does not follow arrives as a message request (messaging.proto).
  static const DmPolicy DM_POLICY_EVERYONE_REQUESTS =
      DmPolicy._(1, _omitEnumNames ? '' : 'DM_POLICY_EVERYONE_REQUESTS');

  /// Only accounts that this account follows can start a conversation or add to a pending request.
  static const DmPolicy DM_POLICY_FOLLOWING_ONLY =
      DmPolicy._(2, _omitEnumNames ? '' : 'DM_POLICY_FOLLOWING_ONLY');

  static const $core.List<DmPolicy> values = <DmPolicy>[
    DM_POLICY_UNSPECIFIED,
    DM_POLICY_EVERYONE_REQUESTS,
    DM_POLICY_FOLLOWING_ONLY,
  ];

  static final $core.List<DmPolicy?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 2);
  static DmPolicy? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const DmPolicy._(super.value, super.name);
}

class ExportStatus extends $pb.ProtobufEnum {
  static const ExportStatus EXPORT_STATUS_UNSPECIFIED =
      ExportStatus._(0, _omitEnumNames ? '' : 'EXPORT_STATUS_UNSPECIFIED');
  static const ExportStatus EXPORT_STATUS_PENDING =
      ExportStatus._(1, _omitEnumNames ? '' : 'EXPORT_STATUS_PENDING');
  static const ExportStatus EXPORT_STATUS_READY =
      ExportStatus._(2, _omitEnumNames ? '' : 'EXPORT_STATUS_READY');
  static const ExportStatus EXPORT_STATUS_FAILED =
      ExportStatus._(3, _omitEnumNames ? '' : 'EXPORT_STATUS_FAILED');

  static const $core.List<ExportStatus> values = <ExportStatus>[
    EXPORT_STATUS_UNSPECIFIED,
    EXPORT_STATUS_PENDING,
    EXPORT_STATUS_READY,
    EXPORT_STATUS_FAILED,
  ];

  static final $core.List<ExportStatus?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 3);
  static ExportStatus? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const ExportStatus._(super.value, super.name);
}

const $core.bool _omitEnumNames =
    $core.bool.fromEnvironment('protobuf.omit_enum_names');
