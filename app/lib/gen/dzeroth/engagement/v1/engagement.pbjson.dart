// This is a generated file - do not edit.
//
// Generated from dzeroth/engagement/v1/engagement.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports
// ignore_for_file: unused_import

import 'dart:convert' as $convert;
import 'dart:core' as $core;
import 'dart:typed_data' as $typed_data;

@$core.Deprecated('Use postEngagementDescriptor instead')
const PostEngagement$json = {
  '1': 'PostEngagement',
  '2': [
    {'1': 'post_id', '3': 1, '4': 1, '5': 9, '10': 'postId'},
    {'1': 'like_count', '3': 2, '4': 1, '5': 3, '10': 'likeCount'},
    {'1': 'repost_count', '3': 3, '4': 1, '5': 3, '10': 'repostCount'},
    {'1': 'liked_by_viewer', '3': 4, '4': 1, '5': 8, '10': 'likedByViewer'},
    {
      '1': 'reposted_by_viewer',
      '3': 5,
      '4': 1,
      '5': 8,
      '10': 'repostedByViewer'
    },
  ],
};

/// Descriptor for `PostEngagement`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List postEngagementDescriptor = $convert.base64Decode(
    'Cg5Qb3N0RW5nYWdlbWVudBIXCgdwb3N0X2lkGAEgASgJUgZwb3N0SWQSHQoKbGlrZV9jb3VudB'
    'gCIAEoA1IJbGlrZUNvdW50EiEKDHJlcG9zdF9jb3VudBgDIAEoA1ILcmVwb3N0Q291bnQSJgoP'
    'bGlrZWRfYnlfdmlld2VyGAQgASgIUg1saWtlZEJ5Vmlld2VyEiwKEnJlcG9zdGVkX2J5X3ZpZX'
    'dlchgFIAEoCFIQcmVwb3N0ZWRCeVZpZXdlcg==');

@$core.Deprecated('Use likePostRequestDescriptor instead')
const LikePostRequest$json = {
  '1': 'LikePostRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'post_id', '3': 2, '4': 1, '5': 9, '10': 'postId'},
  ],
};

/// Descriptor for `LikePostRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List likePostRequestDescriptor = $convert.base64Decode(
    'Cg9MaWtlUG9zdFJlcXVlc3QSJwoPaWRlbXBvdGVuY3lfa2V5GAEgASgJUg5pZGVtcG90ZW5jeU'
    'tleRIXCgdwb3N0X2lkGAIgASgJUgZwb3N0SWQ=');

@$core.Deprecated('Use likePostResponseDescriptor instead')
const LikePostResponse$json = {
  '1': 'LikePostResponse',
  '2': [
    {
      '1': 'engagement',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.engagement.v1.PostEngagement',
      '10': 'engagement'
    },
  ],
};

/// Descriptor for `LikePostResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List likePostResponseDescriptor = $convert.base64Decode(
    'ChBMaWtlUG9zdFJlc3BvbnNlEkUKCmVuZ2FnZW1lbnQYASABKAsyJS5kemVyb3RoLmVuZ2FnZW'
    '1lbnQudjEuUG9zdEVuZ2FnZW1lbnRSCmVuZ2FnZW1lbnQ=');

@$core.Deprecated('Use unlikePostRequestDescriptor instead')
const UnlikePostRequest$json = {
  '1': 'UnlikePostRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'post_id', '3': 2, '4': 1, '5': 9, '10': 'postId'},
  ],
};

/// Descriptor for `UnlikePostRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List unlikePostRequestDescriptor = $convert.base64Decode(
    'ChFVbmxpa2VQb3N0UmVxdWVzdBInCg9pZGVtcG90ZW5jeV9rZXkYASABKAlSDmlkZW1wb3Rlbm'
    'N5S2V5EhcKB3Bvc3RfaWQYAiABKAlSBnBvc3RJZA==');

@$core.Deprecated('Use unlikePostResponseDescriptor instead')
const UnlikePostResponse$json = {
  '1': 'UnlikePostResponse',
  '2': [
    {
      '1': 'engagement',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.engagement.v1.PostEngagement',
      '10': 'engagement'
    },
  ],
};

/// Descriptor for `UnlikePostResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List unlikePostResponseDescriptor = $convert.base64Decode(
    'ChJVbmxpa2VQb3N0UmVzcG9uc2USRQoKZW5nYWdlbWVudBgBIAEoCzIlLmR6ZXJvdGguZW5nYW'
    'dlbWVudC52MS5Qb3N0RW5nYWdlbWVudFIKZW5nYWdlbWVudA==');

@$core.Deprecated('Use repostPostRequestDescriptor instead')
const RepostPostRequest$json = {
  '1': 'RepostPostRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'post_id', '3': 2, '4': 1, '5': 9, '10': 'postId'},
  ],
};

/// Descriptor for `RepostPostRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List repostPostRequestDescriptor = $convert.base64Decode(
    'ChFSZXBvc3RQb3N0UmVxdWVzdBInCg9pZGVtcG90ZW5jeV9rZXkYASABKAlSDmlkZW1wb3Rlbm'
    'N5S2V5EhcKB3Bvc3RfaWQYAiABKAlSBnBvc3RJZA==');

@$core.Deprecated('Use repostPostResponseDescriptor instead')
const RepostPostResponse$json = {
  '1': 'RepostPostResponse',
  '2': [
    {
      '1': 'engagement',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.engagement.v1.PostEngagement',
      '10': 'engagement'
    },
    {'1': 'repost_post_id', '3': 2, '4': 1, '5': 9, '10': 'repostPostId'},
  ],
};

/// Descriptor for `RepostPostResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List repostPostResponseDescriptor = $convert.base64Decode(
    'ChJSZXBvc3RQb3N0UmVzcG9uc2USRQoKZW5nYWdlbWVudBgBIAEoCzIlLmR6ZXJvdGguZW5nYW'
    'dlbWVudC52MS5Qb3N0RW5nYWdlbWVudFIKZW5nYWdlbWVudBIkCg5yZXBvc3RfcG9zdF9pZBgC'
    'IAEoCVIMcmVwb3N0UG9zdElk');

@$core.Deprecated('Use undoRepostRequestDescriptor instead')
const UndoRepostRequest$json = {
  '1': 'UndoRepostRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'post_id', '3': 2, '4': 1, '5': 9, '10': 'postId'},
  ],
};

/// Descriptor for `UndoRepostRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List undoRepostRequestDescriptor = $convert.base64Decode(
    'ChFVbmRvUmVwb3N0UmVxdWVzdBInCg9pZGVtcG90ZW5jeV9rZXkYASABKAlSDmlkZW1wb3Rlbm'
    'N5S2V5EhcKB3Bvc3RfaWQYAiABKAlSBnBvc3RJZA==');

@$core.Deprecated('Use undoRepostResponseDescriptor instead')
const UndoRepostResponse$json = {
  '1': 'UndoRepostResponse',
  '2': [
    {
      '1': 'engagement',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.engagement.v1.PostEngagement',
      '10': 'engagement'
    },
  ],
};

/// Descriptor for `UndoRepostResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List undoRepostResponseDescriptor = $convert.base64Decode(
    'ChJVbmRvUmVwb3N0UmVzcG9uc2USRQoKZW5nYWdlbWVudBgBIAEoCzIlLmR6ZXJvdGguZW5nYW'
    'dlbWVudC52MS5Qb3N0RW5nYWdlbWVudFIKZW5nYWdlbWVudA==');

const $core.Map<$core.String, $core.dynamic> EngagementServiceBase$json = {
  '1': 'EngagementService',
  '2': [
    {
      '1': 'LikePost',
      '2': '.dzeroth.engagement.v1.LikePostRequest',
      '3': '.dzeroth.engagement.v1.LikePostResponse'
    },
    {
      '1': 'UnlikePost',
      '2': '.dzeroth.engagement.v1.UnlikePostRequest',
      '3': '.dzeroth.engagement.v1.UnlikePostResponse'
    },
    {
      '1': 'RepostPost',
      '2': '.dzeroth.engagement.v1.RepostPostRequest',
      '3': '.dzeroth.engagement.v1.RepostPostResponse'
    },
    {
      '1': 'UndoRepost',
      '2': '.dzeroth.engagement.v1.UndoRepostRequest',
      '3': '.dzeroth.engagement.v1.UndoRepostResponse'
    },
  ],
};

@$core.Deprecated('Use engagementServiceDescriptor instead')
const $core.Map<$core.String, $core.Map<$core.String, $core.dynamic>>
    EngagementServiceBase$messageJson = {
  '.dzeroth.engagement.v1.LikePostRequest': LikePostRequest$json,
  '.dzeroth.engagement.v1.LikePostResponse': LikePostResponse$json,
  '.dzeroth.engagement.v1.PostEngagement': PostEngagement$json,
  '.dzeroth.engagement.v1.UnlikePostRequest': UnlikePostRequest$json,
  '.dzeroth.engagement.v1.UnlikePostResponse': UnlikePostResponse$json,
  '.dzeroth.engagement.v1.RepostPostRequest': RepostPostRequest$json,
  '.dzeroth.engagement.v1.RepostPostResponse': RepostPostResponse$json,
  '.dzeroth.engagement.v1.UndoRepostRequest': UndoRepostRequest$json,
  '.dzeroth.engagement.v1.UndoRepostResponse': UndoRepostResponse$json,
};

/// Descriptor for `EngagementService`. Decode as a `google.protobuf.ServiceDescriptorProto`.
final $typed_data.Uint8List engagementServiceDescriptor = $convert.base64Decode(
    'ChFFbmdhZ2VtZW50U2VydmljZRJbCghMaWtlUG9zdBImLmR6ZXJvdGguZW5nYWdlbWVudC52MS'
    '5MaWtlUG9zdFJlcXVlc3QaJy5kemVyb3RoLmVuZ2FnZW1lbnQudjEuTGlrZVBvc3RSZXNwb25z'
    'ZRJhCgpVbmxpa2VQb3N0EiguZHplcm90aC5lbmdhZ2VtZW50LnYxLlVubGlrZVBvc3RSZXF1ZX'
    'N0GikuZHplcm90aC5lbmdhZ2VtZW50LnYxLlVubGlrZVBvc3RSZXNwb25zZRJhCgpSZXBvc3RQ'
    'b3N0EiguZHplcm90aC5lbmdhZ2VtZW50LnYxLlJlcG9zdFBvc3RSZXF1ZXN0GikuZHplcm90aC'
    '5lbmdhZ2VtZW50LnYxLlJlcG9zdFBvc3RSZXNwb25zZRJhCgpVbmRvUmVwb3N0EiguZHplcm90'
    'aC5lbmdhZ2VtZW50LnYxLlVuZG9SZXBvc3RSZXF1ZXN0GikuZHplcm90aC5lbmdhZ2VtZW50Ln'
    'YxLlVuZG9SZXBvc3RSZXNwb25zZQ==');
