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
    as $3;

import '../../common/v1/common.pbjson.dart' as $2;
import '../../lists/v1/lists.pbjson.dart' as $1;
import '../../posts/v1/posts.pbjson.dart' as $0;

@$core.Deprecated('Use userTimelineTabDescriptor instead')
const UserTimelineTab$json = {
  '1': 'UserTimelineTab',
  '2': [
    {'1': 'USER_TIMELINE_TAB_UNSPECIFIED', '2': 0},
    {'1': 'USER_TIMELINE_TAB_POSTS', '2': 1},
    {'1': 'USER_TIMELINE_TAB_REPLIES', '2': 2},
    {'1': 'USER_TIMELINE_TAB_MEDIA', '2': 3},
    {'1': 'USER_TIMELINE_TAB_REPOSTS', '2': 4},
  ],
};

/// Descriptor for `UserTimelineTab`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List userTimelineTabDescriptor = $convert.base64Decode(
    'Cg9Vc2VyVGltZWxpbmVUYWISIQodVVNFUl9USU1FTElORV9UQUJfVU5TUEVDSUZJRUQQABIbCh'
    'dVU0VSX1RJTUVMSU5FX1RBQl9QT1NUUxABEh0KGVVTRVJfVElNRUxJTkVfVEFCX1JFUExJRVMQ'
    'AhIbChdVU0VSX1RJTUVMSU5FX1RBQl9NRURJQRADEh0KGVVTRVJfVElNRUxJTkVfVEFCX1JFUE'
    '9TVFMQBA==');

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
    {'1': 'removed_ids', '3': 5, '4': 3, '5': 9, '10': 'removedIds'},
  ],
};

/// Descriptor for `GetHomeTimelineResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getHomeTimelineResponseDescriptor = $convert.base64Decode(
    'ChdHZXRIb21lVGltZWxpbmVSZXNwb25zZRIwCgVwb3N0cxgBIAMoCzIaLmR6ZXJvdGgucG9zdH'
    'MudjEuUG9zdFZpZXdSBXBvc3RzEiYKD25leHRfcGFnZV90b2tlbhgCIAEoCVINbmV4dFBhZ2VU'
    'b2tlbhIfCgtzaW5jZV90b2tlbhgDIAEoCVIKc2luY2VUb2tlbhIkCg5nYXBfcGFnZV90b2tlbh'
    'gEIAEoCVIMZ2FwUGFnZVRva2VuEh8KC3JlbW92ZWRfaWRzGAUgAygJUgpyZW1vdmVkSWRz');

@$core.Deprecated('Use getUserTimelineRequestDescriptor instead')
const GetUserTimelineRequest$json = {
  '1': 'GetUserTimelineRequest',
  '2': [
    {'1': 'user_id', '3': 1, '4': 1, '5': 9, '10': 'userId'},
    {'1': 'include_replies', '3': 2, '4': 1, '5': 8, '10': 'includeReplies'},
    {'1': 'page_size', '3': 3, '4': 1, '5': 5, '10': 'pageSize'},
    {'1': 'page_token', '3': 4, '4': 1, '5': 9, '10': 'pageToken'},
    {'1': 'since_token', '3': 5, '4': 1, '5': 9, '10': 'sinceToken'},
    {
      '1': 'tab',
      '3': 6,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.timeline.v1.UserTimelineTab',
      '10': 'tab'
    },
  ],
};

/// Descriptor for `GetUserTimelineRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getUserTimelineRequestDescriptor = $convert.base64Decode(
    'ChZHZXRVc2VyVGltZWxpbmVSZXF1ZXN0EhcKB3VzZXJfaWQYASABKAlSBnVzZXJJZBInCg9pbm'
    'NsdWRlX3JlcGxpZXMYAiABKAhSDmluY2x1ZGVSZXBsaWVzEhsKCXBhZ2Vfc2l6ZRgDIAEoBVII'
    'cGFnZVNpemUSHQoKcGFnZV90b2tlbhgEIAEoCVIJcGFnZVRva2VuEh8KC3NpbmNlX3Rva2VuGA'
    'UgASgJUgpzaW5jZVRva2VuEjYKA3RhYhgGIAEoDjIkLmR6ZXJvdGgudGltZWxpbmUudjEuVXNl'
    'clRpbWVsaW5lVGFiUgN0YWI=');

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
    {'1': 'removed_ids', '3': 5, '4': 3, '5': 9, '10': 'removedIds'},
    {'1': 'author_protected', '3': 6, '4': 1, '5': 8, '10': 'authorProtected'},
  ],
};

/// Descriptor for `GetUserTimelineResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getUserTimelineResponseDescriptor = $convert.base64Decode(
    'ChdHZXRVc2VyVGltZWxpbmVSZXNwb25zZRIwCgVwb3N0cxgBIAMoCzIaLmR6ZXJvdGgucG9zdH'
    'MudjEuUG9zdFZpZXdSBXBvc3RzEiYKD25leHRfcGFnZV90b2tlbhgCIAEoCVINbmV4dFBhZ2VU'
    'b2tlbhIfCgtzaW5jZV90b2tlbhgDIAEoCVIKc2luY2VUb2tlbhIkCg5nYXBfcGFnZV90b2tlbh'
    'gEIAEoCVIMZ2FwUGFnZVRva2VuEh8KC3JlbW92ZWRfaWRzGAUgAygJUgpyZW1vdmVkSWRzEikK'
    'EGF1dGhvcl9wcm90ZWN0ZWQYBiABKAhSD2F1dGhvclByb3RlY3RlZA==');

@$core.Deprecated('Use getListTimelineRequestDescriptor instead')
const GetListTimelineRequest$json = {
  '1': 'GetListTimelineRequest',
  '2': [
    {'1': 'list_id', '3': 1, '4': 1, '5': 9, '10': 'listId'},
    {'1': 'page_size', '3': 2, '4': 1, '5': 5, '10': 'pageSize'},
    {'1': 'page_token', '3': 3, '4': 1, '5': 9, '10': 'pageToken'},
    {'1': 'since_token', '3': 4, '4': 1, '5': 9, '10': 'sinceToken'},
  ],
};

/// Descriptor for `GetListTimelineRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getListTimelineRequestDescriptor = $convert.base64Decode(
    'ChZHZXRMaXN0VGltZWxpbmVSZXF1ZXN0EhcKB2xpc3RfaWQYASABKAlSBmxpc3RJZBIbCglwYW'
    'dlX3NpemUYAiABKAVSCHBhZ2VTaXplEh0KCnBhZ2VfdG9rZW4YAyABKAlSCXBhZ2VUb2tlbhIf'
    'CgtzaW5jZV90b2tlbhgEIAEoCVIKc2luY2VUb2tlbg==');

@$core.Deprecated('Use getListTimelineResponseDescriptor instead')
const GetListTimelineResponse$json = {
  '1': 'GetListTimelineResponse',
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
    {'1': 'removed_ids', '3': 5, '4': 3, '5': 9, '10': 'removedIds'},
    {
      '1': 'list',
      '3': 6,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.lists.v1.ListInfo',
      '10': 'list'
    },
  ],
};

/// Descriptor for `GetListTimelineResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getListTimelineResponseDescriptor = $convert.base64Decode(
    'ChdHZXRMaXN0VGltZWxpbmVSZXNwb25zZRIwCgVwb3N0cxgBIAMoCzIaLmR6ZXJvdGgucG9zdH'
    'MudjEuUG9zdFZpZXdSBXBvc3RzEiYKD25leHRfcGFnZV90b2tlbhgCIAEoCVINbmV4dFBhZ2VU'
    'b2tlbhIfCgtzaW5jZV90b2tlbhgDIAEoCVIKc2luY2VUb2tlbhIkCg5nYXBfcGFnZV90b2tlbh'
    'gEIAEoCVIMZ2FwUGFnZVRva2VuEh8KC3JlbW92ZWRfaWRzGAUgAygJUgpyZW1vdmVkSWRzEi4K'
    'BGxpc3QYBiABKAsyGi5kemVyb3RoLmxpc3RzLnYxLkxpc3RJbmZvUgRsaXN0');

@$core.Deprecated('Use setHomeTabsRequestDescriptor instead')
const SetHomeTabsRequest$json = {
  '1': 'SetHomeTabsRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {
      '1': 'tabs',
      '3': 2,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.common.v1.HomeTab',
      '10': 'tabs'
    },
  ],
};

/// Descriptor for `SetHomeTabsRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List setHomeTabsRequestDescriptor = $convert.base64Decode(
    'ChJTZXRIb21lVGFic1JlcXVlc3QSJwoPaWRlbXBvdGVuY3lfa2V5GAEgASgJUg5pZGVtcG90ZW'
    '5jeUtleRIuCgR0YWJzGAIgAygLMhouZHplcm90aC5jb21tb24udjEuSG9tZVRhYlIEdGFicw==');

@$core.Deprecated('Use setHomeTabsResponseDescriptor instead')
const SetHomeTabsResponse$json = {
  '1': 'SetHomeTabsResponse',
  '2': [
    {
      '1': 'tabs',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.common.v1.HomeTab',
      '10': 'tabs'
    },
  ],
};

/// Descriptor for `SetHomeTabsResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List setHomeTabsResponseDescriptor = $convert.base64Decode(
    'ChNTZXRIb21lVGFic1Jlc3BvbnNlEi4KBHRhYnMYASADKAsyGi5kemVyb3RoLmNvbW1vbi52MS'
    '5Ib21lVGFiUgR0YWJz');

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
    {
      '1': 'GetListTimeline',
      '2': '.dzeroth.timeline.v1.GetListTimelineRequest',
      '3': '.dzeroth.timeline.v1.GetListTimelineResponse',
      '4': {'34': 1},
    },
    {
      '1': 'SetHomeTabs',
      '2': '.dzeroth.timeline.v1.SetHomeTabsRequest',
      '3': '.dzeroth.timeline.v1.SetHomeTabsResponse'
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
  '.dzeroth.common.v1.AuthorSnapshot': $2.AuthorSnapshot$json,
  '.dzeroth.common.v1.MediaRef': $2.MediaRef$json,
  '.dzeroth.posts.v1.EmbeddedPost': $0.EmbeddedPost$json,
  '.google.protobuf.Timestamp': $3.Timestamp$json,
  '.dzeroth.posts.v1.Poll': $0.Poll$json,
  '.dzeroth.posts.v1.PollChoice': $0.PollChoice$json,
  '.dzeroth.posts.v1.Mention': $0.Mention$json,
  '.dzeroth.timeline.v1.GetUserTimelineRequest': GetUserTimelineRequest$json,
  '.dzeroth.timeline.v1.GetUserTimelineResponse': GetUserTimelineResponse$json,
  '.dzeroth.timeline.v1.GetListTimelineRequest': GetListTimelineRequest$json,
  '.dzeroth.timeline.v1.GetListTimelineResponse': GetListTimelineResponse$json,
  '.dzeroth.lists.v1.ListInfo': $1.ListInfo$json,
  '.dzeroth.timeline.v1.SetHomeTabsRequest': SetHomeTabsRequest$json,
  '.dzeroth.common.v1.HomeTab': $2.HomeTab$json,
  '.dzeroth.timeline.v1.SetHomeTabsResponse': SetHomeTabsResponse$json,
};

/// Descriptor for `TimelineService`. Decode as a `google.protobuf.ServiceDescriptorProto`.
final $typed_data.Uint8List timelineServiceDescriptor = $convert.base64Decode(
    'Cg9UaW1lbGluZVNlcnZpY2UScQoPR2V0SG9tZVRpbWVsaW5lEisuZHplcm90aC50aW1lbGluZS'
    '52MS5HZXRIb21lVGltZWxpbmVSZXF1ZXN0GiwuZHplcm90aC50aW1lbGluZS52MS5HZXRIb21l'
    'VGltZWxpbmVSZXNwb25zZSIDkAIBEnEKD0dldFVzZXJUaW1lbGluZRIrLmR6ZXJvdGgudGltZW'
    'xpbmUudjEuR2V0VXNlclRpbWVsaW5lUmVxdWVzdBosLmR6ZXJvdGgudGltZWxpbmUudjEuR2V0'
    'VXNlclRpbWVsaW5lUmVzcG9uc2UiA5ACARJxCg9HZXRMaXN0VGltZWxpbmUSKy5kemVyb3RoLn'
    'RpbWVsaW5lLnYxLkdldExpc3RUaW1lbGluZVJlcXVlc3QaLC5kemVyb3RoLnRpbWVsaW5lLnYx'
    'LkdldExpc3RUaW1lbGluZVJlc3BvbnNlIgOQAgESYAoLU2V0SG9tZVRhYnMSJy5kemVyb3RoLn'
    'RpbWVsaW5lLnYxLlNldEhvbWVUYWJzUmVxdWVzdBooLmR6ZXJvdGgudGltZWxpbmUudjEuU2V0'
    'SG9tZVRhYnNSZXNwb25zZQ==');
