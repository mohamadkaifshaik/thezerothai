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
    as $0;

import '../../common/v1/common.pbjson.dart' as $1;

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

@$core.Deprecated('Use replyPolicyDescriptor instead')
const ReplyPolicy$json = {
  '1': 'ReplyPolicy',
  '2': [
    {'1': 'REPLY_POLICY_UNSPECIFIED', '2': 0},
    {'1': 'REPLY_POLICY_EVERYONE', '2': 1},
    {'1': 'REPLY_POLICY_FOLLOWING', '2': 2},
    {'1': 'REPLY_POLICY_MENTIONED_ONLY', '2': 3},
    {'1': 'REPLY_POLICY_FOLLOWING_OF_FOLLOWING', '2': 4},
    {'1': 'REPLY_POLICY_VERIFIED', '2': 5},
  ],
};

/// Descriptor for `ReplyPolicy`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List replyPolicyDescriptor = $convert.base64Decode(
    'CgtSZXBseVBvbGljeRIcChhSRVBMWV9QT0xJQ1lfVU5TUEVDSUZJRUQQABIZChVSRVBMWV9QT0'
    'xJQ1lfRVZFUllPTkUQARIaChZSRVBMWV9QT0xJQ1lfRk9MTE9XSU5HEAISHwobUkVQTFlfUE9M'
    'SUNZX01FTlRJT05FRF9PTkxZEAMSJwojUkVQTFlfUE9MSUNZX0ZPTExPV0lOR19PRl9GT0xMT1'
    'dJTkcQBBIZChVSRVBMWV9QT0xJQ1lfVkVSSUZJRUQQBQ==');

@$core.Deprecated('Use replyPermissionDescriptor instead')
const ReplyPermission$json = {
  '1': 'ReplyPermission',
  '2': [
    {'1': 'REPLY_PERMISSION_UNSPECIFIED', '2': 0},
    {'1': 'REPLY_PERMISSION_ALLOWED', '2': 1},
    {'1': 'REPLY_PERMISSION_NOT_ALLOWED', '2': 2},
    {'1': 'REPLY_PERMISSION_UNKNOWN', '2': 3},
  ],
};

/// Descriptor for `ReplyPermission`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List replyPermissionDescriptor = $convert.base64Decode(
    'Cg9SZXBseVBlcm1pc3Npb24SIAocUkVQTFlfUEVSTUlTU0lPTl9VTlNQRUNJRklFRBAAEhwKGF'
    'JFUExZX1BFUk1JU1NJT05fQUxMT1dFRBABEiAKHFJFUExZX1BFUk1JU1NJT05fTk9UX0FMTE9X'
    'RUQQAhIcChhSRVBMWV9QRVJNSVNTSU9OX1VOS05PV04QAw==');

@$core.Deprecated('Use embedViewerStateDescriptor instead')
const EmbedViewerState$json = {
  '1': 'EmbedViewerState',
  '2': [
    {'1': 'EMBED_VIEWER_STATE_UNSPECIFIED', '2': 0},
    {'1': 'EMBED_VIEWER_STATE_BLOCKED', '2': 1},
    {'1': 'EMBED_VIEWER_STATE_MUTED', '2': 2},
    {'1': 'EMBED_VIEWER_STATE_PROTECTED', '2': 3},
  ],
};

/// Descriptor for `EmbedViewerState`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List embedViewerStateDescriptor = $convert.base64Decode(
    'ChBFbWJlZFZpZXdlclN0YXRlEiIKHkVNQkVEX1ZJRVdFUl9TVEFURV9VTlNQRUNJRklFRBAAEh'
    '4KGkVNQkVEX1ZJRVdFUl9TVEFURV9CTE9DS0VEEAESHAoYRU1CRURfVklFV0VSX1NUQVRFX01V'
    'VEVEEAISIAocRU1CRURfVklFV0VSX1NUQVRFX1BST1RFQ1RFRBAD');

@$core.Deprecated('Use scheduledPostStatusDescriptor instead')
const ScheduledPostStatus$json = {
  '1': 'ScheduledPostStatus',
  '2': [
    {'1': 'SCHEDULED_POST_STATUS_UNSPECIFIED', '2': 0},
    {'1': 'SCHEDULED_POST_STATUS_PENDING', '2': 1},
    {'1': 'SCHEDULED_POST_STATUS_PUBLISHED', '2': 2},
    {'1': 'SCHEDULED_POST_STATUS_CANCELLED', '2': 3},
    {'1': 'SCHEDULED_POST_STATUS_FAILED', '2': 4},
  ],
};

/// Descriptor for `ScheduledPostStatus`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List scheduledPostStatusDescriptor = $convert.base64Decode(
    'ChNTY2hlZHVsZWRQb3N0U3RhdHVzEiUKIVNDSEVEVUxFRF9QT1NUX1NUQVRVU19VTlNQRUNJRk'
    'lFRBAAEiEKHVNDSEVEVUxFRF9QT1NUX1NUQVRVU19QRU5ESU5HEAESIwofU0NIRURVTEVEX1BP'
    'U1RfU1RBVFVTX1BVQkxJU0hFRBACEiMKH1NDSEVEVUxFRF9QT1NUX1NUQVRVU19DQU5DRUxMRU'
    'QQAxIgChxTQ0hFRFVMRURfUE9TVF9TVEFUVVNfRkFJTEVEEAQ=');

@$core.Deprecated('Use scheduledPostFailureDescriptor instead')
const ScheduledPostFailure$json = {
  '1': 'ScheduledPostFailure',
  '2': [
    {'1': 'SCHEDULED_POST_FAILURE_UNSPECIFIED', '2': 0},
    {'1': 'SCHEDULED_POST_FAILURE_MEDIA_UNAVAILABLE', '2': 1},
    {'1': 'SCHEDULED_POST_FAILURE_QUOTA_EXCEEDED', '2': 2},
    {'1': 'SCHEDULED_POST_FAILURE_ACCOUNT_RESTRICTED', '2': 3},
    {'1': 'SCHEDULED_POST_FAILURE_INVALID_CONTENT', '2': 4},
    {'1': 'SCHEDULED_POST_FAILURE_EXPIRED', '2': 5},
    {'1': 'SCHEDULED_POST_FAILURE_INTERNAL', '2': 6},
    {'1': 'SCHEDULED_POST_FAILURE_UNSUPPORTED', '2': 7},
  ],
};

/// Descriptor for `ScheduledPostFailure`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List scheduledPostFailureDescriptor = $convert.base64Decode(
    'ChRTY2hlZHVsZWRQb3N0RmFpbHVyZRImCiJTQ0hFRFVMRURfUE9TVF9GQUlMVVJFX1VOU1BFQ0'
    'lGSUVEEAASLAooU0NIRURVTEVEX1BPU1RfRkFJTFVSRV9NRURJQV9VTkFWQUlMQUJMRRABEikK'
    'JVNDSEVEVUxFRF9QT1NUX0ZBSUxVUkVfUVVPVEFfRVhDRUVERUQQAhItCilTQ0hFRFVMRURfUE'
    '9TVF9GQUlMVVJFX0FDQ09VTlRfUkVTVFJJQ1RFRBADEioKJlNDSEVEVUxFRF9QT1NUX0ZBSUxV'
    'UkVfSU5WQUxJRF9DT05URU5UEAQSIgoeU0NIRURVTEVEX1BPU1RfRkFJTFVSRV9FWFBJUkVEEA'
    'USIwofU0NIRURVTEVEX1BPU1RfRkFJTFVSRV9JTlRFUk5BTBAGEiYKIlNDSEVEVUxFRF9QT1NU'
    'X0ZBSUxVUkVfVU5TVVBQT1JURUQQBw==');

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

@$core.Deprecated('Use pollChoiceDescriptor instead')
const PollChoice$json = {
  '1': 'PollChoice',
  '2': [
    {'1': 'label', '3': 1, '4': 1, '5': 9, '10': 'label'},
    {'1': 'votes', '3': 2, '4': 1, '5': 3, '10': 'votes'},
  ],
};

/// Descriptor for `PollChoice`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List pollChoiceDescriptor = $convert.base64Decode(
    'CgpQb2xsQ2hvaWNlEhQKBWxhYmVsGAEgASgJUgVsYWJlbBIUCgV2b3RlcxgCIAEoA1IFdm90ZX'
    'M=');

@$core.Deprecated('Use pollDescriptor instead')
const Poll$json = {
  '1': 'Poll',
  '2': [
    {
      '1': 'choices',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.posts.v1.PollChoice',
      '10': 'choices'
    },
    {
      '1': 'closes_at',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '10': 'closesAt'
    },
    {'1': 'total_votes', '3': 3, '4': 1, '5': 3, '10': 'totalVotes'},
    {'1': 'results_visible', '3': 4, '4': 1, '5': 8, '10': 'resultsVisible'},
    {'1': 'closed', '3': 5, '4': 1, '5': 8, '10': 'closed'},
  ],
};

/// Descriptor for `Poll`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List pollDescriptor = $convert.base64Decode(
    'CgRQb2xsEjYKB2Nob2ljZXMYASADKAsyHC5kemVyb3RoLnBvc3RzLnYxLlBvbGxDaG9pY2VSB2'
    'Nob2ljZXMSNwoJY2xvc2VzX2F0GAIgASgLMhouZ29vZ2xlLnByb3RvYnVmLlRpbWVzdGFtcFII'
    'Y2xvc2VzQXQSHwoLdG90YWxfdm90ZXMYAyABKANSCnRvdGFsVm90ZXMSJwoPcmVzdWx0c192aX'
    'NpYmxlGAQgASgIUg5yZXN1bHRzVmlzaWJsZRIWCgZjbG9zZWQYBSABKAhSBmNsb3NlZA==');

@$core.Deprecated('Use pollDraftDescriptor instead')
const PollDraft$json = {
  '1': 'PollDraft',
  '2': [
    {'1': 'choices', '3': 1, '4': 3, '5': 9, '10': 'choices'},
    {'1': 'duration_minutes', '3': 2, '4': 1, '5': 5, '10': 'durationMinutes'},
  ],
};

/// Descriptor for `PollDraft`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List pollDraftDescriptor = $convert.base64Decode(
    'CglQb2xsRHJhZnQSGAoHY2hvaWNlcxgBIAMoCVIHY2hvaWNlcxIpChBkdXJhdGlvbl9taW51dG'
    'VzGAIgASgFUg9kdXJhdGlvbk1pbnV0ZXM=');

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
    {'1': 'paid_partnership', '3': 7, '4': 1, '5': 8, '10': 'paidPartnership'},
    {'1': 'made_with_ai', '3': 8, '4': 1, '5': 8, '10': 'madeWithAi'},
    {
      '1': 'reply_policy',
      '3': 9,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.posts.v1.ReplyPolicy',
      '10': 'replyPolicy'
    },
    {
      '1': 'poll',
      '3': 10,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.posts.v1.Poll',
      '10': 'poll'
    },
  ],
};

/// Descriptor for `EmbeddedPost`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List embeddedPostDescriptor = $convert.base64Decode(
    'CgxFbWJlZGRlZFBvc3QSFwoHcG9zdF9pZBgBIAEoCVIGcG9zdElkEjkKBmF1dGhvchgCIAEoCz'
    'IhLmR6ZXJvdGguY29tbW9uLnYxLkF1dGhvclNuYXBzaG90UgZhdXRob3ISEgoEdGV4dBgDIAEo'
    'CVIEdGV4dBIxCgVtZWRpYRgEIAMoCzIbLmR6ZXJvdGguY29tbW9uLnYxLk1lZGlhUmVmUgVtZW'
    'RpYRI5CgpjcmVhdGVkX2F0GAUgASgLMhouZ29vZ2xlLnByb3RvYnVmLlRpbWVzdGFtcFIJY3Jl'
    'YXRlZEF0EiAKC3VuYXZhaWxhYmxlGAYgASgIUgt1bmF2YWlsYWJsZRIpChBwYWlkX3BhcnRuZX'
    'JzaGlwGAcgASgIUg9wYWlkUGFydG5lcnNoaXASIAoMbWFkZV93aXRoX2FpGAggASgIUgptYWRl'
    'V2l0aEFpEkAKDHJlcGx5X3BvbGljeRgJIAEoDjIdLmR6ZXJvdGgucG9zdHMudjEuUmVwbHlQb2'
    'xpY3lSC3JlcGx5UG9saWN5EioKBHBvbGwYCiABKAsyFi5kemVyb3RoLnBvc3RzLnYxLlBvbGxS'
    'BHBvbGw=');

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
    {
      '1': 'reply_policy',
      '3': 18,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.posts.v1.ReplyPolicy',
      '10': 'replyPolicy'
    },
    {'1': 'paid_partnership', '3': 19, '4': 1, '5': 8, '10': 'paidPartnership'},
    {'1': 'made_with_ai', '3': 20, '4': 1, '5': 8, '10': 'madeWithAi'},
    {
      '1': 'poll',
      '3': 21,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.posts.v1.Poll',
      '10': 'poll'
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
    'F0ZWRBdBJACgxyZXBseV9wb2xpY3kYEiABKA4yHS5kemVyb3RoLnBvc3RzLnYxLlJlcGx5UG9s'
    'aWN5UgtyZXBseVBvbGljeRIpChBwYWlkX3BhcnRuZXJzaGlwGBMgASgIUg9wYWlkUGFydG5lcn'
    'NoaXASIAoMbWFkZV93aXRoX2FpGBQgASgIUgptYWRlV2l0aEFpEioKBHBvbGwYFSABKAsyFi5k'
    'emVyb3RoLnBvc3RzLnYxLlBvbGxSBHBvbGw=');

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
    {
      '1': 'viewer_reply_permission',
      '3': 4,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.posts.v1.ReplyPermission',
      '10': 'viewerReplyPermission'
    },
    {
      '1': 'embed_viewer_state',
      '3': 5,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.posts.v1.EmbedViewerState',
      '10': 'embedViewerState'
    },
    {
      '1': 'bookmarked_by_viewer',
      '3': 6,
      '4': 1,
      '5': 8,
      '10': 'bookmarkedByViewer'
    },
    {'1': 'withheld', '3': 7, '4': 1, '5': 8, '10': 'withheld'},
    {
      '1': 'viewer_poll_choice',
      '3': 8,
      '4': 1,
      '5': 5,
      '10': 'viewerPollChoice'
    },
    {
      '1': 'viewer_poll_vote_blocked',
      '3': 9,
      '4': 1,
      '5': 8,
      '10': 'viewerPollVoteBlocked'
    },
  ],
};

/// Descriptor for `PostView`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List postViewDescriptor = $convert.base64Decode(
    'CghQb3N0VmlldxIqCgRwb3N0GAEgASgLMhYuZHplcm90aC5wb3N0cy52MS5Qb3N0UgRwb3N0Ei'
    'YKD2xpa2VkX2J5X3ZpZXdlchgCIAEoCFINbGlrZWRCeVZpZXdlchIsChJyZXBvc3RlZF9ieV92'
    'aWV3ZXIYAyABKAhSEHJlcG9zdGVkQnlWaWV3ZXISWQoXdmlld2VyX3JlcGx5X3Blcm1pc3Npb2'
    '4YBCABKA4yIS5kemVyb3RoLnBvc3RzLnYxLlJlcGx5UGVybWlzc2lvblIVdmlld2VyUmVwbHlQ'
    'ZXJtaXNzaW9uElAKEmVtYmVkX3ZpZXdlcl9zdGF0ZRgFIAEoDjIiLmR6ZXJvdGgucG9zdHMudj'
    'EuRW1iZWRWaWV3ZXJTdGF0ZVIQZW1iZWRWaWV3ZXJTdGF0ZRIwChRib29rbWFya2VkX2J5X3Zp'
    'ZXdlchgGIAEoCFISYm9va21hcmtlZEJ5Vmlld2VyEhoKCHdpdGhoZWxkGAcgASgIUgh3aXRoaG'
    'VsZBIsChJ2aWV3ZXJfcG9sbF9jaG9pY2UYCCABKAVSEHZpZXdlclBvbGxDaG9pY2USNwoYdmll'
    'd2VyX3BvbGxfdm90ZV9ibG9ja2VkGAkgASgIUhV2aWV3ZXJQb2xsVm90ZUJsb2NrZWQ=');

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
    {
      '1': 'reply_policy',
      '3': 7,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.posts.v1.ReplyPolicy',
      '10': 'replyPolicy'
    },
    {'1': 'paid_partnership', '3': 8, '4': 1, '5': 8, '10': 'paidPartnership'},
    {'1': 'made_with_ai', '3': 9, '4': 1, '5': 8, '10': 'madeWithAi'},
    {
      '1': 'poll',
      '3': 10,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.posts.v1.PollDraft',
      '10': 'poll'
    },
  ],
};

/// Descriptor for `CreatePostRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List createPostRequestDescriptor = $convert.base64Decode(
    'ChFDcmVhdGVQb3N0UmVxdWVzdBInCg9pZGVtcG90ZW5jeV9rZXkYASABKAlSDmlkZW1wb3Rlbm'
    'N5S2V5EhIKBHRleHQYAiABKAlSBHRleHQSGwoJbWVkaWFfaWRzGAMgAygJUghtZWRpYUlkcxIn'
    'ChByZXBseV90b19wb3N0X2lkGAQgASgJUg1yZXBseVRvUG9zdElkEicKEHF1b3RlX29mX3Bvc3'
    'RfaWQYBSABKAlSDXF1b3RlT2ZQb3N0SWQSJgoPbWVkaWFfYWx0X3RleHRzGAYgAygJUg1tZWRp'
    'YUFsdFRleHRzEkAKDHJlcGx5X3BvbGljeRgHIAEoDjIdLmR6ZXJvdGgucG9zdHMudjEuUmVwbH'
    'lQb2xpY3lSC3JlcGx5UG9saWN5EikKEHBhaWRfcGFydG5lcnNoaXAYCCABKAhSD3BhaWRQYXJ0'
    'bmVyc2hpcBIgCgxtYWRlX3dpdGhfYWkYCSABKAhSCm1hZGVXaXRoQWkSLwoEcG9sbBgKIAEoCz'
    'IbLmR6ZXJvdGgucG9zdHMudjEuUG9sbERyYWZ0UgRwb2xs');

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
    {
      '1': 'parent_unavailable',
      '3': 6,
      '4': 1,
      '5': 8,
      '10': 'parentUnavailable'
    },
    {'1': 'root_unavailable', '3': 7, '4': 1, '5': 8, '10': 'rootUnavailable'},
  ],
};

/// Descriptor for `GetThreadResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getThreadResponseDescriptor = $convert.base64Decode(
    'ChFHZXRUaHJlYWRSZXNwb25zZRIwCgVmb2NhbBgBIAEoCzIaLmR6ZXJvdGgucG9zdHMudjEuUG'
    '9zdFZpZXdSBWZvY2FsEjIKBnBhcmVudBgCIAEoCzIaLmR6ZXJvdGgucG9zdHMudjEuUG9zdFZp'
    'ZXdSBnBhcmVudBIuCgRyb290GAMgASgLMhouZHplcm90aC5wb3N0cy52MS5Qb3N0Vmlld1IEcm'
    '9vdBI0CgdyZXBsaWVzGAQgAygLMhouZHplcm90aC5wb3N0cy52MS5Qb3N0Vmlld1IHcmVwbGll'
    'cxImCg9uZXh0X3BhZ2VfdG9rZW4YBSABKAlSDW5leHRQYWdlVG9rZW4SLQoScGFyZW50X3VuYX'
    'ZhaWxhYmxlGAYgASgIUhFwYXJlbnRVbmF2YWlsYWJsZRIpChByb290X3VuYXZhaWxhYmxlGAcg'
    'ASgIUg9yb290VW5hdmFpbGFibGU=');

@$core.Deprecated('Use scheduledPostDescriptor instead')
const ScheduledPost$json = {
  '1': 'ScheduledPost',
  '2': [
    {'1': 'scheduled_id', '3': 1, '4': 1, '5': 9, '10': 'scheduledId'},
    {'1': 'text', '3': 2, '4': 1, '5': 9, '10': 'text'},
    {
      '1': 'media',
      '3': 3,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.common.v1.MediaRef',
      '10': 'media'
    },
    {
      '1': 'reply_policy',
      '3': 4,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.posts.v1.ReplyPolicy',
      '10': 'replyPolicy'
    },
    {'1': 'paid_partnership', '3': 5, '4': 1, '5': 8, '10': 'paidPartnership'},
    {'1': 'made_with_ai', '3': 6, '4': 1, '5': 8, '10': 'madeWithAi'},
    {
      '1': 'publish_at',
      '3': 7,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '10': 'publishAt'
    },
    {
      '1': 'status',
      '3': 8,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.posts.v1.ScheduledPostStatus',
      '10': 'status'
    },
    {'1': 'post_id', '3': 9, '4': 1, '5': 9, '10': 'postId'},
    {
      '1': 'failure',
      '3': 10,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.posts.v1.ScheduledPostFailure',
      '10': 'failure'
    },
    {
      '1': 'created_at',
      '3': 11,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '10': 'createdAt'
    },
  ],
};

/// Descriptor for `ScheduledPost`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List scheduledPostDescriptor = $convert.base64Decode(
    'Cg1TY2hlZHVsZWRQb3N0EiEKDHNjaGVkdWxlZF9pZBgBIAEoCVILc2NoZWR1bGVkSWQSEgoEdG'
    'V4dBgCIAEoCVIEdGV4dBIxCgVtZWRpYRgDIAMoCzIbLmR6ZXJvdGguY29tbW9uLnYxLk1lZGlh'
    'UmVmUgVtZWRpYRJACgxyZXBseV9wb2xpY3kYBCABKA4yHS5kemVyb3RoLnBvc3RzLnYxLlJlcG'
    'x5UG9saWN5UgtyZXBseVBvbGljeRIpChBwYWlkX3BhcnRuZXJzaGlwGAUgASgIUg9wYWlkUGFy'
    'dG5lcnNoaXASIAoMbWFkZV93aXRoX2FpGAYgASgIUgptYWRlV2l0aEFpEjkKCnB1Ymxpc2hfYX'
    'QYByABKAsyGi5nb29nbGUucHJvdG9idWYuVGltZXN0YW1wUglwdWJsaXNoQXQSPQoGc3RhdHVz'
    'GAggASgOMiUuZHplcm90aC5wb3N0cy52MS5TY2hlZHVsZWRQb3N0U3RhdHVzUgZzdGF0dXMSFw'
    'oHcG9zdF9pZBgJIAEoCVIGcG9zdElkEkAKB2ZhaWx1cmUYCiABKA4yJi5kemVyb3RoLnBvc3Rz'
    'LnYxLlNjaGVkdWxlZFBvc3RGYWlsdXJlUgdmYWlsdXJlEjkKCmNyZWF0ZWRfYXQYCyABKAsyGi'
    '5nb29nbGUucHJvdG9idWYuVGltZXN0YW1wUgljcmVhdGVkQXQ=');

@$core.Deprecated('Use schedulePostRequestDescriptor instead')
const SchedulePostRequest$json = {
  '1': 'SchedulePostRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'text', '3': 2, '4': 1, '5': 9, '10': 'text'},
    {'1': 'media_ids', '3': 3, '4': 3, '5': 9, '10': 'mediaIds'},
    {'1': 'media_alt_texts', '3': 4, '4': 3, '5': 9, '10': 'mediaAltTexts'},
    {
      '1': 'reply_policy',
      '3': 5,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.posts.v1.ReplyPolicy',
      '10': 'replyPolicy'
    },
    {'1': 'paid_partnership', '3': 6, '4': 1, '5': 8, '10': 'paidPartnership'},
    {'1': 'made_with_ai', '3': 7, '4': 1, '5': 8, '10': 'madeWithAi'},
    {
      '1': 'publish_at',
      '3': 8,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '10': 'publishAt'
    },
  ],
};

/// Descriptor for `SchedulePostRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List schedulePostRequestDescriptor = $convert.base64Decode(
    'ChNTY2hlZHVsZVBvc3RSZXF1ZXN0EicKD2lkZW1wb3RlbmN5X2tleRgBIAEoCVIOaWRlbXBvdG'
    'VuY3lLZXkSEgoEdGV4dBgCIAEoCVIEdGV4dBIbCgltZWRpYV9pZHMYAyADKAlSCG1lZGlhSWRz'
    'EiYKD21lZGlhX2FsdF90ZXh0cxgEIAMoCVINbWVkaWFBbHRUZXh0cxJACgxyZXBseV9wb2xpY3'
    'kYBSABKA4yHS5kemVyb3RoLnBvc3RzLnYxLlJlcGx5UG9saWN5UgtyZXBseVBvbGljeRIpChBw'
    'YWlkX3BhcnRuZXJzaGlwGAYgASgIUg9wYWlkUGFydG5lcnNoaXASIAoMbWFkZV93aXRoX2FpGA'
    'cgASgIUgptYWRlV2l0aEFpEjkKCnB1Ymxpc2hfYXQYCCABKAsyGi5nb29nbGUucHJvdG9idWYu'
    'VGltZXN0YW1wUglwdWJsaXNoQXQ=');

@$core.Deprecated('Use schedulePostResponseDescriptor instead')
const SchedulePostResponse$json = {
  '1': 'SchedulePostResponse',
  '2': [
    {
      '1': 'scheduled_post',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.posts.v1.ScheduledPost',
      '10': 'scheduledPost'
    },
  ],
};

/// Descriptor for `SchedulePostResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List schedulePostResponseDescriptor = $convert.base64Decode(
    'ChRTY2hlZHVsZVBvc3RSZXNwb25zZRJGCg5zY2hlZHVsZWRfcG9zdBgBIAEoCzIfLmR6ZXJvdG'
    'gucG9zdHMudjEuU2NoZWR1bGVkUG9zdFINc2NoZWR1bGVkUG9zdA==');

@$core.Deprecated('Use listScheduledPostsRequestDescriptor instead')
const ListScheduledPostsRequest$json = {
  '1': 'ListScheduledPostsRequest',
  '2': [
    {'1': 'page_size', '3': 1, '4': 1, '5': 5, '10': 'pageSize'},
    {'1': 'page_token', '3': 2, '4': 1, '5': 9, '10': 'pageToken'},
  ],
};

/// Descriptor for `ListScheduledPostsRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listScheduledPostsRequestDescriptor =
    $convert.base64Decode(
        'ChlMaXN0U2NoZWR1bGVkUG9zdHNSZXF1ZXN0EhsKCXBhZ2Vfc2l6ZRgBIAEoBVIIcGFnZVNpem'
        'USHQoKcGFnZV90b2tlbhgCIAEoCVIJcGFnZVRva2Vu');

@$core.Deprecated('Use listScheduledPostsResponseDescriptor instead')
const ListScheduledPostsResponse$json = {
  '1': 'ListScheduledPostsResponse',
  '2': [
    {
      '1': 'scheduled_posts',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.posts.v1.ScheduledPost',
      '10': 'scheduledPosts'
    },
    {'1': 'next_page_token', '3': 2, '4': 1, '5': 9, '10': 'nextPageToken'},
  ],
};

/// Descriptor for `ListScheduledPostsResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listScheduledPostsResponseDescriptor =
    $convert.base64Decode(
        'ChpMaXN0U2NoZWR1bGVkUG9zdHNSZXNwb25zZRJICg9zY2hlZHVsZWRfcG9zdHMYASADKAsyHy'
        '5kemVyb3RoLnBvc3RzLnYxLlNjaGVkdWxlZFBvc3RSDnNjaGVkdWxlZFBvc3RzEiYKD25leHRf'
        'cGFnZV90b2tlbhgCIAEoCVINbmV4dFBhZ2VUb2tlbg==');

@$core.Deprecated('Use cancelScheduledPostRequestDescriptor instead')
const CancelScheduledPostRequest$json = {
  '1': 'CancelScheduledPostRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'scheduled_id', '3': 2, '4': 1, '5': 9, '10': 'scheduledId'},
  ],
};

/// Descriptor for `CancelScheduledPostRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List cancelScheduledPostRequestDescriptor =
    $convert.base64Decode(
        'ChpDYW5jZWxTY2hlZHVsZWRQb3N0UmVxdWVzdBInCg9pZGVtcG90ZW5jeV9rZXkYASABKAlSDm'
        'lkZW1wb3RlbmN5S2V5EiEKDHNjaGVkdWxlZF9pZBgCIAEoCVILc2NoZWR1bGVkSWQ=');

@$core.Deprecated('Use cancelScheduledPostResponseDescriptor instead')
const CancelScheduledPostResponse$json = {
  '1': 'CancelScheduledPostResponse',
  '2': [
    {
      '1': 'scheduled_post',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.posts.v1.ScheduledPost',
      '10': 'scheduledPost'
    },
  ],
};

/// Descriptor for `CancelScheduledPostResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List cancelScheduledPostResponseDescriptor =
    $convert.base64Decode(
        'ChtDYW5jZWxTY2hlZHVsZWRQb3N0UmVzcG9uc2USRgoOc2NoZWR1bGVkX3Bvc3QYASABKAsyHy'
        '5kemVyb3RoLnBvc3RzLnYxLlNjaGVkdWxlZFBvc3RSDXNjaGVkdWxlZFBvc3Q=');

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
    {
      '1': 'SchedulePost',
      '2': '.dzeroth.posts.v1.SchedulePostRequest',
      '3': '.dzeroth.posts.v1.SchedulePostResponse'
    },
    {
      '1': 'ListScheduledPosts',
      '2': '.dzeroth.posts.v1.ListScheduledPostsRequest',
      '3': '.dzeroth.posts.v1.ListScheduledPostsResponse',
      '4': {'34': 1},
    },
    {
      '1': 'CancelScheduledPost',
      '2': '.dzeroth.posts.v1.CancelScheduledPostRequest',
      '3': '.dzeroth.posts.v1.CancelScheduledPostResponse'
    },
  ],
};

@$core.Deprecated('Use postServiceDescriptor instead')
const $core.Map<$core.String, $core.Map<$core.String, $core.dynamic>>
    PostServiceBase$messageJson = {
  '.dzeroth.posts.v1.CreatePostRequest': CreatePostRequest$json,
  '.dzeroth.posts.v1.PollDraft': PollDraft$json,
  '.dzeroth.posts.v1.CreatePostResponse': CreatePostResponse$json,
  '.dzeroth.posts.v1.PostView': PostView$json,
  '.dzeroth.posts.v1.Post': Post$json,
  '.dzeroth.common.v1.AuthorSnapshot': $1.AuthorSnapshot$json,
  '.dzeroth.common.v1.MediaRef': $1.MediaRef$json,
  '.dzeroth.posts.v1.EmbeddedPost': EmbeddedPost$json,
  '.google.protobuf.Timestamp': $0.Timestamp$json,
  '.dzeroth.posts.v1.Poll': Poll$json,
  '.dzeroth.posts.v1.PollChoice': PollChoice$json,
  '.dzeroth.posts.v1.Mention': Mention$json,
  '.dzeroth.posts.v1.DeletePostRequest': DeletePostRequest$json,
  '.dzeroth.posts.v1.DeletePostResponse': DeletePostResponse$json,
  '.dzeroth.posts.v1.GetPostRequest': GetPostRequest$json,
  '.dzeroth.posts.v1.GetPostResponse': GetPostResponse$json,
  '.dzeroth.posts.v1.GetThreadRequest': GetThreadRequest$json,
  '.dzeroth.posts.v1.GetThreadResponse': GetThreadResponse$json,
  '.dzeroth.posts.v1.SchedulePostRequest': SchedulePostRequest$json,
  '.dzeroth.posts.v1.SchedulePostResponse': SchedulePostResponse$json,
  '.dzeroth.posts.v1.ScheduledPost': ScheduledPost$json,
  '.dzeroth.posts.v1.ListScheduledPostsRequest': ListScheduledPostsRequest$json,
  '.dzeroth.posts.v1.ListScheduledPostsResponse':
      ListScheduledPostsResponse$json,
  '.dzeroth.posts.v1.CancelScheduledPostRequest':
      CancelScheduledPostRequest$json,
  '.dzeroth.posts.v1.CancelScheduledPostResponse':
      CancelScheduledPostResponse$json,
};

/// Descriptor for `PostService`. Decode as a `google.protobuf.ServiceDescriptorProto`.
final $typed_data.Uint8List postServiceDescriptor = $convert.base64Decode(
    'CgtQb3N0U2VydmljZRJXCgpDcmVhdGVQb3N0EiMuZHplcm90aC5wb3N0cy52MS5DcmVhdGVQb3'
    'N0UmVxdWVzdBokLmR6ZXJvdGgucG9zdHMudjEuQ3JlYXRlUG9zdFJlc3BvbnNlElcKCkRlbGV0'
    'ZVBvc3QSIy5kemVyb3RoLnBvc3RzLnYxLkRlbGV0ZVBvc3RSZXF1ZXN0GiQuZHplcm90aC5wb3'
    'N0cy52MS5EZWxldGVQb3N0UmVzcG9uc2USUwoHR2V0UG9zdBIgLmR6ZXJvdGgucG9zdHMudjEu'
    'R2V0UG9zdFJlcXVlc3QaIS5kemVyb3RoLnBvc3RzLnYxLkdldFBvc3RSZXNwb25zZSIDkAIBEl'
    'kKCUdldFRocmVhZBIiLmR6ZXJvdGgucG9zdHMudjEuR2V0VGhyZWFkUmVxdWVzdBojLmR6ZXJv'
    'dGgucG9zdHMudjEuR2V0VGhyZWFkUmVzcG9uc2UiA5ACARJdCgxTY2hlZHVsZVBvc3QSJS5kem'
    'Vyb3RoLnBvc3RzLnYxLlNjaGVkdWxlUG9zdFJlcXVlc3QaJi5kemVyb3RoLnBvc3RzLnYxLlNj'
    'aGVkdWxlUG9zdFJlc3BvbnNlEnQKEkxpc3RTY2hlZHVsZWRQb3N0cxIrLmR6ZXJvdGgucG9zdH'
    'MudjEuTGlzdFNjaGVkdWxlZFBvc3RzUmVxdWVzdBosLmR6ZXJvdGgucG9zdHMudjEuTGlzdFNj'
    'aGVkdWxlZFBvc3RzUmVzcG9uc2UiA5ACARJyChNDYW5jZWxTY2hlZHVsZWRQb3N0EiwuZHplcm'
    '90aC5wb3N0cy52MS5DYW5jZWxTY2hlZHVsZWRQb3N0UmVxdWVzdBotLmR6ZXJvdGgucG9zdHMu'
    'djEuQ2FuY2VsU2NoZWR1bGVkUG9zdFJlc3BvbnNl');
