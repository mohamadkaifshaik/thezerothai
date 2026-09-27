// This is a generated file - do not edit.
//
// Generated from dzeroth/media/v1/media.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

class MediaPurpose extends $pb.ProtobufEnum {
  static const MediaPurpose MEDIA_PURPOSE_UNSPECIFIED =
      MediaPurpose._(0, _omitEnumNames ? '' : 'MEDIA_PURPOSE_UNSPECIFIED');

  /// Attach to a post (max 4).
  static const MediaPurpose MEDIA_PURPOSE_POST =
      MediaPurpose._(1, _omitEnumNames ? '' : 'MEDIA_PURPOSE_POST');

  /// Profile avatar (exactly 1; full 400 px, thumb 96 px).
  static const MediaPurpose MEDIA_PURPOSE_AVATAR =
      MediaPurpose._(2, _omitEnumNames ? '' : 'MEDIA_PURPOSE_AVATAR');

  static const $core.List<MediaPurpose> values = <MediaPurpose>[
    MEDIA_PURPOSE_UNSPECIFIED,
    MEDIA_PURPOSE_POST,
    MEDIA_PURPOSE_AVATAR,
  ];

  static final $core.List<MediaPurpose?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 2);
  static MediaPurpose? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const MediaPurpose._(super.value, super.name);
}

class MediaStatus extends $pb.ProtobufEnum {
  static const MediaStatus MEDIA_STATUS_UNSPECIFIED =
      MediaStatus._(0, _omitEnumNames ? '' : 'MEDIA_STATUS_UNSPECIFIED');

  /// Reserved, waiting for upload + FinalizeUpload.
  static const MediaStatus MEDIA_STATUS_PENDING =
      MediaStatus._(1, _omitEnumNames ? '' : 'MEDIA_STATUS_PENDING');

  /// Passed SafeSearch; public.
  static const MediaStatus MEDIA_STATUS_READY =
      MediaStatus._(2, _omitEnumNames ? '' : 'MEDIA_STATUS_READY');

  /// Monthly SafeSearch quota exhausted; published and queued for report-driven review.
  static const MediaStatus MEDIA_STATUS_READY_UNSCREENED =
      MediaStatus._(3, _omitEnumNames ? '' : 'MEDIA_STATUS_READY_UNSCREENED');

  /// Failed validation or moderation; objects deleted.
  static const MediaStatus MEDIA_STATUS_REJECTED =
      MediaStatus._(4, _omitEnumNames ? '' : 'MEDIA_STATUS_REJECTED');

  static const $core.List<MediaStatus> values = <MediaStatus>[
    MEDIA_STATUS_UNSPECIFIED,
    MEDIA_STATUS_PENDING,
    MEDIA_STATUS_READY,
    MEDIA_STATUS_READY_UNSCREENED,
    MEDIA_STATUS_REJECTED,
  ];

  static final $core.List<MediaStatus?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 4);
  static MediaStatus? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const MediaStatus._(super.value, super.name);
}

const $core.bool _omitEnumNames =
    $core.bool.fromEnvironment('protobuf.omit_enum_names');
