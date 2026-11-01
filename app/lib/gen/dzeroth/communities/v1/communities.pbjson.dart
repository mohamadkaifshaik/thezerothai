// This is a generated file - do not edit.
//
// Generated from dzeroth/communities/v1/communities.proto.

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
import '../../graph/v1/graph.pbjson.dart' as $1;

@$core.Deprecated('Use communityRoleDescriptor instead')
const CommunityRole$json = {
  '1': 'CommunityRole',
  '2': [
    {'1': 'COMMUNITY_ROLE_UNSPECIFIED', '2': 0},
    {'1': 'COMMUNITY_ROLE_OWNER', '2': 1},
    {'1': 'COMMUNITY_ROLE_MODERATOR', '2': 2},
    {'1': 'COMMUNITY_ROLE_MEMBER', '2': 3},
    {'1': 'COMMUNITY_ROLE_BANNED', '2': 4},
    {'1': 'COMMUNITY_ROLE_NONE', '2': 5},
  ],
};

/// Descriptor for `CommunityRole`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List communityRoleDescriptor = $convert.base64Decode(
    'Cg1Db21tdW5pdHlSb2xlEh4KGkNPTU1VTklUWV9ST0xFX1VOU1BFQ0lGSUVEEAASGAoUQ09NTV'
    'VOSVRZX1JPTEVfT1dORVIQARIcChhDT01NVU5JVFlfUk9MRV9NT0RFUkFUT1IQAhIZChVDT01N'
    'VU5JVFlfUk9MRV9NRU1CRVIQAxIZChVDT01NVU5JVFlfUk9MRV9CQU5ORUQQBBIXChNDT01NVU'
    '5JVFlfUk9MRV9OT05FEAU=');

@$core.Deprecated('Use communityStatusDescriptor instead')
const CommunityStatus$json = {
  '1': 'CommunityStatus',
  '2': [
    {'1': 'COMMUNITY_STATUS_UNSPECIFIED', '2': 0},
    {'1': 'COMMUNITY_STATUS_ACTIVE', '2': 1},
    {'1': 'COMMUNITY_STATUS_ARCHIVED', '2': 2},
    {'1': 'COMMUNITY_STATUS_SUSPENDED', '2': 3},
  ],
};

/// Descriptor for `CommunityStatus`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List communityStatusDescriptor = $convert.base64Decode(
    'Cg9Db21tdW5pdHlTdGF0dXMSIAocQ09NTVVOSVRZX1NUQVRVU19VTlNQRUNJRklFRBAAEhsKF0'
    'NPTU1VTklUWV9TVEFUVVNfQUNUSVZFEAESHQoZQ09NTVVOSVRZX1NUQVRVU19BUkNISVZFRBAC'
    'Eh4KGkNPTU1VTklUWV9TVEFUVVNfU1VTUEVOREVEEAM=');

@$core.Deprecated('Use communityVisibilityDescriptor instead')
const CommunityVisibility$json = {
  '1': 'CommunityVisibility',
  '2': [
    {'1': 'COMMUNITY_VISIBILITY_UNSPECIFIED', '2': 0},
    {'1': 'COMMUNITY_VISIBILITY_PUBLIC', '2': 1},
  ],
};

/// Descriptor for `CommunityVisibility`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List communityVisibilityDescriptor = $convert.base64Decode(
    'ChNDb21tdW5pdHlWaXNpYmlsaXR5EiQKIENPTU1VTklUWV9WSVNJQklMSVRZX1VOU1BFQ0lGSU'
    'VEEAASHwobQ09NTVVOSVRZX1ZJU0lCSUxJVFlfUFVCTElDEAE=');

@$core.Deprecated('Use communityMemberFilterDescriptor instead')
const CommunityMemberFilter$json = {
  '1': 'CommunityMemberFilter',
  '2': [
    {'1': 'COMMUNITY_MEMBER_FILTER_UNSPECIFIED', '2': 0},
    {'1': 'COMMUNITY_MEMBER_FILTER_JOINED', '2': 1},
    {'1': 'COMMUNITY_MEMBER_FILTER_BANNED', '2': 2},
  ],
};

/// Descriptor for `CommunityMemberFilter`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List communityMemberFilterDescriptor = $convert.base64Decode(
    'ChVDb21tdW5pdHlNZW1iZXJGaWx0ZXISJwojQ09NTVVOSVRZX01FTUJFUl9GSUxURVJfVU5TUE'
    'VDSUZJRUQQABIiCh5DT01NVU5JVFlfTUVNQkVSX0ZJTFRFUl9KT0lORUQQARIiCh5DT01NVU5J'
    'VFlfTUVNQkVSX0ZJTFRFUl9CQU5ORUQQAg==');

@$core.Deprecated('Use memberRoleActionDescriptor instead')
const MemberRoleAction$json = {
  '1': 'MemberRoleAction',
  '2': [
    {'1': 'MEMBER_ROLE_ACTION_UNSPECIFIED', '2': 0},
    {'1': 'MEMBER_ROLE_ACTION_BAN', '2': 1},
    {'1': 'MEMBER_ROLE_ACTION_UNBAN', '2': 2},
    {'1': 'MEMBER_ROLE_ACTION_MAKE_MODERATOR', '2': 3},
    {'1': 'MEMBER_ROLE_ACTION_REMOVE_MODERATOR', '2': 4},
  ],
};

/// Descriptor for `MemberRoleAction`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List memberRoleActionDescriptor = $convert.base64Decode(
    'ChBNZW1iZXJSb2xlQWN0aW9uEiIKHk1FTUJFUl9ST0xFX0FDVElPTl9VTlNQRUNJRklFRBAAEh'
    'oKFk1FTUJFUl9ST0xFX0FDVElPTl9CQU4QARIcChhNRU1CRVJfUk9MRV9BQ1RJT05fVU5CQU4Q'
    'AhIlCiFNRU1CRVJfUk9MRV9BQ1RJT05fTUFLRV9NT0RFUkFUT1IQAxInCiNNRU1CRVJfUk9MRV'
    '9BQ1RJT05fUkVNT1ZFX01PREVSQVRPUhAE');

@$core.Deprecated('Use moderationLogActionDescriptor instead')
const ModerationLogAction$json = {
  '1': 'ModerationLogAction',
  '2': [
    {'1': 'MODERATION_LOG_ACTION_UNSPECIFIED', '2': 0},
    {'1': 'MODERATION_LOG_ACTION_HIDE', '2': 1},
    {'1': 'MODERATION_LOG_ACTION_RESTORE', '2': 2},
    {'1': 'MODERATION_LOG_ACTION_BAN', '2': 3},
    {'1': 'MODERATION_LOG_ACTION_UNBAN', '2': 4},
    {'1': 'MODERATION_LOG_ACTION_MAKE_MODERATOR', '2': 5},
    {'1': 'MODERATION_LOG_ACTION_REMOVE_MODERATOR', '2': 6},
    {'1': 'MODERATION_LOG_ACTION_EDIT', '2': 7},
    {'1': 'MODERATION_LOG_ACTION_MODERATOR_LEFT', '2': 8},
    {'1': 'MODERATION_LOG_ACTION_OWNER_HANDOVER', '2': 9},
  ],
};

/// Descriptor for `ModerationLogAction`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List moderationLogActionDescriptor = $convert.base64Decode(
    'ChNNb2RlcmF0aW9uTG9nQWN0aW9uEiUKIU1PREVSQVRJT05fTE9HX0FDVElPTl9VTlNQRUNJRk'
    'lFRBAAEh4KGk1PREVSQVRJT05fTE9HX0FDVElPTl9ISURFEAESIQodTU9ERVJBVElPTl9MT0df'
    'QUNUSU9OX1JFU1RPUkUQAhIdChlNT0RFUkFUSU9OX0xPR19BQ1RJT05fQkFOEAMSHwobTU9ERV'
    'JBVElPTl9MT0dfQUNUSU9OX1VOQkFOEAQSKAokTU9ERVJBVElPTl9MT0dfQUNUSU9OX01BS0Vf'
    'TU9ERVJBVE9SEAUSKgomTU9ERVJBVElPTl9MT0dfQUNUSU9OX1JFTU9WRV9NT0RFUkFUT1IQBh'
    'IeChpNT0RFUkFUSU9OX0xPR19BQ1RJT05fRURJVBAHEigKJE1PREVSQVRJT05fTE9HX0FDVElP'
    'Tl9NT0RFUkFUT1JfTEVGVBAIEigKJE1PREVSQVRJT05fTE9HX0FDVElPTl9PV05FUl9IQU5ET1'
    'ZFUhAJ');

@$core.Deprecated('Use communityRuleDescriptor instead')
const CommunityRule$json = {
  '1': 'CommunityRule',
  '2': [
    {'1': 'title', '3': 1, '4': 1, '5': 9, '10': 'title'},
    {'1': 'text', '3': 2, '4': 1, '5': 9, '10': 'text'},
  ],
};

/// Descriptor for `CommunityRule`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List communityRuleDescriptor = $convert.base64Decode(
    'Cg1Db21tdW5pdHlSdWxlEhQKBXRpdGxlGAEgASgJUgV0aXRsZRISCgR0ZXh0GAIgASgJUgR0ZX'
    'h0');

@$core.Deprecated('Use communityRuleListDescriptor instead')
const CommunityRuleList$json = {
  '1': 'CommunityRuleList',
  '2': [
    {
      '1': 'rules',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.communities.v1.CommunityRule',
      '10': 'rules'
    },
  ],
};

/// Descriptor for `CommunityRuleList`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List communityRuleListDescriptor = $convert.base64Decode(
    'ChFDb21tdW5pdHlSdWxlTGlzdBI7CgVydWxlcxgBIAMoCzIlLmR6ZXJvdGguY29tbXVuaXRpZX'
    'MudjEuQ29tbXVuaXR5UnVsZVIFcnVsZXM=');

@$core.Deprecated('Use communityDescriptor instead')
const Community$json = {
  '1': 'Community',
  '2': [
    {'1': 'community_id', '3': 1, '4': 1, '5': 9, '10': 'communityId'},
    {'1': 'name', '3': 2, '4': 1, '5': 9, '10': 'name'},
    {'1': 'description', '3': 3, '4': 1, '5': 9, '10': 'description'},
    {'1': 'member_count', '3': 4, '4': 1, '5': 3, '10': 'memberCount'},
    {
      '1': 'status',
      '3': 5,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.communities.v1.CommunityStatus',
      '10': 'status'
    },
    {
      '1': 'visibility',
      '3': 6,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.communities.v1.CommunityVisibility',
      '10': 'visibility'
    },
    {
      '1': 'viewer_role',
      '3': 7,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.communities.v1.CommunityRole',
      '10': 'viewerRole'
    },
    {
      '1': 'created_at',
      '3': 8,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '10': 'createdAt'
    },
  ],
};

/// Descriptor for `Community`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List communityDescriptor = $convert.base64Decode(
    'CglDb21tdW5pdHkSIQoMY29tbXVuaXR5X2lkGAEgASgJUgtjb21tdW5pdHlJZBISCgRuYW1lGA'
    'IgASgJUgRuYW1lEiAKC2Rlc2NyaXB0aW9uGAMgASgJUgtkZXNjcmlwdGlvbhIhCgxtZW1iZXJf'
    'Y291bnQYBCABKANSC21lbWJlckNvdW50Ej8KBnN0YXR1cxgFIAEoDjInLmR6ZXJvdGguY29tbX'
    'VuaXRpZXMudjEuQ29tbXVuaXR5U3RhdHVzUgZzdGF0dXMSSwoKdmlzaWJpbGl0eRgGIAEoDjIr'
    'LmR6ZXJvdGguY29tbXVuaXRpZXMudjEuQ29tbXVuaXR5VmlzaWJpbGl0eVIKdmlzaWJpbGl0eR'
    'JGCgt2aWV3ZXJfcm9sZRgHIAEoDjIlLmR6ZXJvdGguY29tbXVuaXRpZXMudjEuQ29tbXVuaXR5'
    'Um9sZVIKdmlld2VyUm9sZRI5CgpjcmVhdGVkX2F0GAggASgLMhouZ29vZ2xlLnByb3RvYnVmLl'
    'RpbWVzdGFtcFIJY3JlYXRlZEF0');

@$core.Deprecated('Use communityMemberDescriptor instead')
const CommunityMember$json = {
  '1': 'CommunityMember',
  '2': [
    {
      '1': 'user',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.graph.v1.UserListItem',
      '10': 'user'
    },
    {
      '1': 'role',
      '3': 2,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.communities.v1.CommunityRole',
      '10': 'role'
    },
  ],
};

/// Descriptor for `CommunityMember`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List communityMemberDescriptor = $convert.base64Decode(
    'Cg9Db21tdW5pdHlNZW1iZXISMgoEdXNlchgBIAEoCzIeLmR6ZXJvdGguZ3JhcGgudjEuVXNlck'
    'xpc3RJdGVtUgR1c2VyEjkKBHJvbGUYAiABKA4yJS5kemVyb3RoLmNvbW11bml0aWVzLnYxLkNv'
    'bW11bml0eVJvbGVSBHJvbGU=');

@$core.Deprecated('Use moderationLogEntryDescriptor instead')
const ModerationLogEntry$json = {
  '1': 'ModerationLogEntry',
  '2': [
    {'1': 'seq', '3': 1, '4': 1, '5': 3, '10': 'seq'},
    {
      '1': 'at',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '10': 'at'
    },
    {
      '1': 'action',
      '3': 3,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.communities.v1.ModerationLogAction',
      '10': 'action'
    },
    {
      '1': 'actor',
      '3': 4,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.common.v1.AuthorSnapshot',
      '10': 'actor'
    },
    {'1': 'actor_deleted', '3': 5, '4': 1, '5': 8, '10': 'actorDeleted'},
    {
      '1': 'target',
      '3': 6,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.common.v1.AuthorSnapshot',
      '10': 'target'
    },
    {'1': 'target_deleted', '3': 7, '4': 1, '5': 8, '10': 'targetDeleted'},
    {'1': 'post_id', '3': 8, '4': 1, '5': 9, '10': 'postId'},
  ],
};

/// Descriptor for `ModerationLogEntry`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List moderationLogEntryDescriptor = $convert.base64Decode(
    'ChJNb2RlcmF0aW9uTG9nRW50cnkSEAoDc2VxGAEgASgDUgNzZXESKgoCYXQYAiABKAsyGi5nb2'
    '9nbGUucHJvdG9idWYuVGltZXN0YW1wUgJhdBJDCgZhY3Rpb24YAyABKA4yKy5kemVyb3RoLmNv'
    'bW11bml0aWVzLnYxLk1vZGVyYXRpb25Mb2dBY3Rpb25SBmFjdGlvbhI3CgVhY3RvchgEIAEoCz'
    'IhLmR6ZXJvdGguY29tbW9uLnYxLkF1dGhvclNuYXBzaG90UgVhY3RvchIjCg1hY3Rvcl9kZWxl'
    'dGVkGAUgASgIUgxhY3RvckRlbGV0ZWQSOQoGdGFyZ2V0GAYgASgLMiEuZHplcm90aC5jb21tb2'
    '4udjEuQXV0aG9yU25hcHNob3RSBnRhcmdldBIlCg50YXJnZXRfZGVsZXRlZBgHIAEoCFINdGFy'
    'Z2V0RGVsZXRlZBIXCgdwb3N0X2lkGAggASgJUgZwb3N0SWQ=');

@$core.Deprecated('Use createCommunityRequestDescriptor instead')
const CreateCommunityRequest$json = {
  '1': 'CreateCommunityRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'name', '3': 2, '4': 1, '5': 9, '10': 'name'},
    {'1': 'description', '3': 3, '4': 1, '5': 9, '10': 'description'},
    {
      '1': 'rules',
      '3': 4,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.communities.v1.CommunityRule',
      '10': 'rules'
    },
  ],
};

/// Descriptor for `CreateCommunityRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List createCommunityRequestDescriptor = $convert.base64Decode(
    'ChZDcmVhdGVDb21tdW5pdHlSZXF1ZXN0EicKD2lkZW1wb3RlbmN5X2tleRgBIAEoCVIOaWRlbX'
    'BvdGVuY3lLZXkSEgoEbmFtZRgCIAEoCVIEbmFtZRIgCgtkZXNjcmlwdGlvbhgDIAEoCVILZGVz'
    'Y3JpcHRpb24SOwoFcnVsZXMYBCADKAsyJS5kemVyb3RoLmNvbW11bml0aWVzLnYxLkNvbW11bm'
    'l0eVJ1bGVSBXJ1bGVz');

@$core.Deprecated('Use createCommunityResponseDescriptor instead')
const CreateCommunityResponse$json = {
  '1': 'CreateCommunityResponse',
  '2': [
    {
      '1': 'community',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.communities.v1.Community',
      '10': 'community'
    },
    {
      '1': 'rules',
      '3': 2,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.communities.v1.CommunityRule',
      '10': 'rules'
    },
  ],
};

/// Descriptor for `CreateCommunityResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List createCommunityResponseDescriptor = $convert.base64Decode(
    'ChdDcmVhdGVDb21tdW5pdHlSZXNwb25zZRI/Cgljb21tdW5pdHkYASABKAsyIS5kemVyb3RoLm'
    'NvbW11bml0aWVzLnYxLkNvbW11bml0eVIJY29tbXVuaXR5EjsKBXJ1bGVzGAIgAygLMiUuZHpl'
    'cm90aC5jb21tdW5pdGllcy52MS5Db21tdW5pdHlSdWxlUgVydWxlcw==');

@$core.Deprecated('Use updateCommunityRequestDescriptor instead')
const UpdateCommunityRequest$json = {
  '1': 'UpdateCommunityRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'community_id', '3': 2, '4': 1, '5': 9, '10': 'communityId'},
    {'1': 'name', '3': 3, '4': 1, '5': 9, '9': 0, '10': 'name', '17': true},
    {
      '1': 'description',
      '3': 4,
      '4': 1,
      '5': 9,
      '9': 1,
      '10': 'description',
      '17': true
    },
    {
      '1': 'rules',
      '3': 5,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.communities.v1.CommunityRuleList',
      '10': 'rules'
    },
  ],
  '8': [
    {'1': '_name'},
    {'1': '_description'},
  ],
};

/// Descriptor for `UpdateCommunityRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List updateCommunityRequestDescriptor = $convert.base64Decode(
    'ChZVcGRhdGVDb21tdW5pdHlSZXF1ZXN0EicKD2lkZW1wb3RlbmN5X2tleRgBIAEoCVIOaWRlbX'
    'BvdGVuY3lLZXkSIQoMY29tbXVuaXR5X2lkGAIgASgJUgtjb21tdW5pdHlJZBIXCgRuYW1lGAMg'
    'ASgJSABSBG5hbWWIAQESJQoLZGVzY3JpcHRpb24YBCABKAlIAVILZGVzY3JpcHRpb26IAQESPw'
    'oFcnVsZXMYBSABKAsyKS5kemVyb3RoLmNvbW11bml0aWVzLnYxLkNvbW11bml0eVJ1bGVMaXN0'
    'UgVydWxlc0IHCgVfbmFtZUIOCgxfZGVzY3JpcHRpb24=');

@$core.Deprecated('Use updateCommunityResponseDescriptor instead')
const UpdateCommunityResponse$json = {
  '1': 'UpdateCommunityResponse',
  '2': [
    {
      '1': 'community',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.communities.v1.Community',
      '10': 'community'
    },
    {
      '1': 'rules',
      '3': 2,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.communities.v1.CommunityRule',
      '10': 'rules'
    },
  ],
};

/// Descriptor for `UpdateCommunityResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List updateCommunityResponseDescriptor = $convert.base64Decode(
    'ChdVcGRhdGVDb21tdW5pdHlSZXNwb25zZRI/Cgljb21tdW5pdHkYASABKAsyIS5kemVyb3RoLm'
    'NvbW11bml0aWVzLnYxLkNvbW11bml0eVIJY29tbXVuaXR5EjsKBXJ1bGVzGAIgAygLMiUuZHpl'
    'cm90aC5jb21tdW5pdGllcy52MS5Db21tdW5pdHlSdWxlUgVydWxlcw==');

@$core.Deprecated('Use getCommunityRequestDescriptor instead')
const GetCommunityRequest$json = {
  '1': 'GetCommunityRequest',
  '2': [
    {'1': 'community_id', '3': 1, '4': 1, '5': 9, '10': 'communityId'},
  ],
};

/// Descriptor for `GetCommunityRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getCommunityRequestDescriptor = $convert.base64Decode(
    'ChNHZXRDb21tdW5pdHlSZXF1ZXN0EiEKDGNvbW11bml0eV9pZBgBIAEoCVILY29tbXVuaXR5SW'
    'Q=');

@$core.Deprecated('Use getCommunityResponseDescriptor instead')
const GetCommunityResponse$json = {
  '1': 'GetCommunityResponse',
  '2': [
    {
      '1': 'community',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.communities.v1.Community',
      '10': 'community'
    },
    {
      '1': 'rules',
      '3': 2,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.communities.v1.CommunityRule',
      '10': 'rules'
    },
    {
      '1': 'owner',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.graph.v1.UserListItem',
      '10': 'owner'
    },
    {
      '1': 'moderators',
      '3': 4,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.graph.v1.UserListItem',
      '10': 'moderators'
    },
  ],
};

/// Descriptor for `GetCommunityResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getCommunityResponseDescriptor = $convert.base64Decode(
    'ChRHZXRDb21tdW5pdHlSZXNwb25zZRI/Cgljb21tdW5pdHkYASABKAsyIS5kemVyb3RoLmNvbW'
    '11bml0aWVzLnYxLkNvbW11bml0eVIJY29tbXVuaXR5EjsKBXJ1bGVzGAIgAygLMiUuZHplcm90'
    'aC5jb21tdW5pdGllcy52MS5Db21tdW5pdHlSdWxlUgVydWxlcxI0CgVvd25lchgDIAEoCzIeLm'
    'R6ZXJvdGguZ3JhcGgudjEuVXNlckxpc3RJdGVtUgVvd25lchI+Cgptb2RlcmF0b3JzGAQgAygL'
    'Mh4uZHplcm90aC5ncmFwaC52MS5Vc2VyTGlzdEl0ZW1SCm1vZGVyYXRvcnM=');

@$core.Deprecated('Use listCommunitiesRequestDescriptor instead')
const ListCommunitiesRequest$json = {
  '1': 'ListCommunitiesRequest',
  '2': [
    {'1': 'page_size', '3': 1, '4': 1, '5': 5, '10': 'pageSize'},
    {'1': 'page_token', '3': 2, '4': 1, '5': 9, '10': 'pageToken'},
  ],
};

/// Descriptor for `ListCommunitiesRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listCommunitiesRequestDescriptor =
    $convert.base64Decode(
        'ChZMaXN0Q29tbXVuaXRpZXNSZXF1ZXN0EhsKCXBhZ2Vfc2l6ZRgBIAEoBVIIcGFnZVNpemUSHQ'
        'oKcGFnZV90b2tlbhgCIAEoCVIJcGFnZVRva2Vu');

@$core.Deprecated('Use listCommunitiesResponseDescriptor instead')
const ListCommunitiesResponse$json = {
  '1': 'ListCommunitiesResponse',
  '2': [
    {
      '1': 'communities',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.communities.v1.Community',
      '10': 'communities'
    },
    {'1': 'next_page_token', '3': 2, '4': 1, '5': 9, '10': 'nextPageToken'},
  ],
};

/// Descriptor for `ListCommunitiesResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listCommunitiesResponseDescriptor = $convert.base64Decode(
    'ChdMaXN0Q29tbXVuaXRpZXNSZXNwb25zZRJDCgtjb21tdW5pdGllcxgBIAMoCzIhLmR6ZXJvdG'
    'guY29tbXVuaXRpZXMudjEuQ29tbXVuaXR5Ugtjb21tdW5pdGllcxImCg9uZXh0X3BhZ2VfdG9r'
    'ZW4YAiABKAlSDW5leHRQYWdlVG9rZW4=');

@$core.Deprecated('Use listMyCommunitiesRequestDescriptor instead')
const ListMyCommunitiesRequest$json = {
  '1': 'ListMyCommunitiesRequest',
  '2': [
    {'1': 'page_size', '3': 1, '4': 1, '5': 5, '10': 'pageSize'},
    {'1': 'page_token', '3': 2, '4': 1, '5': 9, '10': 'pageToken'},
  ],
};

/// Descriptor for `ListMyCommunitiesRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listMyCommunitiesRequestDescriptor =
    $convert.base64Decode(
        'ChhMaXN0TXlDb21tdW5pdGllc1JlcXVlc3QSGwoJcGFnZV9zaXplGAEgASgFUghwYWdlU2l6ZR'
        'IdCgpwYWdlX3Rva2VuGAIgASgJUglwYWdlVG9rZW4=');

@$core.Deprecated('Use listMyCommunitiesResponseDescriptor instead')
const ListMyCommunitiesResponse$json = {
  '1': 'ListMyCommunitiesResponse',
  '2': [
    {
      '1': 'communities',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.communities.v1.Community',
      '10': 'communities'
    },
    {'1': 'can_create', '3': 2, '4': 1, '5': 8, '10': 'canCreate'},
    {'1': 'next_page_token', '3': 3, '4': 1, '5': 9, '10': 'nextPageToken'},
  ],
};

/// Descriptor for `ListMyCommunitiesResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listMyCommunitiesResponseDescriptor = $convert.base64Decode(
    'ChlMaXN0TXlDb21tdW5pdGllc1Jlc3BvbnNlEkMKC2NvbW11bml0aWVzGAEgAygLMiEuZHplcm'
    '90aC5jb21tdW5pdGllcy52MS5Db21tdW5pdHlSC2NvbW11bml0aWVzEh0KCmNhbl9jcmVhdGUY'
    'AiABKAhSCWNhbkNyZWF0ZRImCg9uZXh0X3BhZ2VfdG9rZW4YAyABKAlSDW5leHRQYWdlVG9rZW'
    '4=');

@$core.Deprecated('Use joinCommunityRequestDescriptor instead')
const JoinCommunityRequest$json = {
  '1': 'JoinCommunityRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'community_id', '3': 2, '4': 1, '5': 9, '10': 'communityId'},
  ],
};

/// Descriptor for `JoinCommunityRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List joinCommunityRequestDescriptor = $convert.base64Decode(
    'ChRKb2luQ29tbXVuaXR5UmVxdWVzdBInCg9pZGVtcG90ZW5jeV9rZXkYASABKAlSDmlkZW1wb3'
    'RlbmN5S2V5EiEKDGNvbW11bml0eV9pZBgCIAEoCVILY29tbXVuaXR5SWQ=');

@$core.Deprecated('Use joinCommunityResponseDescriptor instead')
const JoinCommunityResponse$json = {
  '1': 'JoinCommunityResponse',
  '2': [
    {
      '1': 'community',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.communities.v1.Community',
      '10': 'community'
    },
  ],
};

/// Descriptor for `JoinCommunityResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List joinCommunityResponseDescriptor = $convert.base64Decode(
    'ChVKb2luQ29tbXVuaXR5UmVzcG9uc2USPwoJY29tbXVuaXR5GAEgASgLMiEuZHplcm90aC5jb2'
    '1tdW5pdGllcy52MS5Db21tdW5pdHlSCWNvbW11bml0eQ==');

@$core.Deprecated('Use leaveCommunityRequestDescriptor instead')
const LeaveCommunityRequest$json = {
  '1': 'LeaveCommunityRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'community_id', '3': 2, '4': 1, '5': 9, '10': 'communityId'},
  ],
};

/// Descriptor for `LeaveCommunityRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List leaveCommunityRequestDescriptor = $convert.base64Decode(
    'ChVMZWF2ZUNvbW11bml0eVJlcXVlc3QSJwoPaWRlbXBvdGVuY3lfa2V5GAEgASgJUg5pZGVtcG'
    '90ZW5jeUtleRIhCgxjb21tdW5pdHlfaWQYAiABKAlSC2NvbW11bml0eUlk');

@$core.Deprecated('Use leaveCommunityResponseDescriptor instead')
const LeaveCommunityResponse$json = {
  '1': 'LeaveCommunityResponse',
  '2': [
    {
      '1': 'community',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.communities.v1.Community',
      '10': 'community'
    },
  ],
};

/// Descriptor for `LeaveCommunityResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List leaveCommunityResponseDescriptor =
    $convert.base64Decode(
        'ChZMZWF2ZUNvbW11bml0eVJlc3BvbnNlEj8KCWNvbW11bml0eRgBIAEoCzIhLmR6ZXJvdGguY2'
        '9tbXVuaXRpZXMudjEuQ29tbXVuaXR5Ugljb21tdW5pdHk=');

@$core.Deprecated('Use listCommunityMembersRequestDescriptor instead')
const ListCommunityMembersRequest$json = {
  '1': 'ListCommunityMembersRequest',
  '2': [
    {'1': 'community_id', '3': 1, '4': 1, '5': 9, '10': 'communityId'},
    {
      '1': 'filter',
      '3': 2,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.communities.v1.CommunityMemberFilter',
      '10': 'filter'
    },
    {'1': 'page_size', '3': 3, '4': 1, '5': 5, '10': 'pageSize'},
    {'1': 'page_token', '3': 4, '4': 1, '5': 9, '10': 'pageToken'},
  ],
};

/// Descriptor for `ListCommunityMembersRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listCommunityMembersRequestDescriptor = $convert.base64Decode(
    'ChtMaXN0Q29tbXVuaXR5TWVtYmVyc1JlcXVlc3QSIQoMY29tbXVuaXR5X2lkGAEgASgJUgtjb2'
    '1tdW5pdHlJZBJFCgZmaWx0ZXIYAiABKA4yLS5kemVyb3RoLmNvbW11bml0aWVzLnYxLkNvbW11'
    'bml0eU1lbWJlckZpbHRlclIGZmlsdGVyEhsKCXBhZ2Vfc2l6ZRgDIAEoBVIIcGFnZVNpemUSHQ'
    'oKcGFnZV90b2tlbhgEIAEoCVIJcGFnZVRva2Vu');

@$core.Deprecated('Use listCommunityMembersResponseDescriptor instead')
const ListCommunityMembersResponse$json = {
  '1': 'ListCommunityMembersResponse',
  '2': [
    {
      '1': 'members',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.communities.v1.CommunityMember',
      '10': 'members'
    },
    {'1': 'next_page_token', '3': 2, '4': 1, '5': 9, '10': 'nextPageToken'},
  ],
};

/// Descriptor for `ListCommunityMembersResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listCommunityMembersResponseDescriptor =
    $convert.base64Decode(
        'ChxMaXN0Q29tbXVuaXR5TWVtYmVyc1Jlc3BvbnNlEkEKB21lbWJlcnMYASADKAsyJy5kemVyb3'
        'RoLmNvbW11bml0aWVzLnYxLkNvbW11bml0eU1lbWJlclIHbWVtYmVycxImCg9uZXh0X3BhZ2Vf'
        'dG9rZW4YAiABKAlSDW5leHRQYWdlVG9rZW4=');

@$core.Deprecated('Use hideCommunityPostRequestDescriptor instead')
const HideCommunityPostRequest$json = {
  '1': 'HideCommunityPostRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'community_id', '3': 2, '4': 1, '5': 9, '10': 'communityId'},
    {'1': 'post_id', '3': 3, '4': 1, '5': 9, '10': 'postId'},
  ],
};

/// Descriptor for `HideCommunityPostRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List hideCommunityPostRequestDescriptor = $convert.base64Decode(
    'ChhIaWRlQ29tbXVuaXR5UG9zdFJlcXVlc3QSJwoPaWRlbXBvdGVuY3lfa2V5GAEgASgJUg5pZG'
    'VtcG90ZW5jeUtleRIhCgxjb21tdW5pdHlfaWQYAiABKAlSC2NvbW11bml0eUlkEhcKB3Bvc3Rf'
    'aWQYAyABKAlSBnBvc3RJZA==');

@$core.Deprecated('Use hideCommunityPostResponseDescriptor instead')
const HideCommunityPostResponse$json = {
  '1': 'HideCommunityPostResponse',
};

/// Descriptor for `HideCommunityPostResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List hideCommunityPostResponseDescriptor =
    $convert.base64Decode('ChlIaWRlQ29tbXVuaXR5UG9zdFJlc3BvbnNl');

@$core.Deprecated('Use restoreCommunityPostRequestDescriptor instead')
const RestoreCommunityPostRequest$json = {
  '1': 'RestoreCommunityPostRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'community_id', '3': 2, '4': 1, '5': 9, '10': 'communityId'},
    {'1': 'post_id', '3': 3, '4': 1, '5': 9, '10': 'postId'},
  ],
};

/// Descriptor for `RestoreCommunityPostRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List restoreCommunityPostRequestDescriptor =
    $convert.base64Decode(
        'ChtSZXN0b3JlQ29tbXVuaXR5UG9zdFJlcXVlc3QSJwoPaWRlbXBvdGVuY3lfa2V5GAEgASgJUg'
        '5pZGVtcG90ZW5jeUtleRIhCgxjb21tdW5pdHlfaWQYAiABKAlSC2NvbW11bml0eUlkEhcKB3Bv'
        'c3RfaWQYAyABKAlSBnBvc3RJZA==');

@$core.Deprecated('Use restoreCommunityPostResponseDescriptor instead')
const RestoreCommunityPostResponse$json = {
  '1': 'RestoreCommunityPostResponse',
};

/// Descriptor for `RestoreCommunityPostResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List restoreCommunityPostResponseDescriptor =
    $convert.base64Decode('ChxSZXN0b3JlQ29tbXVuaXR5UG9zdFJlc3BvbnNl');

@$core.Deprecated('Use setMemberRoleRequestDescriptor instead')
const SetMemberRoleRequest$json = {
  '1': 'SetMemberRoleRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'community_id', '3': 2, '4': 1, '5': 9, '10': 'communityId'},
    {'1': 'user_id', '3': 3, '4': 1, '5': 9, '10': 'userId'},
    {
      '1': 'action',
      '3': 4,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.communities.v1.MemberRoleAction',
      '10': 'action'
    },
  ],
};

/// Descriptor for `SetMemberRoleRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List setMemberRoleRequestDescriptor = $convert.base64Decode(
    'ChRTZXRNZW1iZXJSb2xlUmVxdWVzdBInCg9pZGVtcG90ZW5jeV9rZXkYASABKAlSDmlkZW1wb3'
    'RlbmN5S2V5EiEKDGNvbW11bml0eV9pZBgCIAEoCVILY29tbXVuaXR5SWQSFwoHdXNlcl9pZBgD'
    'IAEoCVIGdXNlcklkEkAKBmFjdGlvbhgEIAEoDjIoLmR6ZXJvdGguY29tbXVuaXRpZXMudjEuTW'
    'VtYmVyUm9sZUFjdGlvblIGYWN0aW9u');

@$core.Deprecated('Use setMemberRoleResponseDescriptor instead')
const SetMemberRoleResponse$json = {
  '1': 'SetMemberRoleResponse',
  '2': [
    {
      '1': 'role',
      '3': 1,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.communities.v1.CommunityRole',
      '10': 'role'
    },
    {
      '1': 'community',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.communities.v1.Community',
      '10': 'community'
    },
  ],
};

/// Descriptor for `SetMemberRoleResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List setMemberRoleResponseDescriptor = $convert.base64Decode(
    'ChVTZXRNZW1iZXJSb2xlUmVzcG9uc2USOQoEcm9sZRgBIAEoDjIlLmR6ZXJvdGguY29tbXVuaX'
    'RpZXMudjEuQ29tbXVuaXR5Um9sZVIEcm9sZRI/Cgljb21tdW5pdHkYAiABKAsyIS5kemVyb3Ro'
    'LmNvbW11bml0aWVzLnYxLkNvbW11bml0eVIJY29tbXVuaXR5');

@$core.Deprecated('Use listModerationLogRequestDescriptor instead')
const ListModerationLogRequest$json = {
  '1': 'ListModerationLogRequest',
  '2': [
    {'1': 'community_id', '3': 1, '4': 1, '5': 9, '10': 'communityId'},
    {'1': 'page_size', '3': 2, '4': 1, '5': 5, '10': 'pageSize'},
    {'1': 'page_token', '3': 3, '4': 1, '5': 9, '10': 'pageToken'},
  ],
};

/// Descriptor for `ListModerationLogRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listModerationLogRequestDescriptor = $convert.base64Decode(
    'ChhMaXN0TW9kZXJhdGlvbkxvZ1JlcXVlc3QSIQoMY29tbXVuaXR5X2lkGAEgASgJUgtjb21tdW'
    '5pdHlJZBIbCglwYWdlX3NpemUYAiABKAVSCHBhZ2VTaXplEh0KCnBhZ2VfdG9rZW4YAyABKAlS'
    'CXBhZ2VUb2tlbg==');

@$core.Deprecated('Use listModerationLogResponseDescriptor instead')
const ListModerationLogResponse$json = {
  '1': 'ListModerationLogResponse',
  '2': [
    {
      '1': 'entries',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.communities.v1.ModerationLogEntry',
      '10': 'entries'
    },
    {'1': 'next_page_token', '3': 2, '4': 1, '5': 9, '10': 'nextPageToken'},
  ],
};

/// Descriptor for `ListModerationLogResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listModerationLogResponseDescriptor = $convert.base64Decode(
    'ChlMaXN0TW9kZXJhdGlvbkxvZ1Jlc3BvbnNlEkQKB2VudHJpZXMYASADKAsyKi5kemVyb3RoLm'
    'NvbW11bml0aWVzLnYxLk1vZGVyYXRpb25Mb2dFbnRyeVIHZW50cmllcxImCg9uZXh0X3BhZ2Vf'
    'dG9rZW4YAiABKAlSDW5leHRQYWdlVG9rZW4=');

const $core.Map<$core.String, $core.dynamic> CommunityServiceBase$json = {
  '1': 'CommunityService',
  '2': [
    {
      '1': 'CreateCommunity',
      '2': '.dzeroth.communities.v1.CreateCommunityRequest',
      '3': '.dzeroth.communities.v1.CreateCommunityResponse'
    },
    {
      '1': 'UpdateCommunity',
      '2': '.dzeroth.communities.v1.UpdateCommunityRequest',
      '3': '.dzeroth.communities.v1.UpdateCommunityResponse'
    },
    {
      '1': 'GetCommunity',
      '2': '.dzeroth.communities.v1.GetCommunityRequest',
      '3': '.dzeroth.communities.v1.GetCommunityResponse',
      '4': {'34': 1},
    },
    {
      '1': 'ListCommunities',
      '2': '.dzeroth.communities.v1.ListCommunitiesRequest',
      '3': '.dzeroth.communities.v1.ListCommunitiesResponse',
      '4': {'34': 1},
    },
    {
      '1': 'ListMyCommunities',
      '2': '.dzeroth.communities.v1.ListMyCommunitiesRequest',
      '3': '.dzeroth.communities.v1.ListMyCommunitiesResponse',
      '4': {'34': 1},
    },
    {
      '1': 'JoinCommunity',
      '2': '.dzeroth.communities.v1.JoinCommunityRequest',
      '3': '.dzeroth.communities.v1.JoinCommunityResponse'
    },
    {
      '1': 'LeaveCommunity',
      '2': '.dzeroth.communities.v1.LeaveCommunityRequest',
      '3': '.dzeroth.communities.v1.LeaveCommunityResponse'
    },
    {
      '1': 'ListCommunityMembers',
      '2': '.dzeroth.communities.v1.ListCommunityMembersRequest',
      '3': '.dzeroth.communities.v1.ListCommunityMembersResponse',
      '4': {'34': 1},
    },
    {
      '1': 'HideCommunityPost',
      '2': '.dzeroth.communities.v1.HideCommunityPostRequest',
      '3': '.dzeroth.communities.v1.HideCommunityPostResponse'
    },
    {
      '1': 'RestoreCommunityPost',
      '2': '.dzeroth.communities.v1.RestoreCommunityPostRequest',
      '3': '.dzeroth.communities.v1.RestoreCommunityPostResponse'
    },
    {
      '1': 'SetMemberRole',
      '2': '.dzeroth.communities.v1.SetMemberRoleRequest',
      '3': '.dzeroth.communities.v1.SetMemberRoleResponse'
    },
    {
      '1': 'ListModerationLog',
      '2': '.dzeroth.communities.v1.ListModerationLogRequest',
      '3': '.dzeroth.communities.v1.ListModerationLogResponse',
      '4': {'34': 1},
    },
  ],
};

@$core.Deprecated('Use communityServiceDescriptor instead')
const $core.Map<$core.String, $core.Map<$core.String, $core.dynamic>>
    CommunityServiceBase$messageJson = {
  '.dzeroth.communities.v1.CreateCommunityRequest': CreateCommunityRequest$json,
  '.dzeroth.communities.v1.CommunityRule': CommunityRule$json,
  '.dzeroth.communities.v1.CreateCommunityResponse':
      CreateCommunityResponse$json,
  '.dzeroth.communities.v1.Community': Community$json,
  '.google.protobuf.Timestamp': $0.Timestamp$json,
  '.dzeroth.communities.v1.UpdateCommunityRequest': UpdateCommunityRequest$json,
  '.dzeroth.communities.v1.CommunityRuleList': CommunityRuleList$json,
  '.dzeroth.communities.v1.UpdateCommunityResponse':
      UpdateCommunityResponse$json,
  '.dzeroth.communities.v1.GetCommunityRequest': GetCommunityRequest$json,
  '.dzeroth.communities.v1.GetCommunityResponse': GetCommunityResponse$json,
  '.dzeroth.graph.v1.UserListItem': $1.UserListItem$json,
  '.dzeroth.common.v1.AuthorSnapshot': $2.AuthorSnapshot$json,
  '.dzeroth.graph.v1.Relationship': $1.Relationship$json,
  '.dzeroth.communities.v1.ListCommunitiesRequest': ListCommunitiesRequest$json,
  '.dzeroth.communities.v1.ListCommunitiesResponse':
      ListCommunitiesResponse$json,
  '.dzeroth.communities.v1.ListMyCommunitiesRequest':
      ListMyCommunitiesRequest$json,
  '.dzeroth.communities.v1.ListMyCommunitiesResponse':
      ListMyCommunitiesResponse$json,
  '.dzeroth.communities.v1.JoinCommunityRequest': JoinCommunityRequest$json,
  '.dzeroth.communities.v1.JoinCommunityResponse': JoinCommunityResponse$json,
  '.dzeroth.communities.v1.LeaveCommunityRequest': LeaveCommunityRequest$json,
  '.dzeroth.communities.v1.LeaveCommunityResponse': LeaveCommunityResponse$json,
  '.dzeroth.communities.v1.ListCommunityMembersRequest':
      ListCommunityMembersRequest$json,
  '.dzeroth.communities.v1.ListCommunityMembersResponse':
      ListCommunityMembersResponse$json,
  '.dzeroth.communities.v1.CommunityMember': CommunityMember$json,
  '.dzeroth.communities.v1.HideCommunityPostRequest':
      HideCommunityPostRequest$json,
  '.dzeroth.communities.v1.HideCommunityPostResponse':
      HideCommunityPostResponse$json,
  '.dzeroth.communities.v1.RestoreCommunityPostRequest':
      RestoreCommunityPostRequest$json,
  '.dzeroth.communities.v1.RestoreCommunityPostResponse':
      RestoreCommunityPostResponse$json,
  '.dzeroth.communities.v1.SetMemberRoleRequest': SetMemberRoleRequest$json,
  '.dzeroth.communities.v1.SetMemberRoleResponse': SetMemberRoleResponse$json,
  '.dzeroth.communities.v1.ListModerationLogRequest':
      ListModerationLogRequest$json,
  '.dzeroth.communities.v1.ListModerationLogResponse':
      ListModerationLogResponse$json,
  '.dzeroth.communities.v1.ModerationLogEntry': ModerationLogEntry$json,
};

/// Descriptor for `CommunityService`. Decode as a `google.protobuf.ServiceDescriptorProto`.
final $typed_data.Uint8List communityServiceDescriptor = $convert.base64Decode(
    'ChBDb21tdW5pdHlTZXJ2aWNlEnIKD0NyZWF0ZUNvbW11bml0eRIuLmR6ZXJvdGguY29tbXVuaX'
    'RpZXMudjEuQ3JlYXRlQ29tbXVuaXR5UmVxdWVzdBovLmR6ZXJvdGguY29tbXVuaXRpZXMudjEu'
    'Q3JlYXRlQ29tbXVuaXR5UmVzcG9uc2UScgoPVXBkYXRlQ29tbXVuaXR5Ei4uZHplcm90aC5jb2'
    '1tdW5pdGllcy52MS5VcGRhdGVDb21tdW5pdHlSZXF1ZXN0Gi8uZHplcm90aC5jb21tdW5pdGll'
    'cy52MS5VcGRhdGVDb21tdW5pdHlSZXNwb25zZRJuCgxHZXRDb21tdW5pdHkSKy5kemVyb3RoLm'
    'NvbW11bml0aWVzLnYxLkdldENvbW11bml0eVJlcXVlc3QaLC5kemVyb3RoLmNvbW11bml0aWVz'
    'LnYxLkdldENvbW11bml0eVJlc3BvbnNlIgOQAgESdwoPTGlzdENvbW11bml0aWVzEi4uZHplcm'
    '90aC5jb21tdW5pdGllcy52MS5MaXN0Q29tbXVuaXRpZXNSZXF1ZXN0Gi8uZHplcm90aC5jb21t'
    'dW5pdGllcy52MS5MaXN0Q29tbXVuaXRpZXNSZXNwb25zZSIDkAIBEn0KEUxpc3RNeUNvbW11bm'
    'l0aWVzEjAuZHplcm90aC5jb21tdW5pdGllcy52MS5MaXN0TXlDb21tdW5pdGllc1JlcXVlc3Qa'
    'MS5kemVyb3RoLmNvbW11bml0aWVzLnYxLkxpc3RNeUNvbW11bml0aWVzUmVzcG9uc2UiA5ACAR'
    'JsCg1Kb2luQ29tbXVuaXR5EiwuZHplcm90aC5jb21tdW5pdGllcy52MS5Kb2luQ29tbXVuaXR5'
    'UmVxdWVzdBotLmR6ZXJvdGguY29tbXVuaXRpZXMudjEuSm9pbkNvbW11bml0eVJlc3BvbnNlEm'
    '8KDkxlYXZlQ29tbXVuaXR5Ei0uZHplcm90aC5jb21tdW5pdGllcy52MS5MZWF2ZUNvbW11bml0'
    'eVJlcXVlc3QaLi5kemVyb3RoLmNvbW11bml0aWVzLnYxLkxlYXZlQ29tbXVuaXR5UmVzcG9uc2'
    'UShgEKFExpc3RDb21tdW5pdHlNZW1iZXJzEjMuZHplcm90aC5jb21tdW5pdGllcy52MS5MaXN0'
    'Q29tbXVuaXR5TWVtYmVyc1JlcXVlc3QaNC5kemVyb3RoLmNvbW11bml0aWVzLnYxLkxpc3RDb2'
    '1tdW5pdHlNZW1iZXJzUmVzcG9uc2UiA5ACARJ4ChFIaWRlQ29tbXVuaXR5UG9zdBIwLmR6ZXJv'
    'dGguY29tbXVuaXRpZXMudjEuSGlkZUNvbW11bml0eVBvc3RSZXF1ZXN0GjEuZHplcm90aC5jb2'
    '1tdW5pdGllcy52MS5IaWRlQ29tbXVuaXR5UG9zdFJlc3BvbnNlEoEBChRSZXN0b3JlQ29tbXVu'
    'aXR5UG9zdBIzLmR6ZXJvdGguY29tbXVuaXRpZXMudjEuUmVzdG9yZUNvbW11bml0eVBvc3RSZX'
    'F1ZXN0GjQuZHplcm90aC5jb21tdW5pdGllcy52MS5SZXN0b3JlQ29tbXVuaXR5UG9zdFJlc3Bv'
    'bnNlEmwKDVNldE1lbWJlclJvbGUSLC5kemVyb3RoLmNvbW11bml0aWVzLnYxLlNldE1lbWJlcl'
    'JvbGVSZXF1ZXN0Gi0uZHplcm90aC5jb21tdW5pdGllcy52MS5TZXRNZW1iZXJSb2xlUmVzcG9u'
    'c2USfQoRTGlzdE1vZGVyYXRpb25Mb2cSMC5kemVyb3RoLmNvbW11bml0aWVzLnYxLkxpc3RNb2'
    'RlcmF0aW9uTG9nUmVxdWVzdBoxLmR6ZXJvdGguY29tbXVuaXRpZXMudjEuTGlzdE1vZGVyYXRp'
    'b25Mb2dSZXNwb25zZSIDkAIB');
