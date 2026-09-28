// This is a generated file - do not edit.
//
// Generated from dzeroth/graph/v1/graph.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

class FollowState extends $pb.ProtobufEnum {
  static const FollowState FOLLOW_STATE_UNSPECIFIED =
      FollowState._(0, _omitEnumNames ? '' : 'FOLLOW_STATE_UNSPECIFIED');
  static const FollowState FOLLOW_STATE_NONE =
      FollowState._(1, _omitEnumNames ? '' : 'FOLLOW_STATE_NONE');
  static const FollowState FOLLOW_STATE_FOLLOWING =
      FollowState._(2, _omitEnumNames ? '' : 'FOLLOW_STATE_FOLLOWING');

  /// Pending approval by a private account. Unreachable until private accounts ship (ADR-0008 D1).
  static const FollowState FOLLOW_STATE_REQUESTED =
      FollowState._(3, _omitEnumNames ? '' : 'FOLLOW_STATE_REQUESTED');

  static const $core.List<FollowState> values = <FollowState>[
    FOLLOW_STATE_UNSPECIFIED,
    FOLLOW_STATE_NONE,
    FOLLOW_STATE_FOLLOWING,
    FOLLOW_STATE_REQUESTED,
  ];

  static final $core.List<FollowState?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 3);
  static FollowState? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const FollowState._(super.value, super.name);
}

const $core.bool _omitEnumNames =
    $core.bool.fromEnvironment('protobuf.omit_enum_names');
