// This is a generated file - do not edit.
//
// Generated from dzeroth/articles/v1/articles.proto.

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

import '../../common/v1/common.pbjson.dart' as $2;
import '../../posts/v1/posts.pbjson.dart' as $1;

@$core.Deprecated('Use articleDescriptor instead')
const Article$json = {
  '1': 'Article',
  '2': [
    {'1': 'article_id', '3': 1, '4': 1, '5': 9, '10': 'articleId'},
    {'1': 'author_id', '3': 2, '4': 1, '5': 9, '10': 'authorId'},
    {'1': 'revision', '3': 3, '4': 1, '5': 3, '10': 'revision'},
    {'1': 'title', '3': 4, '4': 1, '5': 9, '10': 'title'},
    {'1': 'body_json', '3': 5, '4': 1, '5': 9, '10': 'bodyJson'},
    {'1': 'cover_media_id', '3': 6, '4': 1, '5': 9, '10': 'coverMediaId'},
    {'1': 'post_id', '3': 7, '4': 1, '5': 9, '10': 'postId'},
    {
      '1': 'updated_at',
      '3': 8,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '10': 'updatedAt'
    },
    {'1': 'cover_url', '3': 9, '4': 1, '5': 9, '10': 'coverUrl'},
    {
      '1': 'publication_pending',
      '3': 10,
      '4': 1,
      '5': 8,
      '10': 'publicationPending'
    },
    {
      '1': 'publication_caption',
      '3': 11,
      '4': 1,
      '5': 9,
      '10': 'publicationCaption'
    },
    {
      '1': 'publication_reply_policy',
      '3': 12,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.posts.v1.ReplyPolicy',
      '10': 'publicationReplyPolicy'
    },
    {'1': 'excerpt', '3': 13, '4': 1, '5': 9, '10': 'excerpt'},
  ],
};

/// Descriptor for `Article`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List articleDescriptor = $convert.base64Decode(
    'CgdBcnRpY2xlEh0KCmFydGljbGVfaWQYASABKAlSCWFydGljbGVJZBIbCglhdXRob3JfaWQYAi'
    'ABKAlSCGF1dGhvcklkEhoKCHJldmlzaW9uGAMgASgDUghyZXZpc2lvbhIUCgV0aXRsZRgEIAEo'
    'CVIFdGl0bGUSGwoJYm9keV9qc29uGAUgASgJUghib2R5SnNvbhIkCg5jb3Zlcl9tZWRpYV9pZB'
    'gGIAEoCVIMY292ZXJNZWRpYUlkEhcKB3Bvc3RfaWQYByABKAlSBnBvc3RJZBI5Cgp1cGRhdGVk'
    'X2F0GAggASgLMhouZ29vZ2xlLnByb3RvYnVmLlRpbWVzdGFtcFIJdXBkYXRlZEF0EhsKCWNvdm'
    'VyX3VybBgJIAEoCVIIY292ZXJVcmwSLwoTcHVibGljYXRpb25fcGVuZGluZxgKIAEoCFIScHVi'
    'bGljYXRpb25QZW5kaW5nEi8KE3B1YmxpY2F0aW9uX2NhcHRpb24YCyABKAlSEnB1YmxpY2F0aW'
    '9uQ2FwdGlvbhJXChhwdWJsaWNhdGlvbl9yZXBseV9wb2xpY3kYDCABKA4yHS5kemVyb3RoLnBv'
    'c3RzLnYxLlJlcGx5UG9saWN5UhZwdWJsaWNhdGlvblJlcGx5UG9saWN5EhgKB2V4Y2VycHQYDS'
    'ABKAlSB2V4Y2VycHQ=');

@$core.Deprecated('Use getArticleRequestDescriptor instead')
const GetArticleRequest$json = {
  '1': 'GetArticleRequest',
  '2': [
    {'1': 'article_id', '3': 1, '4': 1, '5': 9, '10': 'articleId'},
  ],
};

/// Descriptor for `GetArticleRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getArticleRequestDescriptor = $convert.base64Decode(
    'ChFHZXRBcnRpY2xlUmVxdWVzdBIdCgphcnRpY2xlX2lkGAEgASgJUglhcnRpY2xlSWQ=');

@$core.Deprecated('Use getArticleResponseDescriptor instead')
const GetArticleResponse$json = {
  '1': 'GetArticleResponse',
  '2': [
    {
      '1': 'article',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.articles.v1.Article',
      '10': 'article'
    },
    {
      '1': 'post',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.posts.v1.PostView',
      '10': 'post'
    },
  ],
};

/// Descriptor for `GetArticleResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getArticleResponseDescriptor = $convert.base64Decode(
    'ChJHZXRBcnRpY2xlUmVzcG9uc2USNgoHYXJ0aWNsZRgBIAEoCzIcLmR6ZXJvdGguYXJ0aWNsZX'
    'MudjEuQXJ0aWNsZVIHYXJ0aWNsZRIuCgRwb3N0GAIgASgLMhouZHplcm90aC5wb3N0cy52MS5Q'
    'b3N0Vmlld1IEcG9zdA==');

@$core.Deprecated('Use listArticlesRequestDescriptor instead')
const ListArticlesRequest$json = {
  '1': 'ListArticlesRequest',
  '2': [
    {'1': 'published', '3': 1, '4': 1, '5': 8, '10': 'published'},
    {'1': 'page_size', '3': 2, '4': 1, '5': 5, '10': 'pageSize'},
    {'1': 'page_token', '3': 3, '4': 1, '5': 9, '10': 'pageToken'},
  ],
};

/// Descriptor for `ListArticlesRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listArticlesRequestDescriptor = $convert.base64Decode(
    'ChNMaXN0QXJ0aWNsZXNSZXF1ZXN0EhwKCXB1Ymxpc2hlZBgBIAEoCFIJcHVibGlzaGVkEhsKCX'
    'BhZ2Vfc2l6ZRgCIAEoBVIIcGFnZVNpemUSHQoKcGFnZV90b2tlbhgDIAEoCVIJcGFnZVRva2Vu');

@$core.Deprecated('Use listArticlesResponseDescriptor instead')
const ListArticlesResponse$json = {
  '1': 'ListArticlesResponse',
  '2': [
    {
      '1': 'articles',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.articles.v1.Article',
      '10': 'articles'
    },
    {'1': 'next_page_token', '3': 2, '4': 1, '5': 9, '10': 'nextPageToken'},
  ],
};

/// Descriptor for `ListArticlesResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listArticlesResponseDescriptor = $convert.base64Decode(
    'ChRMaXN0QXJ0aWNsZXNSZXNwb25zZRI4CghhcnRpY2xlcxgBIAMoCzIcLmR6ZXJvdGguYXJ0aW'
    'NsZXMudjEuQXJ0aWNsZVIIYXJ0aWNsZXMSJgoPbmV4dF9wYWdlX3Rva2VuGAIgASgJUg1uZXh0'
    'UGFnZVRva2Vu');

@$core.Deprecated('Use saveArticleRequestDescriptor instead')
const SaveArticleRequest$json = {
  '1': 'SaveArticleRequest',
  '2': [
    {
      '1': 'article',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.articles.v1.Article',
      '10': 'article'
    },
    {
      '1': 'expected_revision',
      '3': 2,
      '4': 1,
      '5': 3,
      '10': 'expectedRevision'
    },
  ],
};

/// Descriptor for `SaveArticleRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List saveArticleRequestDescriptor = $convert.base64Decode(
    'ChJTYXZlQXJ0aWNsZVJlcXVlc3QSNgoHYXJ0aWNsZRgBIAEoCzIcLmR6ZXJvdGguYXJ0aWNsZX'
    'MudjEuQXJ0aWNsZVIHYXJ0aWNsZRIrChFleHBlY3RlZF9yZXZpc2lvbhgCIAEoA1IQZXhwZWN0'
    'ZWRSZXZpc2lvbg==');

@$core.Deprecated('Use saveArticleResponseDescriptor instead')
const SaveArticleResponse$json = {
  '1': 'SaveArticleResponse',
  '2': [
    {
      '1': 'article',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.articles.v1.Article',
      '10': 'article'
    },
  ],
};

/// Descriptor for `SaveArticleResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List saveArticleResponseDescriptor = $convert.base64Decode(
    'ChNTYXZlQXJ0aWNsZVJlc3BvbnNlEjYKB2FydGljbGUYASABKAsyHC5kemVyb3RoLmFydGljbG'
    'VzLnYxLkFydGljbGVSB2FydGljbGU=');

@$core.Deprecated('Use deleteArticleRequestDescriptor instead')
const DeleteArticleRequest$json = {
  '1': 'DeleteArticleRequest',
  '2': [
    {'1': 'article_id', '3': 1, '4': 1, '5': 9, '10': 'articleId'},
    {
      '1': 'expected_revision',
      '3': 2,
      '4': 1,
      '5': 3,
      '10': 'expectedRevision'
    },
  ],
};

/// Descriptor for `DeleteArticleRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List deleteArticleRequestDescriptor = $convert.base64Decode(
    'ChREZWxldGVBcnRpY2xlUmVxdWVzdBIdCgphcnRpY2xlX2lkGAEgASgJUglhcnRpY2xlSWQSKw'
    'oRZXhwZWN0ZWRfcmV2aXNpb24YAiABKANSEGV4cGVjdGVkUmV2aXNpb24=');

@$core.Deprecated('Use deleteArticleResponseDescriptor instead')
const DeleteArticleResponse$json = {
  '1': 'DeleteArticleResponse',
};

/// Descriptor for `DeleteArticleResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List deleteArticleResponseDescriptor =
    $convert.base64Decode('ChVEZWxldGVBcnRpY2xlUmVzcG9uc2U=');

@$core.Deprecated('Use publishArticleRequestDescriptor instead')
const PublishArticleRequest$json = {
  '1': 'PublishArticleRequest',
  '2': [
    {'1': 'article_id', '3': 1, '4': 1, '5': 9, '10': 'articleId'},
    {
      '1': 'expected_revision',
      '3': 2,
      '4': 1,
      '5': 3,
      '10': 'expectedRevision'
    },
    {'1': 'idempotency_key', '3': 3, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'caption', '3': 4, '4': 1, '5': 9, '10': 'caption'},
    {
      '1': 'reply_policy',
      '3': 5,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.posts.v1.ReplyPolicy',
      '10': 'replyPolicy'
    },
  ],
};

/// Descriptor for `PublishArticleRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List publishArticleRequestDescriptor = $convert.base64Decode(
    'ChVQdWJsaXNoQXJ0aWNsZVJlcXVlc3QSHQoKYXJ0aWNsZV9pZBgBIAEoCVIJYXJ0aWNsZUlkEi'
    'sKEWV4cGVjdGVkX3JldmlzaW9uGAIgASgDUhBleHBlY3RlZFJldmlzaW9uEicKD2lkZW1wb3Rl'
    'bmN5X2tleRgDIAEoCVIOaWRlbXBvdGVuY3lLZXkSGAoHY2FwdGlvbhgEIAEoCVIHY2FwdGlvbh'
    'JACgxyZXBseV9wb2xpY3kYBSABKA4yHS5kemVyb3RoLnBvc3RzLnYxLlJlcGx5UG9saWN5Ugty'
    'ZXBseVBvbGljeQ==');

@$core.Deprecated('Use publishArticleResponseDescriptor instead')
const PublishArticleResponse$json = {
  '1': 'PublishArticleResponse',
  '2': [
    {
      '1': 'article',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.articles.v1.Article',
      '10': 'article'
    },
    {
      '1': 'post',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.posts.v1.PostView',
      '10': 'post'
    },
  ],
};

/// Descriptor for `PublishArticleResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List publishArticleResponseDescriptor = $convert.base64Decode(
    'ChZQdWJsaXNoQXJ0aWNsZVJlc3BvbnNlEjYKB2FydGljbGUYASABKAsyHC5kemVyb3RoLmFydG'
    'ljbGVzLnYxLkFydGljbGVSB2FydGljbGUSLgoEcG9zdBgCIAEoCzIaLmR6ZXJvdGgucG9zdHMu'
    'djEuUG9zdFZpZXdSBHBvc3Q=');

const $core.Map<$core.String, $core.dynamic> ArticleServiceBase$json = {
  '1': 'ArticleService',
  '2': [
    {
      '1': 'GetArticle',
      '2': '.dzeroth.articles.v1.GetArticleRequest',
      '3': '.dzeroth.articles.v1.GetArticleResponse',
      '4': {'34': 1},
    },
    {
      '1': 'ListArticles',
      '2': '.dzeroth.articles.v1.ListArticlesRequest',
      '3': '.dzeroth.articles.v1.ListArticlesResponse',
      '4': {'34': 1},
    },
    {
      '1': 'SaveArticle',
      '2': '.dzeroth.articles.v1.SaveArticleRequest',
      '3': '.dzeroth.articles.v1.SaveArticleResponse'
    },
    {
      '1': 'DeleteArticle',
      '2': '.dzeroth.articles.v1.DeleteArticleRequest',
      '3': '.dzeroth.articles.v1.DeleteArticleResponse'
    },
    {
      '1': 'PublishArticle',
      '2': '.dzeroth.articles.v1.PublishArticleRequest',
      '3': '.dzeroth.articles.v1.PublishArticleResponse'
    },
  ],
};

@$core.Deprecated('Use articleServiceDescriptor instead')
const $core.Map<$core.String, $core.Map<$core.String, $core.dynamic>>
    ArticleServiceBase$messageJson = {
  '.dzeroth.articles.v1.GetArticleRequest': GetArticleRequest$json,
  '.dzeroth.articles.v1.GetArticleResponse': GetArticleResponse$json,
  '.dzeroth.articles.v1.Article': Article$json,
  '.google.protobuf.Timestamp': $0.Timestamp$json,
  '.dzeroth.posts.v1.PostView': $1.PostView$json,
  '.dzeroth.posts.v1.Post': $1.Post$json,
  '.dzeroth.common.v1.AuthorSnapshot': $2.AuthorSnapshot$json,
  '.dzeroth.common.v1.MediaRef': $2.MediaRef$json,
  '.dzeroth.posts.v1.EmbeddedPost': $1.EmbeddedPost$json,
  '.dzeroth.posts.v1.Poll': $1.Poll$json,
  '.dzeroth.posts.v1.PollChoice': $1.PollChoice$json,
  '.dzeroth.posts.v1.ArticlePreview': $1.ArticlePreview$json,
  '.dzeroth.posts.v1.Mention': $1.Mention$json,
  '.dzeroth.posts.v1.CommunityRef': $1.CommunityRef$json,
  '.dzeroth.articles.v1.ListArticlesRequest': ListArticlesRequest$json,
  '.dzeroth.articles.v1.ListArticlesResponse': ListArticlesResponse$json,
  '.dzeroth.articles.v1.SaveArticleRequest': SaveArticleRequest$json,
  '.dzeroth.articles.v1.SaveArticleResponse': SaveArticleResponse$json,
  '.dzeroth.articles.v1.DeleteArticleRequest': DeleteArticleRequest$json,
  '.dzeroth.articles.v1.DeleteArticleResponse': DeleteArticleResponse$json,
  '.dzeroth.articles.v1.PublishArticleRequest': PublishArticleRequest$json,
  '.dzeroth.articles.v1.PublishArticleResponse': PublishArticleResponse$json,
};

/// Descriptor for `ArticleService`. Decode as a `google.protobuf.ServiceDescriptorProto`.
final $typed_data.Uint8List articleServiceDescriptor = $convert.base64Decode(
    'Cg5BcnRpY2xlU2VydmljZRJiCgpHZXRBcnRpY2xlEiYuZHplcm90aC5hcnRpY2xlcy52MS5HZX'
    'RBcnRpY2xlUmVxdWVzdBonLmR6ZXJvdGguYXJ0aWNsZXMudjEuR2V0QXJ0aWNsZVJlc3BvbnNl'
    'IgOQAgESaAoMTGlzdEFydGljbGVzEiguZHplcm90aC5hcnRpY2xlcy52MS5MaXN0QXJ0aWNsZX'
    'NSZXF1ZXN0GikuZHplcm90aC5hcnRpY2xlcy52MS5MaXN0QXJ0aWNsZXNSZXNwb25zZSIDkAIB'
    'EmAKC1NhdmVBcnRpY2xlEicuZHplcm90aC5hcnRpY2xlcy52MS5TYXZlQXJ0aWNsZVJlcXVlc3'
    'QaKC5kemVyb3RoLmFydGljbGVzLnYxLlNhdmVBcnRpY2xlUmVzcG9uc2USZgoNRGVsZXRlQXJ0'
    'aWNsZRIpLmR6ZXJvdGguYXJ0aWNsZXMudjEuRGVsZXRlQXJ0aWNsZVJlcXVlc3QaKi5kemVyb3'
    'RoLmFydGljbGVzLnYxLkRlbGV0ZUFydGljbGVSZXNwb25zZRJpCg5QdWJsaXNoQXJ0aWNsZRIq'
    'LmR6ZXJvdGguYXJ0aWNsZXMudjEuUHVibGlzaEFydGljbGVSZXF1ZXN0GisuZHplcm90aC5hcn'
    'RpY2xlcy52MS5QdWJsaXNoQXJ0aWNsZVJlc3BvbnNl');
