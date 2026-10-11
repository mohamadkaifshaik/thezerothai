// This is a generated file - do not edit.
//
// Generated from dzeroth/notifications/v1/notifications.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

class NotificationType extends $pb.ProtobufEnum {
  static const NotificationType NOTIFICATION_TYPE_UNSPECIFIED =
      NotificationType._(
          0, _omitEnumNames ? '' : 'NOTIFICATION_TYPE_UNSPECIFIED');

  /// actor started following you.
  static const NotificationType NOTIFICATION_TYPE_FOLLOW =
      NotificationType._(1, _omitEnumNames ? '' : 'NOTIFICATION_TYPE_FOLLOW');

  /// actor mentioned you in post_id.
  static const NotificationType NOTIFICATION_TYPE_MENTION =
      NotificationType._(2, _omitEnumNames ? '' : 'NOTIFICATION_TYPE_MENTION');

  /// actor replied to your post; post_id is the reply.
  static const NotificationType NOTIFICATION_TYPE_REPLY =
      NotificationType._(3, _omitEnumNames ? '' : 'NOTIFICATION_TYPE_REPLY');

  /// actor(s) liked your post_id. Collapsed per post per hour: one row, actor_count grows.
  static const NotificationType NOTIFICATION_TYPE_LIKE =
      NotificationType._(4, _omitEnumNames ? '' : 'NOTIFICATION_TYPE_LIKE');

  /// actor reposted your post_id.
  static const NotificationType NOTIFICATION_TYPE_REPOST =
      NotificationType._(5, _omitEnumNames ? '' : 'NOTIFICATION_TYPE_REPOST');

  /// actor quoted your post; post_id is the quote post.
  static const NotificationType NOTIFICATION_TYPE_QUOTE =
      NotificationType._(6, _omitEnumNames ? '' : 'NOTIFICATION_TYPE_QUOTE');

  static const $core.List<NotificationType> values = <NotificationType>[
    NOTIFICATION_TYPE_UNSPECIFIED,
    NOTIFICATION_TYPE_FOLLOW,
    NOTIFICATION_TYPE_MENTION,
    NOTIFICATION_TYPE_REPLY,
    NOTIFICATION_TYPE_LIKE,
    NOTIFICATION_TYPE_REPOST,
    NOTIFICATION_TYPE_QUOTE,
  ];

  static final $core.List<NotificationType?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 6);
  static NotificationType? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const NotificationType._(super.value, super.name);
}

class DevicePlatform extends $pb.ProtobufEnum {
  static const DevicePlatform DEVICE_PLATFORM_UNSPECIFIED =
      DevicePlatform._(0, _omitEnumNames ? '' : 'DEVICE_PLATFORM_UNSPECIFIED');
  static const DevicePlatform DEVICE_PLATFORM_IOS =
      DevicePlatform._(1, _omitEnumNames ? '' : 'DEVICE_PLATFORM_IOS');
  static const DevicePlatform DEVICE_PLATFORM_ANDROID =
      DevicePlatform._(2, _omitEnumNames ? '' : 'DEVICE_PLATFORM_ANDROID');

  static const $core.List<DevicePlatform> values = <DevicePlatform>[
    DEVICE_PLATFORM_UNSPECIFIED,
    DEVICE_PLATFORM_IOS,
    DEVICE_PLATFORM_ANDROID,
  ];

  static final $core.List<DevicePlatform?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 2);
  static DevicePlatform? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const DevicePlatform._(super.value, super.name);
}

const $core.bool _omitEnumNames =
    $core.bool.fromEnvironment('protobuf.omit_enum_names');
