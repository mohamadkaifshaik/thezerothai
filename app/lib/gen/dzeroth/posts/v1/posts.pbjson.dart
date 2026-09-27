// This is a generated file - do not edit.
//
// Generated from dzeroth/posts/v1/posts.proto.

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

import 'package:protobuf/well_known_types/google/protobuf/timestamp.pbjson.dart'
    as $1;

import '../../common/v1/common.pbjson.dart' as $0;

@$core.Deprecated('Use postKindDescriptor instead')
const PostKind$json = {
  '1': 'PostKind',
  '2': [
    {'1': 'POST_KIND_UNSPECIFIED', '2': 0},
    {'1': 'POST_KIND_POST', '2': 1},
    {'1': 'POST_KIND_REPLY', '2': 2},
    {'1': 'POST_KIND_QUOTE', '2': 3},
    {'1': 'POST_KIND_REPOST', '2': 4},
  ],
};

/// Descriptor for `PostKind`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List postKindDescriptor = $convert.base64Decode(
    'CghQb3N0S2luZBIZChVQT1NUX0tJTkRfVU5TUEVDSUZJRUQQABISCg5QT1NUX0tJTkRfUE9TVB'
    'ABEhMKD1BPU1RfS0lORF9SRVBMWRACEhMKD1BPU1RfS0lORF9RVU9URRADEhQKEFBPU1RfS0lO'
    'RF9SRVBPU1QQBA==');

@$core.Deprecated('Use visibilityDescriptor instead')
const Visibility$json = {
  '1': 'Visibility',
  '2': [
    {'1': 'VISIBILITY_UNSPECIFIED', '2': 0},
    {'1': 'VISIBILITY_PUBLIC', '2': 1},
    {'1': 'VISIBILITY_FOLLOWERS', '2': 2},
  ],
};

/// Descriptor for `Visibility`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List visibilityDescriptor = $convert.base64Decode(
    'CgpWaXNpYmlsaXR5EhoKFlZJU0lCSUxJVFlfVU5TUEVDSUZJRUQQABIVChFWSVNJQklMSVRZX1'
    'BVQkxJQxABEhgKFFZJU0lCSUxJVFlfRk9MTE9XRVJTEAI=');

@$core.Deprecated('Use mentionDescriptor instead')
const Mention$json = {
  '1': 'Mention',
  '2': [
    {'1': 'user_id', '3': 1, '4': 1, '5': 9, '10': 'userId'},
    {'1': 'handle', '3': 2, '4': 1, '5': 9, '10': 'handle'},
  ],
};

/// Descriptor for `Mention`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List mentionDescriptor = $convert.base64Decode(
    'CgdNZW50aW9uEhcKB3VzZXJfaWQYASABKAlSBnVzZXJJZBIWCgZoYW5kbGUYAiABKAlSBmhhbm'
    'RsZQ==');

@$core.Deprecated('Use embeddedPostDescriptor instead')
const EmbeddedPost$json = {
  '1': 'EmbeddedPost',
  '2': [
    {'1': 'post_id', '3': 1, '4': 1, '5': 9, '10': 'postId'},
    {
      '1': 'author',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.common.v1.AuthorSnapshot',
      '10': 'author'
    },
    {'1': 'text', '3': 3, '4': 1, '5': 9, '10': 'text'},
    {
      '1': 'media',
      '3': 4,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.common.v1.MediaRef',
      '10': 'media'
    },
    {
      '1': 'created_at',
      '3': 5,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '10': 'createdAt'
    },
    {'1': 'unavailable', '3': 6, '4': 1, '5': 8, '10': 'unavailable'},
  ],
};

/// Descriptor for `EmbeddedPost`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List embeddedPostDescriptor = $convert.base64Decode(
    'CgxFbWJlZGRlZFBvc3QSFwoHcG9zdF9pZBgBIAEoCVIGcG9zdElkEjkKBmF1dGhvchgCIAEoCz'
    'IhLmR6ZXJvdGguY29tbW9uLnYxLkF1dGhvclNuYXBzaG90UgZhdXRob3ISEgoEdGV4dBgDIAEo'
    'CVIEdGV4dBIxCgVtZWRpYRgEIAMoCzIbLmR6ZXJvdGguY29tbW9uLnYxLk1lZGlhUmVmUgVtZW'
    'RpYRI5CgpjcmVhdGVkX2F0GAUgASgLMhouZ29vZ2xlLnByb3RvYnVmLlRpbWVzdGFtcFIJY3Jl'
    'YXRlZEF0EiAKC3VuYXZhaWxhYmxlGAYgASgIUgt1bmF2YWlsYWJsZQ==');

@$core.Deprecated('Use postDescriptor instead')
const Post$json = {
  '1': 'Post',
  '2': [
    {'1': 'post_id', '3': 1, '4': 1, '5': 9, '10': 'postId'},
    {
      '1': 'author',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.common.v1.AuthorSnapshot',
      '10': 'author'
    },
    {
      '1': 'kind',
      '3': 3,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.posts.v1.PostKind',
      '10': 'kind'
    },
    {'1': 'text', '3': 4, '4': 1, '5': 9, '10': 'text'},
    {
      '1': 'media',
      '3': 5,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.common.v1.MediaRef',
      '10': 'media'
    },
    {'1': 'reply_to_post_id', '3': 6, '4': 1, '5': 9, '10': 'replyToPostId'},
    {'1': 'reply_to_handle', '3': 7, '4': 1, '5': 9, '10': 'replyToHandle'},
    {'1': 'conversation_id', '3': 8, '4': 1, '5': 9, '10': 'conversationId'},
    {
      '1': 'embedded',
      '3': 9,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.posts.v1.EmbeddedPost',
      '10': 'embedded'
    },
    {'1': 'hashtags', '3': 10, '4': 3, '5': 9, '10': 'hashtags'},
    {
      '1': 'mentions',
      '3': 11,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.posts.v1.Mention',
      '10': 'mentions'
    },
    {'1': 'like_count', '3': 12, '4': 1, '5': 3, '10': 'likeCount'},
    {'1': 'repost_count', '3': 13, '4': 1, '5': 3, '10': 'repostCount'},
    {'1': 'reply_count', '3': 14, '4': 1, '5': 3, '10': 'replyCount'},
    {'1': 'quote_count', '3': 15, '4': 1, '5': 3, '10': 'quoteCount'},
    {
      '1': 'visibility',
      '3': 16,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.posts.v1.Visibility',
      '10': 'visibility'
    },
    {
      '1': 'created_at',
      '3': 17,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '10': 'createdAt'
    },
  ],
};

/// Descriptor for `Post`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List postDescriptor = $convert.base64Decode(
    'CgRQb3N0EhcKB3Bvc3RfaWQYASABKAlSBnBvc3RJZBI5CgZhdXRob3IYAiABKAsyIS5kemVyb3'
    'RoLmNvbW1vbi52MS5BdXRob3JTbmFwc2hvdFIGYXV0aG9yEi4KBGtpbmQYAyABKA4yGi5kemVy'
    'b3RoLnBvc3RzLnYxLlBvc3RLaW5kUgRraW5kEhIKBHRleHQYBCABKAlSBHRleHQSMQoFbWVkaW'
    'EYBSADKAsyGy5kemVyb3RoLmNvbW1vbi52MS5NZWRpYVJlZlIFbWVkaWESJwoQcmVwbHlfdG9f'
    'cG9zdF9pZBgGIAEoCVINcmVwbHlUb1Bvc3RJZBImCg9yZXBseV90b19oYW5kbGUYByABKAlSDX'
    'JlcGx5VG9IYW5kbGUSJwoPY29udmVyc2F0aW9uX2lkGAggASgJUg5jb252ZXJzYXRpb25JZBI6'
    'CghlbWJlZGRlZBgJIAEoCzIeLmR6ZXJvdGgucG9zdHMudjEuRW1iZWRkZWRQb3N0UghlbWJlZG'
    'RlZBIaCghoYXNodGFncxgKIAMoCVIIaGFzaHRhZ3MSNQoIbWVudGlvbnMYCyADKAsyGS5kemVy'
    'b3RoLnBvc3RzLnYxLk1lbnRpb25SCG1lbnRpb25zEh0KCmxpa2VfY291bnQYDCABKANSCWxpa2'
    'VDb3VudBIhCgxyZXBvc3RfY291bnQYDSABKANSC3JlcG9zdENvdW50Eh8KC3JlcGx5X2NvdW50'
    'GA4gASgDUgpyZXBseUNvdW50Eh8KC3F1b3RlX2NvdW50GA8gASgDUgpxdW90ZUNvdW50EjwKCn'
    'Zpc2liaWxpdHkYECABKA4yHC5kemVyb3RoLnBvc3RzLnYxLlZpc2liaWxpdHlSCnZpc2liaWxp'
    'dHkSOQoKY3JlYXRlZF9hdBgRIAEoCzIaLmdvb2dsZS5wcm90b2J1Zi5UaW1lc3RhbXBSCWNyZW'
    'F0ZWRBdA==');

@$core.Deprecated('Use postViewDescriptor instead')
const PostView$json = {
  '1': 'PostView',
  '2': [
    {
      '1': 'post',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.posts.v1.Post',
      '10': 'post'
    },
    {'1': 'liked_by_viewer', '3': 2, '4': 1, '5': 8, '10': 'likedByViewer'},
    {
      '1': 'reposted_by_viewer',
      '3': 3,
      '4': 1,
      '5': 8,
      '10': 'repostedByViewer'
    },
  ],
};

/// Descriptor for `PostView`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List postViewDescriptor = $convert.base64Decode(
    'CghQb3N0VmlldxIqCgRwb3N0GAEgASgLMhYuZHplcm90aC5wb3N0cy52MS5Qb3N0UgRwb3N0Ei'
    'YKD2xpa2VkX2J5X3ZpZXdlchgCIAEoCFINbGlrZWRCeVZpZXdlchIsChJyZXBvc3RlZF9ieV92'
    'aWV3ZXIYAyABKAhSEHJlcG9zdGVkQnlWaWV3ZXI=');

@$core.Deprecated('Use createPostRequestDescriptor instead')
const CreatePostRequest$json = {
  '1': 'CreatePostRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'text', '3': 2, '4': 1, '5': 9, '10': 'text'},
    {'1': 'media_ids', '3': 3, '4': 3, '5': 9, '10': 'mediaIds'},
    {'1': 'reply_to_post_id', '3': 4, '4': 1, '5': 9, '10': 'replyToPostId'},
    {'1': 'quote_of_post_id', '3': 5, '4': 1, '5': 9, '10': 'quoteOfPostId'},
    {'1': 'media_alt_texts', '3': 6, '4': 3, '5': 9, '10': 'mediaAltTexts'},
  ],
};

/// Descriptor for `CreatePostRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List createPostRequestDescriptor = $convert.base64Decode(
    'ChFDcmVhdGVQb3N0UmVxdWVzdBInCg9pZGVtcG90ZW5jeV9rZXkYASABKAlSDmlkZW1wb3Rlbm'
    'N5S2V5EhIKBHRleHQYAiABKAlSBHRleHQSGwoJbWVkaWFfaWRzGAMgAygJUghtZWRpYUlkcxIn'
    'ChByZXBseV90b19wb3N0X2lkGAQgASgJUg1yZXBseVRvUG9zdElkEicKEHF1b3RlX29mX3Bvc3'
    'RfaWQYBSABKAlSDXF1b3RlT2ZQb3N0SWQSJgoPbWVkaWFfYWx0X3RleHRzGAYgAygJUg1tZWRp'
    'YUFsdFRleHRz');

@$core.Deprecated('Use createPostResponseDescriptor instead')
const CreatePostResponse$json = {
  '1': 'CreatePostResponse',
  '2': [
    {
      '1': 'post',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.posts.v1.PostView',
      '10': 'post'
    },
  ],
};

/// Descriptor for `CreatePostResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List createPostResponseDescriptor = $convert.base64Decode(
    'ChJDcmVhdGVQb3N0UmVzcG9uc2USLgoEcG9zdBgBIAEoCzIaLmR6ZXJvdGgucG9zdHMudjEuUG'
    '9zdFZpZXdSBHBvc3Q=');

@$core.Deprecated('Use deletePostRequestDescriptor instead')
const DeletePostRequest$json = {
  '1': 'DeletePostRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'post_id', '3': 2, '4': 1, '5': 9, '10': 'postId'},
  ],
};

/// Descriptor for `DeletePostRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List deletePostRequestDescriptor = $convert.base64Decode(
    'ChFEZWxldGVQb3N0UmVxdWVzdBInCg9pZGVtcG90ZW5jeV9rZXkYASABKAlSDmlkZW1wb3Rlbm'
    'N5S2V5EhcKB3Bvc3RfaWQYAiABKAlSBnBvc3RJZA==');

@$core.Deprecated('Use deletePostResponseDescriptor instead')
const DeletePostResponse$json = {
  '1': 'DeletePostResponse',
};

/// Descriptor for `DeletePostResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List deletePostResponseDescriptor =
    $convert.base64Decode('ChJEZWxldGVQb3N0UmVzcG9uc2U=');

@$core.Deprecated('Use getPostRequestDescriptor instead')
const GetPostRequest$json = {
  '1': 'GetPostRequest',
  '2': [
    {'1': 'post_id', '3': 1, '4': 1, '5': 9, '10': 'postId'},
  ],
};

/// Descriptor for `GetPostRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getPostRequestDescriptor = $convert
    .base64Decode('Cg5HZXRQb3N0UmVxdWVzdBIXCgdwb3N0X2lkGAEgASgJUgZwb3N0SWQ=');

@$core.Deprecated('Use getPostResponseDescriptor instead')
const GetPostResponse$json = {
  '1': 'GetPostResponse',
  '2': [
    {
      '1': 'post',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.posts.v1.PostView',
      '10': 'post'
    },
  ],
};

/// Descriptor for `GetPostResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getPostResponseDescriptor = $convert.base64Decode(
    'Cg9HZXRQb3N0UmVzcG9uc2USLgoEcG9zdBgBIAEoCzIaLmR6ZXJvdGgucG9zdHMudjEuUG9zdF'
    'ZpZXdSBHBvc3Q=');

@$core.Deprecated('Use getThreadRequestDescriptor instead')
const GetThreadRequest$json = {
  '1': 'GetThreadRequest',
  '2': [
    {'1': 'post_id', '3': 1, '4': 1, '5': 9, '10': 'postId'},
    {'1': 'page_size', '3': 2, '4': 1, '5': 5, '10': 'pageSize'},
    {'1': 'page_token', '3': 3, '4': 1, '5': 9, '10': 'pageToken'},
  ],
};

/// Descriptor for `GetThreadRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getThreadRequestDescriptor = $convert.base64Decode(
    'ChBHZXRUaHJlYWRSZXF1ZXN0EhcKB3Bvc3RfaWQYASABKAlSBnBvc3RJZBIbCglwYWdlX3Npem'
    'UYAiABKAVSCHBhZ2VTaXplEh0KCnBhZ2VfdG9rZW4YAyABKAlSCXBhZ2VUb2tlbg==');

@$core.Deprecated('Use getThreadResponseDescriptor instead')
const GetThreadResponse$json = {
  '1': 'GetThreadResponse',
  '2': [
    {
      '1': 'focal',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.posts.v1.PostView',
      '10': 'focal'
    },
    {
      '1': 'parent',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.posts.v1.PostView',
      '10': 'parent'
    },
    {
      '1': 'root',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.posts.v1.PostView',
      '10': 'root'
    },
    {
      '1': 'replies',
      '3': 4,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.posts.v1.PostView',
      '10': 'replies'
    },
    {'1': 'next_page_token', '3': 5, '4': 1, '5': 9, '10': 'nextPageToken'},
  ],
};

/// Descriptor for `GetThreadResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getThreadResponseDescriptor = $convert.base64Decode(
    'ChFHZXRUaHJlYWRSZXNwb25zZRIwCgVmb2NhbBgBIAEoCzIaLmR6ZXJvdGgucG9zdHMudjEuUG'
    '9zdFZpZXdSBWZvY2FsEjIKBnBhcmVudBgCIAEoCzIaLmR6ZXJvdGgucG9zdHMudjEuUG9zdFZp'
    'ZXdSBnBhcmVudBIuCgRyb290GAMgASgLMhouZHplcm90aC5wb3N0cy52MS5Qb3N0Vmlld1IEcm'
    '9vdBI0CgdyZXBsaWVzGAQgAygLMhouZHplcm90aC5wb3N0cy52MS5Qb3N0Vmlld1IHcmVwbGll'
    'cxImCg9uZXh0X3BhZ2VfdG9rZW4YBSABKAlSDW5leHRQYWdlVG9rZW4=');

const $core.Map<$core.String, $core.dynamic> PostServiceBase$json = {
  '1': 'PostService',
  '2': [
    {
      '1': 'CreatePost',
      '2': '.dzeroth.posts.v1.CreatePostRequest',
      '3': '.dzeroth.posts.v1.CreatePostResponse'
    },
    {
      '1': 'DeletePost',
      '2': '.dzeroth.posts.v1.DeletePostRequest',
      '3': '.dzeroth.posts.v1.DeletePostResponse'
    },
    {
      '1': 'GetPost',
      '2': '.dzeroth.posts.v1.GetPostRequest',
      '3': '.dzeroth.posts.v1.GetPostResponse',
      '4': {'34': 1},
    },
    {
      '1': 'GetThread',
      '2': '.dzeroth.posts.v1.GetThreadRequest',
      '3': '.dzeroth.posts.v1.GetThreadResponse',
      '4': {'34': 1},
    },
  ],
};

@$core.Deprecated('Use postServiceDescriptor instead')
const $core.Map<$core.String, $core.Map<$core.String, $core.dynamic>>
    PostServiceBase$messageJson = {
  '.dzeroth.posts.v1.CreatePostRequest': CreatePostRequest$json,
  '.dzeroth.posts.v1.CreatePostResponse': CreatePostResponse$json,
  '.dzeroth.posts.v1.PostView': PostView$json,
  '.dzeroth.posts.v1.Post': Post$json,
  '.dzeroth.common.v1.AuthorSnapshot': $0.AuthorSnapshot$json,
  '.dzeroth.common.v1.MediaRef': $0.MediaRef$json,
  '.dzeroth.posts.v1.EmbeddedPost': EmbeddedPost$json,
  '.google.protobuf.Timestamp': $1.Timestamp$json,
  '.dzeroth.posts.v1.Mention': Mention$json,
  '.dzeroth.posts.v1.DeletePostRequest': DeletePostRequest$json,
  '.dzeroth.posts.v1.DeletePostResponse': DeletePostResponse$json,
  '.dzeroth.posts.v1.GetPostRequest': GetPostRequest$json,
  '.dzeroth.posts.v1.GetPostResponse': GetPostResponse$json,
  '.dzeroth.posts.v1.GetThreadRequest': GetThreadRequest$json,
  '.dzeroth.posts.v1.GetThreadResponse': GetThreadResponse$json,
};

/// Descriptor for `PostService`. Decode as a `google.protobuf.ServiceDescriptorProto`.
final $typed_data.Uint8List postServiceDescriptor = $convert.base64Decode(
    'CgtQb3N0U2VydmljZRJXCgpDcmVhdGVQb3N0EiMuZHplcm90aC5wb3N0cy52MS5DcmVhdGVQb3'
    'N0UmVxdWVzdBokLmR6ZXJvdGgucG9zdHMudjEuQ3JlYXRlUG9zdFJlc3BvbnNlElcKCkRlbGV0'
    'ZVBvc3QSIy5kemVyb3RoLnBvc3RzLnYxLkRlbGV0ZVBvc3RSZXF1ZXN0GiQuZHplcm90aC5wb3'
    'N0cy52MS5EZWxldGVQb3N0UmVzcG9uc2USUwoHR2V0UG9zdBIgLmR6ZXJvdGgucG9zdHMudjEu'
    'R2V0UG9zdFJlcXVlc3QaIS5kemVyb3RoLnBvc3RzLnYxLkdldFBvc3RSZXNwb25zZSIDkAIBEl'
    'kKCUdldFRocmVhZBIiLmR6ZXJvdGgucG9zdHMudjEuR2V0VGhyZWFkUmVxdWVzdBojLmR6ZXJv'
    'dGgucG9zdHMudjEuR2V0VGhyZWFkUmVzcG9uc2UiA5ACAQ==');
