// This is a generated file - do not edit.
//
// Generated from dzeroth/engagement/v1/engagement.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

/// Where an outside share went, as the client saw it. Logged for aggregate metrics only, never stored. Additive.
class ShareChannel extends $pb.ProtobufEnum {
  static const ShareChannel SHARE_CHANNEL_UNSPECIFIED =
      ShareChannel._(0, _omitEnumNames ? '' : 'SHARE_CHANNEL_UNSPECIFIED');

  /// "Copy link" wrote the post URL to the clipboard.
  static const ShareChannel SHARE_CHANNEL_COPY_LINK =
      ShareChannel._(1, _omitEnumNames ? '' : 'SHARE_CHANNEL_COPY_LINK');

  /// The platform share sheet reported a completed share.
  static const ShareChannel SHARE_CHANNEL_SHARE_SHEET =
      ShareChannel._(2, _omitEnumNames ? '' : 'SHARE_CHANNEL_SHARE_SHEET');

  static const $core.List<ShareChannel> values = <ShareChannel>[
    SHARE_CHANNEL_UNSPECIFIED,
    SHARE_CHANNEL_COPY_LINK,
    SHARE_CHANNEL_SHARE_SHEET,
  ];

  static final $core.List<ShareChannel?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 2);
  static ShareChannel? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const ShareChannel._(super.value, super.name);
}

const $core.bool _omitEnumNames =
    $core.bool.fromEnvironment('protobuf.omit_enum_names');
