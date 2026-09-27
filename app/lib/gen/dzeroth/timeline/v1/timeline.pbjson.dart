// This is a generated file - do not edit.
//
// Generated from dzeroth/timeline/v1/timeline.proto.

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
    as $2;

import '../../common/v1/common.pbjson.dart' as $1;
import '../../posts/v1/posts.pbjson.dart' as $0;

@$core.Deprecated('Use getHomeTimelineRequestDescriptor instead')
const GetHomeTimelineRequest$json = {
  '1': 'GetHomeTimelineRequest',
  '2': [
    {'1': 'page_size', '3': 1, '4': 1, '5': 5, '10': 'pageSize'},
    {'1': 'page_token', '3': 2, '4': 1, '5': 9, '10': 'pageToken'},
    {'1': 'since_token', '3': 3, '4': 1, '5': 9, '10': 'sinceToken'},
  ],
};

/// Descriptor for `GetHomeTimelineRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getHomeTimelineRequestDescriptor = $convert.base64Decode(
    'ChZHZXRIb21lVGltZWxpbmVSZXF1ZXN0EhsKCXBhZ2Vfc2l6ZRgBIAEoBVIIcGFnZVNpemUSHQ'
    'oKcGFnZV90b2tlbhgCIAEoCVIJcGFnZVRva2VuEh8KC3NpbmNlX3Rva2VuGAMgASgJUgpzaW5j'
    'ZVRva2Vu');

@$core.Deprecated('Use getHomeTimelineResponseDescriptor instead')
const GetHomeTimelineResponse$json = {
  '1': 'GetHomeTimelineResponse',
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
    {'1': 'since_token', '3': 3, '4': 1, '5': 9, '10': 'sinceToken'},
    {'1': 'gap_page_token', '3': 4, '4': 1, '5': 9, '10': 'gapPageToken'},
  ],
};

/// Descriptor for `GetHomeTimelineResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getHomeTimelineResponseDescriptor = $convert.base64Decode(
    'ChdHZXRIb21lVGltZWxpbmVSZXNwb25zZRIwCgVwb3N0cxgBIAMoCzIaLmR6ZXJvdGgucG9zdH'
    'MudjEuUG9zdFZpZXdSBXBvc3RzEiYKD25leHRfcGFnZV90b2tlbhgCIAEoCVINbmV4dFBhZ2VU'
    'b2tlbhIfCgtzaW5jZV90b2tlbhgDIAEoCVIKc2luY2VUb2tlbhIkCg5nYXBfcGFnZV90b2tlbh'
    'gEIAEoCVIMZ2FwUGFnZVRva2Vu');

@$core.Deprecated('Use getUserTimelineRequestDescriptor instead')
const GetUserTimelineRequest$json = {
  '1': 'GetUserTimelineRequest',
  '2': [
    {'1': 'user_id', '3': 1, '4': 1, '5': 9, '10': 'userId'},
    {'1': 'include_replies', '3': 2, '4': 1, '5': 8, '10': 'includeReplies'},
    {'1': 'page_size', '3': 3, '4': 1, '5': 5, '10': 'pageSize'},
    {'1': 'page_token', '3': 4, '4': 1, '5': 9, '10': 'pageToken'},
    {'1': 'since_token', '3': 5, '4': 1, '5': 9, '10': 'sinceToken'},
  ],
};

/// Descriptor for `GetUserTimelineRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getUserTimelineRequestDescriptor = $convert.base64Decode(
    'ChZHZXRVc2VyVGltZWxpbmVSZXF1ZXN0EhcKB3VzZXJfaWQYASABKAlSBnVzZXJJZBInCg9pbm'
    'NsdWRlX3JlcGxpZXMYAiABKAhSDmluY2x1ZGVSZXBsaWVzEhsKCXBhZ2Vfc2l6ZRgDIAEoBVII'
    'cGFnZVNpemUSHQoKcGFnZV90b2tlbhgEIAEoCVIJcGFnZVRva2VuEh8KC3NpbmNlX3Rva2VuGA'
    'UgASgJUgpzaW5jZVRva2Vu');

@$core.Deprecated('Use getUserTimelineResponseDescriptor instead')
const GetUserTimelineResponse$json = {
  '1': 'GetUserTimelineResponse',
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
    {'1': 'since_token', '3': 3, '4': 1, '5': 9, '10': 'sinceToken'},
    {'1': 'gap_page_token', '3': 4, '4': 1, '5': 9, '10': 'gapPageToken'},
  ],
};

/// Descriptor for `GetUserTimelineResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getUserTimelineResponseDescriptor = $convert.base64Decode(
    'ChdHZXRVc2VyVGltZWxpbmVSZXNwb25zZRIwCgVwb3N0cxgBIAMoCzIaLmR6ZXJvdGgucG9zdH'
    'MudjEuUG9zdFZpZXdSBXBvc3RzEiYKD25leHRfcGFnZV90b2tlbhgCIAEoCVINbmV4dFBhZ2VU'
    'b2tlbhIfCgtzaW5jZV90b2tlbhgDIAEoCVIKc2luY2VUb2tlbhIkCg5nYXBfcGFnZV90b2tlbh'
    'gEIAEoCVIMZ2FwUGFnZVRva2Vu');

const $core.Map<$core.String, $core.dynamic> TimelineServiceBase$json = {
  '1': 'TimelineService',
  '2': [
    {
      '1': 'GetHomeTimeline',
      '2': '.dzeroth.timeline.v1.GetHomeTimelineRequest',
      '3': '.dzeroth.timeline.v1.GetHomeTimelineResponse',
      '4': {'34': 1},
    },
    {
      '1': 'GetUserTimeline',
      '2': '.dzeroth.timeline.v1.GetUserTimelineRequest',
      '3': '.dzeroth.timeline.v1.GetUserTimelineResponse',
      '4': {'34': 1},
    },
  ],
};

@$core.Deprecated('Use timelineServiceDescriptor instead')
const $core.Map<$core.String, $core.Map<$core.String, $core.dynamic>>
    TimelineServiceBase$messageJson = {
  '.dzeroth.timeline.v1.GetHomeTimelineRequest': GetHomeTimelineRequest$json,
  '.dzeroth.timeline.v1.GetHomeTimelineResponse': GetHomeTimelineResponse$json,
  '.dzeroth.posts.v1.PostView': $0.PostView$json,
  '.dzeroth.posts.v1.Post': $0.Post$json,
  '.dzeroth.common.v1.AuthorSnapshot': $1.AuthorSnapshot$json,
  '.dzeroth.common.v1.MediaRef': $1.MediaRef$json,
  '.dzeroth.posts.v1.EmbeddedPost': $0.EmbeddedPost$json,
  '.google.protobuf.Timestamp': $2.Timestamp$json,
  '.dzeroth.posts.v1.Mention': $0.Mention$json,
  '.dzeroth.timeline.v1.GetUserTimelineRequest': GetUserTimelineRequest$json,
  '.dzeroth.timeline.v1.GetUserTimelineResponse': GetUserTimelineResponse$json,
};

/// Descriptor for `TimelineService`. Decode as a `google.protobuf.ServiceDescriptorProto`.
final $typed_data.Uint8List timelineServiceDescriptor = $convert.base64Decode(
    'Cg9UaW1lbGluZVNlcnZpY2UScQoPR2V0SG9tZVRpbWVsaW5lEisuZHplcm90aC50aW1lbGluZS'
    '52MS5HZXRIb21lVGltZWxpbmVSZXF1ZXN0GiwuZHplcm90aC50aW1lbGluZS52MS5HZXRIb21l'
    'VGltZWxpbmVSZXNwb25zZSIDkAIBEnEKD0dldFVzZXJUaW1lbGluZRIrLmR6ZXJvdGgudGltZW'
    'xpbmUudjEuR2V0VXNlclRpbWVsaW5lUmVxdWVzdBosLmR6ZXJvdGgudGltZWxpbmUudjEuR2V0'
    'VXNlclRpbWVsaW5lUmVzcG9uc2UiA5ACAQ==');
