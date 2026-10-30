// This is a generated file - do not edit.
//
// Generated from dzeroth/search/v1/search.proto.

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

import '../../common/v1/common.pbjson.dart' as $3;
import '../../graph/v1/graph.pbjson.dart' as $0;
import '../../posts/v1/posts.pbjson.dart' as $1;

@$core.Deprecated('Use searchTabDescriptor instead')
const SearchTab$json = {
  '1': 'SearchTab',
  '2': [
    {'1': 'SEARCH_TAB_UNSPECIFIED', '2': 0},
    {'1': 'SEARCH_TAB_TOP', '2': 1},
    {'1': 'SEARCH_TAB_LATEST', '2': 2},
    {'1': 'SEARCH_TAB_MEDIA', '2': 3},
  ],
};

/// Descriptor for `SearchTab`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List searchTabDescriptor = $convert.base64Decode(
    'CglTZWFyY2hUYWISGgoWU0VBUkNIX1RBQl9VTlNQRUNJRklFRBAAEhIKDlNFQVJDSF9UQUJfVE'
    '9QEAESFQoRU0VBUkNIX1RBQl9MQVRFU1QQAhIUChBTRUFSQ0hfVEFCX01FRElBEAM=');

@$core.Deprecated('Use searchPeopleRequestDescriptor instead')
const SearchPeopleRequest$json = {
  '1': 'SearchPeopleRequest',
  '2': [
    {'1': 'query', '3': 1, '4': 1, '5': 9, '10': 'query'},
    {'1': 'limit', '3': 2, '4': 1, '5': 5, '10': 'limit'},
  ],
};

/// Descriptor for `SearchPeopleRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List searchPeopleRequestDescriptor = $convert.base64Decode(
    'ChNTZWFyY2hQZW9wbGVSZXF1ZXN0EhQKBXF1ZXJ5GAEgASgJUgVxdWVyeRIUCgVsaW1pdBgCIA'
    'EoBVIFbGltaXQ=');

@$core.Deprecated('Use searchPeopleResponseDescriptor instead')
const SearchPeopleResponse$json = {
  '1': 'SearchPeopleResponse',
  '2': [
    {
      '1': 'users',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.graph.v1.UserListItem',
      '10': 'users'
    },
    {
      '1': 'unsupported_query',
      '3': 2,
      '4': 1,
      '5': 8,
      '10': 'unsupportedQuery'
    },
  ],
};

/// Descriptor for `SearchPeopleResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List searchPeopleResponseDescriptor = $convert.base64Decode(
    'ChRTZWFyY2hQZW9wbGVSZXNwb25zZRI0CgV1c2VycxgBIAMoCzIeLmR6ZXJvdGguZ3JhcGgudj'
    'EuVXNlckxpc3RJdGVtUgV1c2VycxIrChF1bnN1cHBvcnRlZF9xdWVyeRgCIAEoCFIQdW5zdXBw'
    'b3J0ZWRRdWVyeQ==');

@$core.Deprecated('Use searchPostsRequestDescriptor instead')
const SearchPostsRequest$json = {
  '1': 'SearchPostsRequest',
  '2': [
    {'1': 'query', '3': 1, '4': 1, '5': 9, '10': 'query'},
    {
      '1': 'tab',
      '3': 2,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.search.v1.SearchTab',
      '10': 'tab'
    },
    {'1': 'page_size', '3': 3, '4': 1, '5': 5, '10': 'pageSize'},
    {'1': 'page_token', '3': 4, '4': 1, '5': 9, '10': 'pageToken'},
  ],
};

/// Descriptor for `SearchPostsRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List searchPostsRequestDescriptor = $convert.base64Decode(
    'ChJTZWFyY2hQb3N0c1JlcXVlc3QSFAoFcXVlcnkYASABKAlSBXF1ZXJ5Ei4KA3RhYhgCIAEoDj'
    'IcLmR6ZXJvdGguc2VhcmNoLnYxLlNlYXJjaFRhYlIDdGFiEhsKCXBhZ2Vfc2l6ZRgDIAEoBVII'
    'cGFnZVNpemUSHQoKcGFnZV90b2tlbhgEIAEoCVIJcGFnZVRva2Vu');

@$core.Deprecated('Use searchPostsResponseDescriptor instead')
const SearchPostsResponse$json = {
  '1': 'SearchPostsResponse',
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
    {'1': 'normalized_tag', '3': 3, '4': 1, '5': 9, '10': 'normalizedTag'},
    {
      '1': 'unsupported_query',
      '3': 4,
      '4': 1,
      '5': 8,
      '10': 'unsupportedQuery'
    },
  ],
};

/// Descriptor for `SearchPostsResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List searchPostsResponseDescriptor = $convert.base64Decode(
    'ChNTZWFyY2hQb3N0c1Jlc3BvbnNlEjAKBXBvc3RzGAEgAygLMhouZHplcm90aC5wb3N0cy52MS'
    '5Qb3N0Vmlld1IFcG9zdHMSJgoPbmV4dF9wYWdlX3Rva2VuGAIgASgJUg1uZXh0UGFnZVRva2Vu'
    'EiUKDm5vcm1hbGl6ZWRfdGFnGAMgASgJUg1ub3JtYWxpemVkVGFnEisKEXVuc3VwcG9ydGVkX3'
    'F1ZXJ5GAQgASgIUhB1bnN1cHBvcnRlZFF1ZXJ5');

@$core.Deprecated('Use getTrendsRequestDescriptor instead')
const GetTrendsRequest$json = {
  '1': 'GetTrendsRequest',
  '2': [
    {'1': 'limit', '3': 1, '4': 1, '5': 5, '10': 'limit'},
    {'1': 'prefix', '3': 2, '4': 1, '5': 9, '10': 'prefix'},
  ],
};

/// Descriptor for `GetTrendsRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getTrendsRequestDescriptor = $convert.base64Decode(
    'ChBHZXRUcmVuZHNSZXF1ZXN0EhQKBWxpbWl0GAEgASgFUgVsaW1pdBIWCgZwcmVmaXgYAiABKA'
    'lSBnByZWZpeA==');

@$core.Deprecated('Use trendDescriptor instead')
const Trend$json = {
  '1': 'Trend',
  '2': [
    {'1': 'tag', '3': 1, '4': 1, '5': 9, '10': 'tag'},
    {'1': 'post_count', '3': 2, '4': 1, '5': 3, '10': 'postCount'},
    {'1': 'rank', '3': 3, '4': 1, '5': 5, '10': 'rank'},
  ],
};

/// Descriptor for `Trend`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List trendDescriptor = $convert.base64Decode(
    'CgVUcmVuZBIQCgN0YWcYASABKAlSA3RhZxIdCgpwb3N0X2NvdW50GAIgASgDUglwb3N0Q291bn'
    'QSEgoEcmFuaxgDIAEoBVIEcmFuaw==');

@$core.Deprecated('Use getTrendsResponseDescriptor instead')
const GetTrendsResponse$json = {
  '1': 'GetTrendsResponse',
  '2': [
    {
      '1': 'trends',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.search.v1.Trend',
      '10': 'trends'
    },
    {
      '1': 'computed_at',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '10': 'computedAt'
    },
  ],
};

/// Descriptor for `GetTrendsResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getTrendsResponseDescriptor = $convert.base64Decode(
    'ChFHZXRUcmVuZHNSZXNwb25zZRIwCgZ0cmVuZHMYASADKAsyGC5kemVyb3RoLnNlYXJjaC52MS'
    '5UcmVuZFIGdHJlbmRzEjsKC2NvbXB1dGVkX2F0GAIgASgLMhouZ29vZ2xlLnByb3RvYnVmLlRp'
    'bWVzdGFtcFIKY29tcHV0ZWRBdA==');

const $core.Map<$core.String, $core.dynamic> SearchServiceBase$json = {
  '1': 'SearchService',
  '2': [
    {
      '1': 'SearchPeople',
      '2': '.dzeroth.search.v1.SearchPeopleRequest',
      '3': '.dzeroth.search.v1.SearchPeopleResponse',
      '4': {'34': 1},
    },
    {
      '1': 'SearchPosts',
      '2': '.dzeroth.search.v1.SearchPostsRequest',
      '3': '.dzeroth.search.v1.SearchPostsResponse',
      '4': {'34': 1},
    },
    {
      '1': 'GetTrends',
      '2': '.dzeroth.search.v1.GetTrendsRequest',
      '3': '.dzeroth.search.v1.GetTrendsResponse',
      '4': {'34': 1},
    },
  ],
};

@$core.Deprecated('Use searchServiceDescriptor instead')
const $core.Map<$core.String, $core.Map<$core.String, $core.dynamic>>
    SearchServiceBase$messageJson = {
  '.dzeroth.search.v1.SearchPeopleRequest': SearchPeopleRequest$json,
  '.dzeroth.search.v1.SearchPeopleResponse': SearchPeopleResponse$json,
  '.dzeroth.graph.v1.UserListItem': $0.UserListItem$json,
  '.dzeroth.common.v1.AuthorSnapshot': $3.AuthorSnapshot$json,
  '.google.protobuf.Timestamp': $2.Timestamp$json,
  '.dzeroth.graph.v1.Relationship': $0.Relationship$json,
  '.dzeroth.search.v1.SearchPostsRequest': SearchPostsRequest$json,
  '.dzeroth.search.v1.SearchPostsResponse': SearchPostsResponse$json,
  '.dzeroth.posts.v1.PostView': $1.PostView$json,
  '.dzeroth.posts.v1.Post': $1.Post$json,
  '.dzeroth.common.v1.MediaRef': $3.MediaRef$json,
  '.dzeroth.posts.v1.EmbeddedPost': $1.EmbeddedPost$json,
  '.dzeroth.posts.v1.Poll': $1.Poll$json,
  '.dzeroth.posts.v1.PollChoice': $1.PollChoice$json,
  '.dzeroth.posts.v1.Mention': $1.Mention$json,
  '.dzeroth.search.v1.GetTrendsRequest': GetTrendsRequest$json,
  '.dzeroth.search.v1.GetTrendsResponse': GetTrendsResponse$json,
  '.dzeroth.search.v1.Trend': Trend$json,
};

/// Descriptor for `SearchService`. Decode as a `google.protobuf.ServiceDescriptorProto`.
final $typed_data.Uint8List searchServiceDescriptor = $convert.base64Decode(
    'Cg1TZWFyY2hTZXJ2aWNlEmQKDFNlYXJjaFBlb3BsZRImLmR6ZXJvdGguc2VhcmNoLnYxLlNlYX'
    'JjaFBlb3BsZVJlcXVlc3QaJy5kemVyb3RoLnNlYXJjaC52MS5TZWFyY2hQZW9wbGVSZXNwb25z'
    'ZSIDkAIBEmEKC1NlYXJjaFBvc3RzEiUuZHplcm90aC5zZWFyY2gudjEuU2VhcmNoUG9zdHNSZX'
    'F1ZXN0GiYuZHplcm90aC5zZWFyY2gudjEuU2VhcmNoUG9zdHNSZXNwb25zZSIDkAIBElsKCUdl'
    'dFRyZW5kcxIjLmR6ZXJvdGguc2VhcmNoLnYxLkdldFRyZW5kc1JlcXVlc3QaJC5kemVyb3RoLn'
    'NlYXJjaC52MS5HZXRUcmVuZHNSZXNwb25zZSIDkAIB');
