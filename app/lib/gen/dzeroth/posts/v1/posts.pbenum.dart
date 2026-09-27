// This is a generated file - do not edit.
//
// Generated from dzeroth/posts/v1/posts.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

class PostKind extends $pb.ProtobufEnum {
  static const PostKind POST_KIND_UNSPECIFIED =
      PostKind._(0, _omitEnumNames ? '' : 'POST_KIND_UNSPECIFIED');
  static const PostKind POST_KIND_POST =
      PostKind._(1, _omitEnumNames ? '' : 'POST_KIND_POST');
  static const PostKind POST_KIND_REPLY =
      PostKind._(2, _omitEnumNames ? '' : 'POST_KIND_REPLY');
  static const PostKind POST_KIND_QUOTE =
      PostKind._(3, _omitEnumNames ? '' : 'POST_KIND_QUOTE');

  /// Created by the engagement module (future RPC); stored as a post doc so pull timelines include it.
  static const PostKind POST_KIND_REPOST =
      PostKind._(4, _omitEnumNames ? '' : 'POST_KIND_REPOST');

  static const $core.List<PostKind> values = <PostKind>[
    POST_KIND_UNSPECIFIED,
    POST_KIND_POST,
    POST_KIND_REPLY,
    POST_KIND_QUOTE,
    POST_KIND_REPOST,
  ];

  static final $core.List<PostKind?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 4);
  static PostKind? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const PostKind._(super.value, super.name);
}

class Visibility extends $pb.ProtobufEnum {
  static const Visibility VISIBILITY_UNSPECIFIED =
      Visibility._(0, _omitEnumNames ? '' : 'VISIBILITY_UNSPECIFIED');
  static const Visibility VISIBILITY_PUBLIC =
      Visibility._(1, _omitEnumNames ? '' : 'VISIBILITY_PUBLIC');

  /// Author is a private account: only approved followers and the author.
  static const Visibility VISIBILITY_FOLLOWERS =
      Visibility._(2, _omitEnumNames ? '' : 'VISIBILITY_FOLLOWERS');

  static const $core.List<Visibility> values = <Visibility>[
    VISIBILITY_UNSPECIFIED,
    VISIBILITY_PUBLIC,
    VISIBILITY_FOLLOWERS,
  ];

  static final $core.List<Visibility?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 2);
  static Visibility? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const Visibility._(super.value, super.name);
}

const $core.bool _omitEnumNames =
    $core.bool.fromEnvironment('protobuf.omit_enum_names');
