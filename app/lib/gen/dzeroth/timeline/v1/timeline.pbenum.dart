// This is a generated file - do not edit.
//
// Generated from dzeroth/timeline/v1/timeline.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

/// The profile tab a GetUserTimeline call reads (ADR-0024 D5).
class UserTimelineTab extends $pb.ProtobufEnum {
  /// Use include_replies (false = POSTS, true = REPLIES), exactly as before the tab field existed.
  static const UserTimelineTab USER_TIMELINE_TAB_UNSPECIFIED =
      UserTimelineTab._(
          0, _omitEnumNames ? '' : 'USER_TIMELINE_TAB_UNSPECIFIED');

  /// Root posts (isReply == false).
  static const UserTimelineTab USER_TIMELINE_TAB_POSTS =
      UserTimelineTab._(1, _omitEnumNames ? '' : 'USER_TIMELINE_TAB_POSTS');

  /// All of the author's posts, replies included.
  static const UserTimelineTab USER_TIMELINE_TAB_REPLIES =
      UserTimelineTab._(2, _omitEnumNames ? '' : 'USER_TIMELINE_TAB_REPLIES');

  /// The author's posts with their own images (hasMedia == true), replies and quotes included, REPOSTs excluded.
  /// Needs FEATURE_PROFILE_TABS.
  static const UserTimelineTab USER_TIMELINE_TAB_MEDIA =
      UserTimelineTab._(3, _omitEnumNames ? '' : 'USER_TIMELINE_TAB_MEDIA');

  /// The author's REPOST items (kind == REPOST). Needs FEATURE_PROFILE_TABS.
  static const UserTimelineTab USER_TIMELINE_TAB_REPOSTS =
      UserTimelineTab._(4, _omitEnumNames ? '' : 'USER_TIMELINE_TAB_REPOSTS');

  static const $core.List<UserTimelineTab> values = <UserTimelineTab>[
    USER_TIMELINE_TAB_UNSPECIFIED,
    USER_TIMELINE_TAB_POSTS,
    USER_TIMELINE_TAB_REPLIES,
    USER_TIMELINE_TAB_MEDIA,
    USER_TIMELINE_TAB_REPOSTS,
  ];

  static final $core.List<UserTimelineTab?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 4);
  static UserTimelineTab? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const UserTimelineTab._(super.value, super.name);
}

const $core.bool _omitEnumNames =
    $core.bool.fromEnvironment('protobuf.omit_enum_names');
