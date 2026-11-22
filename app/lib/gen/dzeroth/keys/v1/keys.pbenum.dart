// This is a generated file - do not edit.
//
// Generated from dzeroth/keys/v1/keys.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

/// Why a device is removed. Decides whether the server remembers the id.
class RemoveReason extends $pb.ProtobufEnum {
  /// Builds before this field. Treated as SIGN_OUT.
  static const RemoveReason REMOVE_REASON_UNSPECIFIED =
      RemoveReason._(0, _omitEnumNames ? '' : 'REMOVE_REASON_UNSPECIFIED');

  /// The device removes itself as it signs out. No removed mark: the same id may register again (a failed sign-out
  /// registers it again).
  static const RemoveReason REMOVE_REASON_SIGN_OUT =
      RemoveReason._(1, _omitEnumNames ? '' : 'REMOVE_REASON_SIGN_OUT');

  /// The user removes another device of theirs (lost, stolen, sold). The server keeps a removed mark for at least 90
  /// days: RegisterKeyDevice and UploadKeyPackages refuse the id with FAILED_PRECONDITION + DEVICE_REMOVED. Needs a
  /// recent sign-in (FAILED_PRECONDITION + REAUTH_REQUIRED when the ID token's auth_time is older than
  /// ACCOUNT_DELETE_REAUTH_MAX_AGE, 5 min, or missing; nothing is written) unless the id is already marked: a retry
  /// finishes the removal without one. An id that was never registered is marked too (the answer does not tell whether
  /// the id existed).
  static const RemoveReason REMOVE_REASON_REMOTE =
      RemoveReason._(2, _omitEnumNames ? '' : 'REMOVE_REASON_REMOTE');

  static const $core.List<RemoveReason> values = <RemoveReason>[
    REMOVE_REASON_UNSPECIFIED,
    REMOVE_REASON_SIGN_OUT,
    REMOVE_REASON_REMOTE,
  ];

  static final $core.List<RemoveReason?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 2);
  static RemoveReason? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const RemoveReason._(super.value, super.name);
}

const $core.bool _omitEnumNames =
    $core.bool.fromEnvironment('protobuf.omit_enum_names');
