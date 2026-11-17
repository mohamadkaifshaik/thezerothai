// This is a generated file - do not edit.
//
// Generated from dzeroth/common/v1/options.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

/// How the edge treats a field that names a user. Values are never renumbered or reused.
class UserRefKind extends $pb.ProtobufEnum {
  /// Not a valid annotation: the guard test rejects a field annotated with it.
  static const UserRefKind USER_REF_KIND_UNSPECIFIED =
      UserRefKind._(0, _omitEnumNames ? '' : 'USER_REF_KIND_UNSPECIFIED');

  /// The field holds a user id (string, repeated string). On the wire it is the user's public id once FEATURE_PUBLIC_IDS
  /// is on; the edge translates it in both directions. "" stays "" (several requests read "" as "the caller").
  static const UserRefKind USER_REF_KIND_TRANSLATE =
      UserRefKind._(1, _omitEnumNames ? '' : 'USER_REF_KIND_TRANSLATE');

  /// The field holds a user id only for some values of a sibling field (e.g. moderation.v1.ReportContentRequest.target_id
  /// when target_type is ACCOUNT), or an id that embeds a user id (e.g. notifications.v1.Notification.id, whose last "_"
  /// segment names the actor for some types). The edge needs a per-field rule for it, which says whether and where the
  /// value holds a user id; the generic walker never touches it otherwise.
  static const UserRefKind USER_REF_KIND_CONDITIONAL =
      UserRefKind._(2, _omitEnumNames ? '' : 'USER_REF_KIND_CONDITIONAL');

  /// The field already holds a public id (e.g. Profile.public_id). Never translated.
  static const UserRefKind USER_REF_KIND_PUBLIC_ID =
      UserRefKind._(3, _omitEnumNames ? '' : 'USER_REF_KIND_PUBLIC_ID');

  /// The field's name looks like a user id but it is not one (e.g. billing.v1's private billing customer id). Never
  /// translated. Present so the guard test can tell "reviewed, not a user id" from "forgotten".
  static const UserRefKind USER_REF_KIND_NOT_USER =
      UserRefKind._(4, _omitEnumNames ? '' : 'USER_REF_KIND_NOT_USER');

  static const $core.List<UserRefKind> values = <UserRefKind>[
    USER_REF_KIND_UNSPECIFIED,
    USER_REF_KIND_TRANSLATE,
    USER_REF_KIND_CONDITIONAL,
    USER_REF_KIND_PUBLIC_ID,
    USER_REF_KIND_NOT_USER,
  ];

  static final $core.List<UserRefKind?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 4);
  static UserRefKind? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const UserRefKind._(super.value, super.name);
}

const $core.bool _omitEnumNames =
    $core.bool.fromEnvironment('protobuf.omit_enum_names');
