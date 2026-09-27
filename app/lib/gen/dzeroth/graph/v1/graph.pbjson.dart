// This is a generated file - do not edit.
//
// Generated from dzeroth/graph/v1/graph.proto.

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

@$core.Deprecated('Use followStateDescriptor instead')
const FollowState$json = {
  '1': 'FollowState',
  '2': [
    {'1': 'FOLLOW_STATE_UNSPECIFIED', '2': 0},
    {'1': 'FOLLOW_STATE_NONE', '2': 1},
    {'1': 'FOLLOW_STATE_FOLLOWING', '2': 2},
    {'1': 'FOLLOW_STATE_REQUESTED', '2': 3},
  ],
};

/// Descriptor for `FollowState`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List followStateDescriptor = $convert.base64Decode(
    'CgtGb2xsb3dTdGF0ZRIcChhGT0xMT1dfU1RBVEVfVU5TUEVDSUZJRUQQABIVChFGT0xMT1dfU1'
    'RBVEVfTk9ORRABEhoKFkZPTExPV19TVEFURV9GT0xMT1dJTkcQAhIaChZGT0xMT1dfU1RBVEVf'
    'UkVRVUVTVEVEEAM=');

@$core.Deprecated('Use relationshipDescriptor instead')
const Relationship$json = {
  '1': 'Relationship',
  '2': [
    {'1': 'user_id', '3': 1, '4': 1, '5': 9, '10': 'userId'},
    {
      '1': 'follow_state',
      '3': 2,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.graph.v1.FollowState',
      '10': 'followState'
    },
    {'1': 'blocking', '3': 3, '4': 1, '5': 8, '10': 'blocking'},
    {'1': 'muting', '3': 4, '4': 1, '5': 8, '10': 'muting'},
  ],
};

/// Descriptor for `Relationship`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List relationshipDescriptor = $convert.base64Decode(
    'CgxSZWxhdGlvbnNoaXASFwoHdXNlcl9pZBgBIAEoCVIGdXNlcklkEkAKDGZvbGxvd19zdGF0ZR'
    'gCIAEoDjIdLmR6ZXJvdGguZ3JhcGgudjEuRm9sbG93U3RhdGVSC2ZvbGxvd1N0YXRlEhoKCGJs'
    'b2NraW5nGAMgASgIUghibG9ja2luZxIWCgZtdXRpbmcYBCABKAhSBm11dGluZw==');

@$core.Deprecated('Use userListItemDescriptor instead')
const UserListItem$json = {
  '1': 'UserListItem',
  '2': [
    {
      '1': 'user',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.common.v1.AuthorSnapshot',
      '10': 'user'
    },
    {
      '1': 'since',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '10': 'since'
    },
  ],
};

/// Descriptor for `UserListItem`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List userListItemDescriptor = $convert.base64Decode(
    'CgxVc2VyTGlzdEl0ZW0SNQoEdXNlchgBIAEoCzIhLmR6ZXJvdGguY29tbW9uLnYxLkF1dGhvcl'
    'NuYXBzaG90UgR1c2VyEjAKBXNpbmNlGAIgASgLMhouZ29vZ2xlLnByb3RvYnVmLlRpbWVzdGFt'
    'cFIFc2luY2U=');

@$core.Deprecated('Use followRequestDescriptor instead')
const FollowRequest$json = {
  '1': 'FollowRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'user_id', '3': 2, '4': 1, '5': 9, '10': 'userId'},
  ],
};

/// Descriptor for `FollowRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List followRequestDescriptor = $convert.base64Decode(
    'Cg1Gb2xsb3dSZXF1ZXN0EicKD2lkZW1wb3RlbmN5X2tleRgBIAEoCVIOaWRlbXBvdGVuY3lLZX'
    'kSFwoHdXNlcl9pZBgCIAEoCVIGdXNlcklk');

@$core.Deprecated('Use followResponseDescriptor instead')
const FollowResponse$json = {
  '1': 'FollowResponse',
  '2': [
    {
      '1': 'relationship',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.graph.v1.Relationship',
      '10': 'relationship'
    },
  ],
};

/// Descriptor for `FollowResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List followResponseDescriptor = $convert.base64Decode(
    'Cg5Gb2xsb3dSZXNwb25zZRJCCgxyZWxhdGlvbnNoaXAYASABKAsyHi5kemVyb3RoLmdyYXBoLn'
    'YxLlJlbGF0aW9uc2hpcFIMcmVsYXRpb25zaGlw');

@$core.Deprecated('Use unfollowRequestDescriptor instead')
const UnfollowRequest$json = {
  '1': 'UnfollowRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'user_id', '3': 2, '4': 1, '5': 9, '10': 'userId'},
  ],
};

/// Descriptor for `UnfollowRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List unfollowRequestDescriptor = $convert.base64Decode(
    'Cg9VbmZvbGxvd1JlcXVlc3QSJwoPaWRlbXBvdGVuY3lfa2V5GAEgASgJUg5pZGVtcG90ZW5jeU'
    'tleRIXCgd1c2VyX2lkGAIgASgJUgZ1c2VySWQ=');

@$core.Deprecated('Use unfollowResponseDescriptor instead')
const UnfollowResponse$json = {
  '1': 'UnfollowResponse',
  '2': [
    {
      '1': 'relationship',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.graph.v1.Relationship',
      '10': 'relationship'
    },
  ],
};

/// Descriptor for `UnfollowResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List unfollowResponseDescriptor = $convert.base64Decode(
    'ChBVbmZvbGxvd1Jlc3BvbnNlEkIKDHJlbGF0aW9uc2hpcBgBIAEoCzIeLmR6ZXJvdGguZ3JhcG'
    'gudjEuUmVsYXRpb25zaGlwUgxyZWxhdGlvbnNoaXA=');

@$core.Deprecated('Use listFollowRequestsRequestDescriptor instead')
const ListFollowRequestsRequest$json = {
  '1': 'ListFollowRequestsRequest',
  '2': [
    {'1': 'page_size', '3': 1, '4': 1, '5': 5, '10': 'pageSize'},
    {'1': 'page_token', '3': 2, '4': 1, '5': 9, '10': 'pageToken'},
  ],
};

/// Descriptor for `ListFollowRequestsRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listFollowRequestsRequestDescriptor =
    $convert.base64Decode(
        'ChlMaXN0Rm9sbG93UmVxdWVzdHNSZXF1ZXN0EhsKCXBhZ2Vfc2l6ZRgBIAEoBVIIcGFnZVNpem'
        'USHQoKcGFnZV90b2tlbhgCIAEoCVIJcGFnZVRva2Vu');

@$core.Deprecated('Use listFollowRequestsResponseDescriptor instead')
const ListFollowRequestsResponse$json = {
  '1': 'ListFollowRequestsResponse',
  '2': [
    {
      '1': 'requests',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.graph.v1.UserListItem',
      '10': 'requests'
    },
    {'1': 'next_page_token', '3': 2, '4': 1, '5': 9, '10': 'nextPageToken'},
  ],
};

/// Descriptor for `ListFollowRequestsResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listFollowRequestsResponseDescriptor =
    $convert.base64Decode(
        'ChpMaXN0Rm9sbG93UmVxdWVzdHNSZXNwb25zZRI6CghyZXF1ZXN0cxgBIAMoCzIeLmR6ZXJvdG'
        'guZ3JhcGgudjEuVXNlckxpc3RJdGVtUghyZXF1ZXN0cxImCg9uZXh0X3BhZ2VfdG9rZW4YAiAB'
        'KAlSDW5leHRQYWdlVG9rZW4=');

@$core.Deprecated('Use respondToFollowRequestRequestDescriptor instead')
const RespondToFollowRequestRequest$json = {
  '1': 'RespondToFollowRequestRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'requester_user_id', '3': 2, '4': 1, '5': 9, '10': 'requesterUserId'},
    {'1': 'accept', '3': 3, '4': 1, '5': 8, '10': 'accept'},
  ],
};

/// Descriptor for `RespondToFollowRequestRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List respondToFollowRequestRequestDescriptor =
    $convert.base64Decode(
        'Ch1SZXNwb25kVG9Gb2xsb3dSZXF1ZXN0UmVxdWVzdBInCg9pZGVtcG90ZW5jeV9rZXkYASABKA'
        'lSDmlkZW1wb3RlbmN5S2V5EioKEXJlcXVlc3Rlcl91c2VyX2lkGAIgASgJUg9yZXF1ZXN0ZXJV'
        'c2VySWQSFgoGYWNjZXB0GAMgASgIUgZhY2NlcHQ=');

@$core.Deprecated('Use respondToFollowRequestResponseDescriptor instead')
const RespondToFollowRequestResponse$json = {
  '1': 'RespondToFollowRequestResponse',
};

/// Descriptor for `RespondToFollowRequestResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List respondToFollowRequestResponseDescriptor =
    $convert.base64Decode('Ch5SZXNwb25kVG9Gb2xsb3dSZXF1ZXN0UmVzcG9uc2U=');

@$core.Deprecated('Use blockRequestDescriptor instead')
const BlockRequest$json = {
  '1': 'BlockRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'user_id', '3': 2, '4': 1, '5': 9, '10': 'userId'},
  ],
};

/// Descriptor for `BlockRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List blockRequestDescriptor = $convert.base64Decode(
    'CgxCbG9ja1JlcXVlc3QSJwoPaWRlbXBvdGVuY3lfa2V5GAEgASgJUg5pZGVtcG90ZW5jeUtleR'
    'IXCgd1c2VyX2lkGAIgASgJUgZ1c2VySWQ=');

@$core.Deprecated('Use blockResponseDescriptor instead')
const BlockResponse$json = {
  '1': 'BlockResponse',
  '2': [
    {
      '1': 'relationship',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.graph.v1.Relationship',
      '10': 'relationship'
    },
  ],
};

/// Descriptor for `BlockResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List blockResponseDescriptor = $convert.base64Decode(
    'Cg1CbG9ja1Jlc3BvbnNlEkIKDHJlbGF0aW9uc2hpcBgBIAEoCzIeLmR6ZXJvdGguZ3JhcGgudj'
    'EuUmVsYXRpb25zaGlwUgxyZWxhdGlvbnNoaXA=');

@$core.Deprecated('Use unblockRequestDescriptor instead')
const UnblockRequest$json = {
  '1': 'UnblockRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'user_id', '3': 2, '4': 1, '5': 9, '10': 'userId'},
  ],
};

/// Descriptor for `UnblockRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List unblockRequestDescriptor = $convert.base64Decode(
    'Cg5VbmJsb2NrUmVxdWVzdBInCg9pZGVtcG90ZW5jeV9rZXkYASABKAlSDmlkZW1wb3RlbmN5S2'
    'V5EhcKB3VzZXJfaWQYAiABKAlSBnVzZXJJZA==');

@$core.Deprecated('Use unblockResponseDescriptor instead')
const UnblockResponse$json = {
  '1': 'UnblockResponse',
  '2': [
    {
      '1': 'relationship',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.graph.v1.Relationship',
      '10': 'relationship'
    },
  ],
};

/// Descriptor for `UnblockResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List unblockResponseDescriptor = $convert.base64Decode(
    'Cg9VbmJsb2NrUmVzcG9uc2USQgoMcmVsYXRpb25zaGlwGAEgASgLMh4uZHplcm90aC5ncmFwaC'
    '52MS5SZWxhdGlvbnNoaXBSDHJlbGF0aW9uc2hpcA==');

@$core.Deprecated('Use muteRequestDescriptor instead')
const MuteRequest$json = {
  '1': 'MuteRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'user_id', '3': 2, '4': 1, '5': 9, '10': 'userId'},
  ],
};

/// Descriptor for `MuteRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List muteRequestDescriptor = $convert.base64Decode(
    'CgtNdXRlUmVxdWVzdBInCg9pZGVtcG90ZW5jeV9rZXkYASABKAlSDmlkZW1wb3RlbmN5S2V5Eh'
    'cKB3VzZXJfaWQYAiABKAlSBnVzZXJJZA==');

@$core.Deprecated('Use muteResponseDescriptor instead')
const MuteResponse$json = {
  '1': 'MuteResponse',
  '2': [
    {
      '1': 'relationship',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.graph.v1.Relationship',
      '10': 'relationship'
    },
  ],
};

/// Descriptor for `MuteResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List muteResponseDescriptor = $convert.base64Decode(
    'CgxNdXRlUmVzcG9uc2USQgoMcmVsYXRpb25zaGlwGAEgASgLMh4uZHplcm90aC5ncmFwaC52MS'
    '5SZWxhdGlvbnNoaXBSDHJlbGF0aW9uc2hpcA==');

@$core.Deprecated('Use unmuteRequestDescriptor instead')
const UnmuteRequest$json = {
  '1': 'UnmuteRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'user_id', '3': 2, '4': 1, '5': 9, '10': 'userId'},
  ],
};

/// Descriptor for `UnmuteRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List unmuteRequestDescriptor = $convert.base64Decode(
    'Cg1Vbm11dGVSZXF1ZXN0EicKD2lkZW1wb3RlbmN5X2tleRgBIAEoCVIOaWRlbXBvdGVuY3lLZX'
    'kSFwoHdXNlcl9pZBgCIAEoCVIGdXNlcklk');

@$core.Deprecated('Use unmuteResponseDescriptor instead')
const UnmuteResponse$json = {
  '1': 'UnmuteResponse',
  '2': [
    {
      '1': 'relationship',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.graph.v1.Relationship',
      '10': 'relationship'
    },
  ],
};

/// Descriptor for `UnmuteResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List unmuteResponseDescriptor = $convert.base64Decode(
    'Cg5Vbm11dGVSZXNwb25zZRJCCgxyZWxhdGlvbnNoaXAYASABKAsyHi5kemVyb3RoLmdyYXBoLn'
    'YxLlJlbGF0aW9uc2hpcFIMcmVsYXRpb25zaGlw');

@$core.Deprecated('Use getRelationshipsRequestDescriptor instead')
const GetRelationshipsRequest$json = {
  '1': 'GetRelationshipsRequest',
  '2': [
    {'1': 'user_ids', '3': 1, '4': 3, '5': 9, '10': 'userIds'},
  ],
};

/// Descriptor for `GetRelationshipsRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getRelationshipsRequestDescriptor =
    $convert.base64Decode(
        'ChdHZXRSZWxhdGlvbnNoaXBzUmVxdWVzdBIZCgh1c2VyX2lkcxgBIAMoCVIHdXNlcklkcw==');

@$core.Deprecated('Use getRelationshipsResponseDescriptor instead')
const GetRelationshipsResponse$json = {
  '1': 'GetRelationshipsResponse',
  '2': [
    {
      '1': 'relationships',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.graph.v1.Relationship',
      '10': 'relationships'
    },
  ],
};

/// Descriptor for `GetRelationshipsResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getRelationshipsResponseDescriptor =
    $convert.base64Decode(
        'ChhHZXRSZWxhdGlvbnNoaXBzUmVzcG9uc2USRAoNcmVsYXRpb25zaGlwcxgBIAMoCzIeLmR6ZX'
        'JvdGguZ3JhcGgudjEuUmVsYXRpb25zaGlwUg1yZWxhdGlvbnNoaXBz');

@$core.Deprecated('Use listFollowersRequestDescriptor instead')
const ListFollowersRequest$json = {
  '1': 'ListFollowersRequest',
  '2': [
    {'1': 'user_id', '3': 1, '4': 1, '5': 9, '10': 'userId'},
    {'1': 'page_size', '3': 2, '4': 1, '5': 5, '10': 'pageSize'},
    {'1': 'page_token', '3': 3, '4': 1, '5': 9, '10': 'pageToken'},
  ],
};

/// Descriptor for `ListFollowersRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listFollowersRequestDescriptor = $convert.base64Decode(
    'ChRMaXN0Rm9sbG93ZXJzUmVxdWVzdBIXCgd1c2VyX2lkGAEgASgJUgZ1c2VySWQSGwoJcGFnZV'
    '9zaXplGAIgASgFUghwYWdlU2l6ZRIdCgpwYWdlX3Rva2VuGAMgASgJUglwYWdlVG9rZW4=');

@$core.Deprecated('Use listFollowersResponseDescriptor instead')
const ListFollowersResponse$json = {
  '1': 'ListFollowersResponse',
  '2': [
    {
      '1': 'users',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.graph.v1.UserListItem',
      '10': 'users'
    },
    {'1': 'next_page_token', '3': 2, '4': 1, '5': 9, '10': 'nextPageToken'},
  ],
};

/// Descriptor for `ListFollowersResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listFollowersResponseDescriptor = $convert.base64Decode(
    'ChVMaXN0Rm9sbG93ZXJzUmVzcG9uc2USNAoFdXNlcnMYASADKAsyHi5kemVyb3RoLmdyYXBoLn'
    'YxLlVzZXJMaXN0SXRlbVIFdXNlcnMSJgoPbmV4dF9wYWdlX3Rva2VuGAIgASgJUg1uZXh0UGFn'
    'ZVRva2Vu');

@$core.Deprecated('Use listFollowingRequestDescriptor instead')
const ListFollowingRequest$json = {
  '1': 'ListFollowingRequest',
  '2': [
    {'1': 'user_id', '3': 1, '4': 1, '5': 9, '10': 'userId'},
    {'1': 'page_size', '3': 2, '4': 1, '5': 5, '10': 'pageSize'},
    {'1': 'page_token', '3': 3, '4': 1, '5': 9, '10': 'pageToken'},
  ],
};

/// Descriptor for `ListFollowingRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listFollowingRequestDescriptor = $convert.base64Decode(
    'ChRMaXN0Rm9sbG93aW5nUmVxdWVzdBIXCgd1c2VyX2lkGAEgASgJUgZ1c2VySWQSGwoJcGFnZV'
    '9zaXplGAIgASgFUghwYWdlU2l6ZRIdCgpwYWdlX3Rva2VuGAMgASgJUglwYWdlVG9rZW4=');

@$core.Deprecated('Use listFollowingResponseDescriptor instead')
const ListFollowingResponse$json = {
  '1': 'ListFollowingResponse',
  '2': [
    {
      '1': 'users',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.graph.v1.UserListItem',
      '10': 'users'
    },
    {'1': 'next_page_token', '3': 2, '4': 1, '5': 9, '10': 'nextPageToken'},
  ],
};

/// Descriptor for `ListFollowingResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listFollowingResponseDescriptor = $convert.base64Decode(
    'ChVMaXN0Rm9sbG93aW5nUmVzcG9uc2USNAoFdXNlcnMYASADKAsyHi5kemVyb3RoLmdyYXBoLn'
    'YxLlVzZXJMaXN0SXRlbVIFdXNlcnMSJgoPbmV4dF9wYWdlX3Rva2VuGAIgASgJUg1uZXh0UGFn'
    'ZVRva2Vu');

@$core.Deprecated('Use listBlockedUsersRequestDescriptor instead')
const ListBlockedUsersRequest$json = {
  '1': 'ListBlockedUsersRequest',
  '2': [
    {'1': 'page_size', '3': 1, '4': 1, '5': 5, '10': 'pageSize'},
    {'1': 'page_token', '3': 2, '4': 1, '5': 9, '10': 'pageToken'},
  ],
};

/// Descriptor for `ListBlockedUsersRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listBlockedUsersRequestDescriptor =
    $convert.base64Decode(
        'ChdMaXN0QmxvY2tlZFVzZXJzUmVxdWVzdBIbCglwYWdlX3NpemUYASABKAVSCHBhZ2VTaXplEh'
        '0KCnBhZ2VfdG9rZW4YAiABKAlSCXBhZ2VUb2tlbg==');

@$core.Deprecated('Use listBlockedUsersResponseDescriptor instead')
const ListBlockedUsersResponse$json = {
  '1': 'ListBlockedUsersResponse',
  '2': [
    {
      '1': 'users',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.graph.v1.UserListItem',
      '10': 'users'
    },
    {'1': 'next_page_token', '3': 2, '4': 1, '5': 9, '10': 'nextPageToken'},
  ],
};

/// Descriptor for `ListBlockedUsersResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listBlockedUsersResponseDescriptor = $convert.base64Decode(
    'ChhMaXN0QmxvY2tlZFVzZXJzUmVzcG9uc2USNAoFdXNlcnMYASADKAsyHi5kemVyb3RoLmdyYX'
    'BoLnYxLlVzZXJMaXN0SXRlbVIFdXNlcnMSJgoPbmV4dF9wYWdlX3Rva2VuGAIgASgJUg1uZXh0'
    'UGFnZVRva2Vu');

@$core.Deprecated('Use listMutedUsersRequestDescriptor instead')
const ListMutedUsersRequest$json = {
  '1': 'ListMutedUsersRequest',
  '2': [
    {'1': 'page_size', '3': 1, '4': 1, '5': 5, '10': 'pageSize'},
    {'1': 'page_token', '3': 2, '4': 1, '5': 9, '10': 'pageToken'},
  ],
};

/// Descriptor for `ListMutedUsersRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listMutedUsersRequestDescriptor = $convert.base64Decode(
    'ChVMaXN0TXV0ZWRVc2Vyc1JlcXVlc3QSGwoJcGFnZV9zaXplGAEgASgFUghwYWdlU2l6ZRIdCg'
    'pwYWdlX3Rva2VuGAIgASgJUglwYWdlVG9rZW4=');

@$core.Deprecated('Use listMutedUsersResponseDescriptor instead')
const ListMutedUsersResponse$json = {
  '1': 'ListMutedUsersResponse',
  '2': [
    {
      '1': 'users',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.graph.v1.UserListItem',
      '10': 'users'
    },
    {'1': 'next_page_token', '3': 2, '4': 1, '5': 9, '10': 'nextPageToken'},
  ],
};

/// Descriptor for `ListMutedUsersResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listMutedUsersResponseDescriptor = $convert.base64Decode(
    'ChZMaXN0TXV0ZWRVc2Vyc1Jlc3BvbnNlEjQKBXVzZXJzGAEgAygLMh4uZHplcm90aC5ncmFwaC'
    '52MS5Vc2VyTGlzdEl0ZW1SBXVzZXJzEiYKD25leHRfcGFnZV90b2tlbhgCIAEoCVINbmV4dFBh'
    'Z2VUb2tlbg==');

const $core.Map<$core.String, $core.dynamic> GraphServiceBase$json = {
  '1': 'GraphService',
  '2': [
    {
      '1': 'Follow',
      '2': '.dzeroth.graph.v1.FollowRequest',
      '3': '.dzeroth.graph.v1.FollowResponse'
    },
    {
      '1': 'Unfollow',
      '2': '.dzeroth.graph.v1.UnfollowRequest',
      '3': '.dzeroth.graph.v1.UnfollowResponse'
    },
    {
      '1': 'ListFollowRequests',
      '2': '.dzeroth.graph.v1.ListFollowRequestsRequest',
      '3': '.dzeroth.graph.v1.ListFollowRequestsResponse',
      '4': {'34': 1},
    },
    {
      '1': 'RespondToFollowRequest',
      '2': '.dzeroth.graph.v1.RespondToFollowRequestRequest',
      '3': '.dzeroth.graph.v1.RespondToFollowRequestResponse'
    },
    {
      '1': 'Block',
      '2': '.dzeroth.graph.v1.BlockRequest',
      '3': '.dzeroth.graph.v1.BlockResponse'
    },
    {
      '1': 'Unblock',
      '2': '.dzeroth.graph.v1.UnblockRequest',
      '3': '.dzeroth.graph.v1.UnblockResponse'
    },
    {
      '1': 'Mute',
      '2': '.dzeroth.graph.v1.MuteRequest',
      '3': '.dzeroth.graph.v1.MuteResponse'
    },
    {
      '1': 'Unmute',
      '2': '.dzeroth.graph.v1.UnmuteRequest',
      '3': '.dzeroth.graph.v1.UnmuteResponse'
    },
    {
      '1': 'GetRelationships',
      '2': '.dzeroth.graph.v1.GetRelationshipsRequest',
      '3': '.dzeroth.graph.v1.GetRelationshipsResponse',
      '4': {'34': 1},
    },
    {
      '1': 'ListFollowers',
      '2': '.dzeroth.graph.v1.ListFollowersRequest',
      '3': '.dzeroth.graph.v1.ListFollowersResponse',
      '4': {'34': 1},
    },
    {
      '1': 'ListFollowing',
      '2': '.dzeroth.graph.v1.ListFollowingRequest',
      '3': '.dzeroth.graph.v1.ListFollowingResponse',
      '4': {'34': 1},
    },
    {
      '1': 'ListBlockedUsers',
      '2': '.dzeroth.graph.v1.ListBlockedUsersRequest',
      '3': '.dzeroth.graph.v1.ListBlockedUsersResponse',
      '4': {'34': 1},
    },
    {
      '1': 'ListMutedUsers',
      '2': '.dzeroth.graph.v1.ListMutedUsersRequest',
      '3': '.dzeroth.graph.v1.ListMutedUsersResponse',
      '4': {'34': 1},
    },
  ],
};

@$core.Deprecated('Use graphServiceDescriptor instead')
const $core.Map<$core.String, $core.Map<$core.String, $core.dynamic>>
    GraphServiceBase$messageJson = {
  '.dzeroth.graph.v1.FollowRequest': FollowRequest$json,
  '.dzeroth.graph.v1.FollowResponse': FollowResponse$json,
  '.dzeroth.graph.v1.Relationship': Relationship$json,
  '.dzeroth.graph.v1.UnfollowRequest': UnfollowRequest$json,
  '.dzeroth.graph.v1.UnfollowResponse': UnfollowResponse$json,
  '.dzeroth.graph.v1.ListFollowRequestsRequest': ListFollowRequestsRequest$json,
  '.dzeroth.graph.v1.ListFollowRequestsResponse':
      ListFollowRequestsResponse$json,
  '.dzeroth.graph.v1.UserListItem': UserListItem$json,
  '.dzeroth.common.v1.AuthorSnapshot': $0.AuthorSnapshot$json,
  '.google.protobuf.Timestamp': $1.Timestamp$json,
  '.dzeroth.graph.v1.RespondToFollowRequestRequest':
      RespondToFollowRequestRequest$json,
  '.dzeroth.graph.v1.RespondToFollowRequestResponse':
      RespondToFollowRequestResponse$json,
  '.dzeroth.graph.v1.BlockRequest': BlockRequest$json,
  '.dzeroth.graph.v1.BlockResponse': BlockResponse$json,
  '.dzeroth.graph.v1.UnblockRequest': UnblockRequest$json,
  '.dzeroth.graph.v1.UnblockResponse': UnblockResponse$json,
  '.dzeroth.graph.v1.MuteRequest': MuteRequest$json,
  '.dzeroth.graph.v1.MuteResponse': MuteResponse$json,
  '.dzeroth.graph.v1.UnmuteRequest': UnmuteRequest$json,
  '.dzeroth.graph.v1.UnmuteResponse': UnmuteResponse$json,
  '.dzeroth.graph.v1.GetRelationshipsRequest': GetRelationshipsRequest$json,
  '.dzeroth.graph.v1.GetRelationshipsResponse': GetRelationshipsResponse$json,
  '.dzeroth.graph.v1.ListFollowersRequest': ListFollowersRequest$json,
  '.dzeroth.graph.v1.ListFollowersResponse': ListFollowersResponse$json,
  '.dzeroth.graph.v1.ListFollowingRequest': ListFollowingRequest$json,
  '.dzeroth.graph.v1.ListFollowingResponse': ListFollowingResponse$json,
  '.dzeroth.graph.v1.ListBlockedUsersRequest': ListBlockedUsersRequest$json,
  '.dzeroth.graph.v1.ListBlockedUsersResponse': ListBlockedUsersResponse$json,
  '.dzeroth.graph.v1.ListMutedUsersRequest': ListMutedUsersRequest$json,
  '.dzeroth.graph.v1.ListMutedUsersResponse': ListMutedUsersResponse$json,
};

/// Descriptor for `GraphService`. Decode as a `google.protobuf.ServiceDescriptorProto`.
final $typed_data.Uint8List graphServiceDescriptor = $convert.base64Decode(
    'CgxHcmFwaFNlcnZpY2USSwoGRm9sbG93Eh8uZHplcm90aC5ncmFwaC52MS5Gb2xsb3dSZXF1ZX'
    'N0GiAuZHplcm90aC5ncmFwaC52MS5Gb2xsb3dSZXNwb25zZRJRCghVbmZvbGxvdxIhLmR6ZXJv'
    'dGguZ3JhcGgudjEuVW5mb2xsb3dSZXF1ZXN0GiIuZHplcm90aC5ncmFwaC52MS5VbmZvbGxvd1'
    'Jlc3BvbnNlEnQKEkxpc3RGb2xsb3dSZXF1ZXN0cxIrLmR6ZXJvdGguZ3JhcGgudjEuTGlzdEZv'
    'bGxvd1JlcXVlc3RzUmVxdWVzdBosLmR6ZXJvdGguZ3JhcGgudjEuTGlzdEZvbGxvd1JlcXVlc3'
    'RzUmVzcG9uc2UiA5ACARJ7ChZSZXNwb25kVG9Gb2xsb3dSZXF1ZXN0Ei8uZHplcm90aC5ncmFw'
    'aC52MS5SZXNwb25kVG9Gb2xsb3dSZXF1ZXN0UmVxdWVzdBowLmR6ZXJvdGguZ3JhcGgudjEuUm'
    'VzcG9uZFRvRm9sbG93UmVxdWVzdFJlc3BvbnNlEkgKBUJsb2NrEh4uZHplcm90aC5ncmFwaC52'
    'MS5CbG9ja1JlcXVlc3QaHy5kemVyb3RoLmdyYXBoLnYxLkJsb2NrUmVzcG9uc2USTgoHVW5ibG'
    '9jaxIgLmR6ZXJvdGguZ3JhcGgudjEuVW5ibG9ja1JlcXVlc3QaIS5kemVyb3RoLmdyYXBoLnYx'
    'LlVuYmxvY2tSZXNwb25zZRJFCgRNdXRlEh0uZHplcm90aC5ncmFwaC52MS5NdXRlUmVxdWVzdB'
    'oeLmR6ZXJvdGguZ3JhcGgudjEuTXV0ZVJlc3BvbnNlEksKBlVubXV0ZRIfLmR6ZXJvdGguZ3Jh'
    'cGgudjEuVW5tdXRlUmVxdWVzdBogLmR6ZXJvdGguZ3JhcGgudjEuVW5tdXRlUmVzcG9uc2USbg'
    'oQR2V0UmVsYXRpb25zaGlwcxIpLmR6ZXJvdGguZ3JhcGgudjEuR2V0UmVsYXRpb25zaGlwc1Jl'
    'cXVlc3QaKi5kemVyb3RoLmdyYXBoLnYxLkdldFJlbGF0aW9uc2hpcHNSZXNwb25zZSIDkAIBEm'
    'UKDUxpc3RGb2xsb3dlcnMSJi5kemVyb3RoLmdyYXBoLnYxLkxpc3RGb2xsb3dlcnNSZXF1ZXN0'
    'GicuZHplcm90aC5ncmFwaC52MS5MaXN0Rm9sbG93ZXJzUmVzcG9uc2UiA5ACARJlCg1MaXN0Rm'
    '9sbG93aW5nEiYuZHplcm90aC5ncmFwaC52MS5MaXN0Rm9sbG93aW5nUmVxdWVzdBonLmR6ZXJv'
    'dGguZ3JhcGgudjEuTGlzdEZvbGxvd2luZ1Jlc3BvbnNlIgOQAgESbgoQTGlzdEJsb2NrZWRVc2'
    'VycxIpLmR6ZXJvdGguZ3JhcGgudjEuTGlzdEJsb2NrZWRVc2Vyc1JlcXVlc3QaKi5kemVyb3Ro'
    'LmdyYXBoLnYxLkxpc3RCbG9ja2VkVXNlcnNSZXNwb25zZSIDkAIBEmgKDkxpc3RNdXRlZFVzZX'
    'JzEicuZHplcm90aC5ncmFwaC52MS5MaXN0TXV0ZWRVc2Vyc1JlcXVlc3QaKC5kemVyb3RoLmdy'
    'YXBoLnYxLkxpc3RNdXRlZFVzZXJzUmVzcG9uc2UiA5ACAQ==');
