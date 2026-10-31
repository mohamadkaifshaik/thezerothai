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

import 'package:protobuf/well_known_types/google/protobuf/timestamp.pbjson.dart'
    as $1;

import '../../common/v1/common.pbjson.dart' as $2;
import '../../posts/v1/posts.pbjson.dart' as $0;

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

@$core.Deprecated('Use bookmarkStateDescriptor instead')
const BookmarkState$json = {
  '1': 'BookmarkState',
  '2': [
    {'1': 'post_id', '3': 1, '4': 1, '5': 9, '10': 'postId'},
    {'1': 'bookmarked', '3': 2, '4': 1, '5': 8, '10': 'bookmarked'},
  ],
};

/// Descriptor for `BookmarkState`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List bookmarkStateDescriptor = $convert.base64Decode(
    'Cg1Cb29rbWFya1N0YXRlEhcKB3Bvc3RfaWQYASABKAlSBnBvc3RJZBIeCgpib29rbWFya2VkGA'
    'IgASgIUgpib29rbWFya2Vk');

@$core.Deprecated('Use addBookmarkRequestDescriptor instead')
const AddBookmarkRequest$json = {
  '1': 'AddBookmarkRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'post_id', '3': 2, '4': 1, '5': 9, '10': 'postId'},
  ],
};

/// Descriptor for `AddBookmarkRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List addBookmarkRequestDescriptor = $convert.base64Decode(
    'ChJBZGRCb29rbWFya1JlcXVlc3QSJwoPaWRlbXBvdGVuY3lfa2V5GAEgASgJUg5pZGVtcG90ZW'
    '5jeUtleRIXCgdwb3N0X2lkGAIgASgJUgZwb3N0SWQ=');

@$core.Deprecated('Use addBookmarkResponseDescriptor instead')
const AddBookmarkResponse$json = {
  '1': 'AddBookmarkResponse',
  '2': [
    {
      '1': 'state',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.engagement.v1.BookmarkState',
      '10': 'state'
    },
  ],
};

/// Descriptor for `AddBookmarkResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List addBookmarkResponseDescriptor = $convert.base64Decode(
    'ChNBZGRCb29rbWFya1Jlc3BvbnNlEjoKBXN0YXRlGAEgASgLMiQuZHplcm90aC5lbmdhZ2VtZW'
    '50LnYxLkJvb2ttYXJrU3RhdGVSBXN0YXRl');

@$core.Deprecated('Use removeBookmarkRequestDescriptor instead')
const RemoveBookmarkRequest$json = {
  '1': 'RemoveBookmarkRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'post_id', '3': 2, '4': 1, '5': 9, '10': 'postId'},
  ],
};

/// Descriptor for `RemoveBookmarkRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List removeBookmarkRequestDescriptor = $convert.base64Decode(
    'ChVSZW1vdmVCb29rbWFya1JlcXVlc3QSJwoPaWRlbXBvdGVuY3lfa2V5GAEgASgJUg5pZGVtcG'
    '90ZW5jeUtleRIXCgdwb3N0X2lkGAIgASgJUgZwb3N0SWQ=');

@$core.Deprecated('Use removeBookmarkResponseDescriptor instead')
const RemoveBookmarkResponse$json = {
  '1': 'RemoveBookmarkResponse',
  '2': [
    {
      '1': 'state',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.engagement.v1.BookmarkState',
      '10': 'state'
    },
  ],
};

/// Descriptor for `RemoveBookmarkResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List removeBookmarkResponseDescriptor =
    $convert.base64Decode(
        'ChZSZW1vdmVCb29rbWFya1Jlc3BvbnNlEjoKBXN0YXRlGAEgASgLMiQuZHplcm90aC5lbmdhZ2'
        'VtZW50LnYxLkJvb2ttYXJrU3RhdGVSBXN0YXRl');

@$core.Deprecated('Use listBookmarksRequestDescriptor instead')
const ListBookmarksRequest$json = {
  '1': 'ListBookmarksRequest',
  '2': [
    {'1': 'page_size', '3': 1, '4': 1, '5': 5, '10': 'pageSize'},
    {'1': 'page_token', '3': 2, '4': 1, '5': 9, '10': 'pageToken'},
  ],
};

/// Descriptor for `ListBookmarksRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listBookmarksRequestDescriptor = $convert.base64Decode(
    'ChRMaXN0Qm9va21hcmtzUmVxdWVzdBIbCglwYWdlX3NpemUYASABKAVSCHBhZ2VTaXplEh0KCn'
    'BhZ2VfdG9rZW4YAiABKAlSCXBhZ2VUb2tlbg==');

@$core.Deprecated('Use bookmarkDescriptor instead')
const Bookmark$json = {
  '1': 'Bookmark',
  '2': [
    {
      '1': 'post',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.posts.v1.PostView',
      '10': 'post'
    },
    {
      '1': 'bookmarked_at',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '10': 'bookmarkedAt'
    },
  ],
};

/// Descriptor for `Bookmark`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List bookmarkDescriptor = $convert.base64Decode(
    'CghCb29rbWFyaxIuCgRwb3N0GAEgASgLMhouZHplcm90aC5wb3N0cy52MS5Qb3N0Vmlld1IEcG'
    '9zdBI/Cg1ib29rbWFya2VkX2F0GAIgASgLMhouZ29vZ2xlLnByb3RvYnVmLlRpbWVzdGFtcFIM'
    'Ym9va21hcmtlZEF0');

@$core.Deprecated('Use listBookmarksResponseDescriptor instead')
const ListBookmarksResponse$json = {
  '1': 'ListBookmarksResponse',
  '2': [
    {
      '1': 'bookmarks',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.engagement.v1.Bookmark',
      '10': 'bookmarks'
    },
    {'1': 'next_page_token', '3': 2, '4': 1, '5': 9, '10': 'nextPageToken'},
  ],
};

/// Descriptor for `ListBookmarksResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listBookmarksResponseDescriptor = $convert.base64Decode(
    'ChVMaXN0Qm9va21hcmtzUmVzcG9uc2USPQoJYm9va21hcmtzGAEgAygLMh8uZHplcm90aC5lbm'
    'dhZ2VtZW50LnYxLkJvb2ttYXJrUglib29rbWFya3MSJgoPbmV4dF9wYWdlX3Rva2VuGAIgASgJ'
    'Ug1uZXh0UGFnZVRva2Vu');

@$core.Deprecated('Use listLikedPostsRequestDescriptor instead')
const ListLikedPostsRequest$json = {
  '1': 'ListLikedPostsRequest',
  '2': [
    {'1': 'page_size', '3': 1, '4': 1, '5': 5, '10': 'pageSize'},
    {'1': 'page_token', '3': 2, '4': 1, '5': 9, '10': 'pageToken'},
  ],
};

/// Descriptor for `ListLikedPostsRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listLikedPostsRequestDescriptor = $convert.base64Decode(
    'ChVMaXN0TGlrZWRQb3N0c1JlcXVlc3QSGwoJcGFnZV9zaXplGAEgASgFUghwYWdlU2l6ZRIdCg'
    'pwYWdlX3Rva2VuGAIgASgJUglwYWdlVG9rZW4=');

@$core.Deprecated('Use listLikedPostsResponseDescriptor instead')
const ListLikedPostsResponse$json = {
  '1': 'ListLikedPostsResponse',
  '2': [
    {
      '1': 'posts',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.posts.v1.PostView',
      '10': 'posts'
    },
    {'1': 'next_page_token', '3': 2, '4': 1, '5': 9, '10': 'nextPageToken'},
  ],
};

/// Descriptor for `ListLikedPostsResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listLikedPostsResponseDescriptor = $convert.base64Decode(
    'ChZMaXN0TGlrZWRQb3N0c1Jlc3BvbnNlEjAKBXBvc3RzGAEgAygLMhouZHplcm90aC5wb3N0cy'
    '52MS5Qb3N0Vmlld1IFcG9zdHMSJgoPbmV4dF9wYWdlX3Rva2VuGAIgASgJUg1uZXh0UGFnZVRv'
    'a2Vu');

@$core.Deprecated('Use votePollRequestDescriptor instead')
const VotePollRequest$json = {
  '1': 'VotePollRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'post_id', '3': 2, '4': 1, '5': 9, '10': 'postId'},
    {'1': 'choice_index', '3': 3, '4': 1, '5': 5, '10': 'choiceIndex'},
    {'1': 'expected_choice', '3': 4, '4': 1, '5': 5, '10': 'expectedChoice'},
  ],
};

/// Descriptor for `VotePollRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List votePollRequestDescriptor = $convert.base64Decode(
    'Cg9Wb3RlUG9sbFJlcXVlc3QSJwoPaWRlbXBvdGVuY3lfa2V5GAEgASgJUg5pZGVtcG90ZW5jeU'
    'tleRIXCgdwb3N0X2lkGAIgASgJUgZwb3N0SWQSIQoMY2hvaWNlX2luZGV4GAMgASgFUgtjaG9p'
    'Y2VJbmRleBInCg9leHBlY3RlZF9jaG9pY2UYBCABKAVSDmV4cGVjdGVkQ2hvaWNl');

@$core.Deprecated('Use votePollResponseDescriptor instead')
const VotePollResponse$json = {
  '1': 'VotePollResponse',
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

/// Descriptor for `VotePollResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List votePollResponseDescriptor = $convert.base64Decode(
    'ChBWb3RlUG9sbFJlc3BvbnNlEi4KBHBvc3QYASABKAsyGi5kemVyb3RoLnBvc3RzLnYxLlBvc3'
    'RWaWV3UgRwb3N0');

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
    {
      '1': 'AddBookmark',
      '2': '.dzeroth.engagement.v1.AddBookmarkRequest',
      '3': '.dzeroth.engagement.v1.AddBookmarkResponse'
    },
    {
      '1': 'RemoveBookmark',
      '2': '.dzeroth.engagement.v1.RemoveBookmarkRequest',
      '3': '.dzeroth.engagement.v1.RemoveBookmarkResponse'
    },
    {
      '1': 'ListBookmarks',
      '2': '.dzeroth.engagement.v1.ListBookmarksRequest',
      '3': '.dzeroth.engagement.v1.ListBookmarksResponse',
      '4': {'34': 1},
    },
    {
      '1': 'ListLikedPosts',
      '2': '.dzeroth.engagement.v1.ListLikedPostsRequest',
      '3': '.dzeroth.engagement.v1.ListLikedPostsResponse',
      '4': {'34': 1},
    },
    {
      '1': 'VotePoll',
      '2': '.dzeroth.engagement.v1.VotePollRequest',
      '3': '.dzeroth.engagement.v1.VotePollResponse'
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
  '.dzeroth.engagement.v1.AddBookmarkRequest': AddBookmarkRequest$json,
  '.dzeroth.engagement.v1.AddBookmarkResponse': AddBookmarkResponse$json,
  '.dzeroth.engagement.v1.BookmarkState': BookmarkState$json,
  '.dzeroth.engagement.v1.RemoveBookmarkRequest': RemoveBookmarkRequest$json,
  '.dzeroth.engagement.v1.RemoveBookmarkResponse': RemoveBookmarkResponse$json,
  '.dzeroth.engagement.v1.ListBookmarksRequest': ListBookmarksRequest$json,
  '.dzeroth.engagement.v1.ListBookmarksResponse': ListBookmarksResponse$json,
  '.dzeroth.engagement.v1.Bookmark': Bookmark$json,
  '.dzeroth.posts.v1.PostView': $0.PostView$json,
  '.dzeroth.posts.v1.Post': $0.Post$json,
  '.dzeroth.common.v1.AuthorSnapshot': $2.AuthorSnapshot$json,
  '.dzeroth.common.v1.MediaRef': $2.MediaRef$json,
  '.dzeroth.posts.v1.EmbeddedPost': $0.EmbeddedPost$json,
  '.google.protobuf.Timestamp': $1.Timestamp$json,
  '.dzeroth.posts.v1.Poll': $0.Poll$json,
  '.dzeroth.posts.v1.PollChoice': $0.PollChoice$json,
  '.dzeroth.posts.v1.Mention': $0.Mention$json,
  '.dzeroth.engagement.v1.ListLikedPostsRequest': ListLikedPostsRequest$json,
  '.dzeroth.engagement.v1.ListLikedPostsResponse': ListLikedPostsResponse$json,
  '.dzeroth.engagement.v1.VotePollRequest': VotePollRequest$json,
  '.dzeroth.engagement.v1.VotePollResponse': VotePollResponse$json,
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
    'YxLlVuZG9SZXBvc3RSZXNwb25zZRJkCgtBZGRCb29rbWFyaxIpLmR6ZXJvdGguZW5nYWdlbWVu'
    'dC52MS5BZGRCb29rbWFya1JlcXVlc3QaKi5kemVyb3RoLmVuZ2FnZW1lbnQudjEuQWRkQm9va2'
    '1hcmtSZXNwb25zZRJtCg5SZW1vdmVCb29rbWFyaxIsLmR6ZXJvdGguZW5nYWdlbWVudC52MS5S'
    'ZW1vdmVCb29rbWFya1JlcXVlc3QaLS5kemVyb3RoLmVuZ2FnZW1lbnQudjEuUmVtb3ZlQm9va2'
    '1hcmtSZXNwb25zZRJvCg1MaXN0Qm9va21hcmtzEisuZHplcm90aC5lbmdhZ2VtZW50LnYxLkxp'
    'c3RCb29rbWFya3NSZXF1ZXN0GiwuZHplcm90aC5lbmdhZ2VtZW50LnYxLkxpc3RCb29rbWFya3'
    'NSZXNwb25zZSIDkAIBEnIKDkxpc3RMaWtlZFBvc3RzEiwuZHplcm90aC5lbmdhZ2VtZW50LnYx'
    'Lkxpc3RMaWtlZFBvc3RzUmVxdWVzdBotLmR6ZXJvdGguZW5nYWdlbWVudC52MS5MaXN0TGlrZW'
    'RQb3N0c1Jlc3BvbnNlIgOQAgESWwoIVm90ZVBvbGwSJi5kemVyb3RoLmVuZ2FnZW1lbnQudjEu'
    'Vm90ZVBvbGxSZXF1ZXN0GicuZHplcm90aC5lbmdhZ2VtZW50LnYxLlZvdGVQb2xsUmVzcG9uc2'
    'U=');
