// This is a generated file - do not edit.
//
// Generated from dzeroth/messaging/v1/messaging.proto.

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
import '../../posts/v1/posts.pbjson.dart' as $2;

@$core.Deprecated('Use conversationKindDescriptor instead')
const ConversationKind$json = {
  '1': 'ConversationKind',
  '2': [
    {'1': 'CONVERSATION_KIND_UNSPECIFIED', '2': 0},
    {'1': 'CONVERSATION_KIND_DIRECT', '2': 1},
  ],
};

/// Descriptor for `ConversationKind`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List conversationKindDescriptor = $convert.base64Decode(
    'ChBDb252ZXJzYXRpb25LaW5kEiEKHUNPTlZFUlNBVElPTl9LSU5EX1VOU1BFQ0lGSUVEEAASHA'
    'oYQ09OVkVSU0FUSU9OX0tJTkRfRElSRUNUEAE=');

@$core.Deprecated('Use conversationStateDescriptor instead')
const ConversationState$json = {
  '1': 'ConversationState',
  '2': [
    {'1': 'CONVERSATION_STATE_UNSPECIFIED', '2': 0},
    {'1': 'CONVERSATION_STATE_REQUEST', '2': 1},
    {'1': 'CONVERSATION_STATE_ACCEPTED', '2': 2},
  ],
};

/// Descriptor for `ConversationState`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List conversationStateDescriptor = $convert.base64Decode(
    'ChFDb252ZXJzYXRpb25TdGF0ZRIiCh5DT05WRVJTQVRJT05fU1RBVEVfVU5TUEVDSUZJRUQQAB'
    'IeChpDT05WRVJTQVRJT05fU1RBVEVfUkVRVUVTVBABEh8KG0NPTlZFUlNBVElPTl9TVEFURV9B'
    'Q0NFUFRFRBAC');

@$core.Deprecated('Use folderDescriptor instead')
const Folder$json = {
  '1': 'Folder',
  '2': [
    {'1': 'FOLDER_UNSPECIFIED', '2': 0},
    {'1': 'FOLDER_INBOX', '2': 1},
    {'1': 'FOLDER_REQUESTS', '2': 2},
  ],
};

/// Descriptor for `Folder`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List folderDescriptor = $convert.base64Decode(
    'CgZGb2xkZXISFgoSRk9MREVSX1VOU1BFQ0lGSUVEEAASEAoMRk9MREVSX0lOQk9YEAESEwoPRk'
    '9MREVSX1JFUVVFU1RTEAI=');

@$core.Deprecated('Use conversationEncryptionDescriptor instead')
const ConversationEncryption$json = {
  '1': 'ConversationEncryption',
  '2': [
    {'1': 'CONVERSATION_ENCRYPTION_UNSPECIFIED', '2': 0},
    {'1': 'CONVERSATION_ENCRYPTION_NONE', '2': 1},
    {'1': 'CONVERSATION_ENCRYPTION_MLS', '2': 2},
  ],
};

/// Descriptor for `ConversationEncryption`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List conversationEncryptionDescriptor = $convert.base64Decode(
    'ChZDb252ZXJzYXRpb25FbmNyeXB0aW9uEicKI0NPTlZFUlNBVElPTl9FTkNSWVBUSU9OX1VOU1'
    'BFQ0lGSUVEEAASIAocQ09OVkVSU0FUSU9OX0VOQ1JZUFRJT05fTk9ORRABEh8KG0NPTlZFUlNB'
    'VElPTl9FTkNSWVBUSU9OX01MUxAC');

@$core.Deprecated('Use messageStateDescriptor instead')
const MessageState$json = {
  '1': 'MessageState',
  '2': [
    {'1': 'MESSAGE_STATE_UNSPECIFIED', '2': 0},
    {'1': 'MESSAGE_STATE_VISIBLE', '2': 1},
    {'1': 'MESSAGE_STATE_DELETED_ACCOUNT', '2': 2},
    {'1': 'MESSAGE_STATE_REMOVED', '2': 3},
  ],
};

/// Descriptor for `MessageState`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List messageStateDescriptor = $convert.base64Decode(
    'CgxNZXNzYWdlU3RhdGUSHQoZTUVTU0FHRV9TVEFURV9VTlNQRUNJRklFRBAAEhkKFU1FU1NBR0'
    'VfU1RBVEVfVklTSUJMRRABEiEKHU1FU1NBR0VfU1RBVEVfREVMRVRFRF9BQ0NPVU5UEAISGQoV'
    'TUVTU0FHRV9TVEFURV9SRU1PVkVEEAM=');

@$core.Deprecated('Use messageSuggestionReasonDescriptor instead')
const MessageSuggestionReason$json = {
  '1': 'MessageSuggestionReason',
  '2': [
    {'1': 'MESSAGE_SUGGESTION_REASON_UNSPECIFIED', '2': 0},
    {'1': 'MESSAGE_SUGGESTION_REASON_RECENT_CONVERSATION', '2': 1},
    {'1': 'MESSAGE_SUGGESTION_REASON_MET_ON_PLAN', '2': 2},
    {'1': 'MESSAGE_SUGGESTION_REASON_MUTUAL_FOLLOW', '2': 3},
    {'1': 'MESSAGE_SUGGESTION_REASON_COMMUNITY_MEMBER', '2': 4},
  ],
};

/// Descriptor for `MessageSuggestionReason`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List messageSuggestionReasonDescriptor = $convert.base64Decode(
    'ChdNZXNzYWdlU3VnZ2VzdGlvblJlYXNvbhIpCiVNRVNTQUdFX1NVR0dFU1RJT05fUkVBU09OX1'
    'VOU1BFQ0lGSUVEEAASMQotTUVTU0FHRV9TVUdHRVNUSU9OX1JFQVNPTl9SRUNFTlRfQ09OVkVS'
    'U0FUSU9OEAESKQolTUVTU0FHRV9TVUdHRVNUSU9OX1JFQVNPTl9NRVRfT05fUExBThACEisKJ0'
    '1FU1NBR0VfU1VHR0VTVElPTl9SRUFTT05fTVVUVUFMX0ZPTExPVxADEi4KKk1FU1NBR0VfU1VH'
    'R0VTVElPTl9SRUFTT05fQ09NTVVOSVRZX01FTUJFUhAE');

@$core.Deprecated('Use epochMessageOrderDescriptor instead')
const EpochMessageOrder$json = {
  '1': 'EpochMessageOrder',
  '2': [
    {'1': 'EPOCH_MESSAGE_ORDER_UNSPECIFIED', '2': 0},
    {'1': 'EPOCH_MESSAGE_ORDER_CREATED_AT', '2': 1},
  ],
};

/// Descriptor for `EpochMessageOrder`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List epochMessageOrderDescriptor = $convert.base64Decode(
    'ChFFcG9jaE1lc3NhZ2VPcmRlchIjCh9FUE9DSF9NRVNTQUdFX09SREVSX1VOU1BFQ0lGSUVEEA'
    'ASIgoeRVBPQ0hfTUVTU0FHRV9PUkRFUl9DUkVBVEVEX0FUEAE=');

@$core.Deprecated('Use conversationDescriptor instead')
const Conversation$json = {
  '1': 'Conversation',
  '2': [
    {'1': 'id', '3': 1, '4': 1, '5': 9, '10': 'id'},
    {
      '1': 'kind',
      '3': 2,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.messaging.v1.ConversationKind',
      '10': 'kind'
    },
    {
      '1': 'peer',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.common.v1.AuthorSnapshot',
      '10': 'peer'
    },
    {
      '1': 'state',
      '3': 4,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.messaging.v1.ConversationState',
      '10': 'state'
    },
    {
      '1': 'folder',
      '3': 5,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.messaging.v1.Folder',
      '10': 'folder'
    },
    {
      '1': 'last_message',
      '3': 6,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.messaging.v1.MessagePreview',
      '10': 'lastMessage'
    },
    {'1': 'unread_count', '3': 7, '4': 1, '5': 3, '10': 'unreadCount'},
    {'1': 'can_reply', '3': 8, '4': 1, '5': 8, '10': 'canReply'},
    {'1': 'silent', '3': 9, '4': 1, '5': 8, '10': 'silent'},
    {
      '1': 'updated_at',
      '3': 10,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '10': 'updatedAt'
    },
    {
      '1': 'peer_read_at',
      '3': 11,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '10': 'peerReadAt'
    },
    {
      '1': 'encryption',
      '3': 12,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.messaging.v1.ConversationEncryption',
      '10': 'encryption'
    },
    {'1': 'mls_generation', '3': 13, '4': 1, '5': 4, '10': 'mlsGeneration'},
    {'1': 'mls_epoch', '3': 14, '4': 1, '5': 4, '10': 'mlsEpoch'},
  ],
};

/// Descriptor for `Conversation`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List conversationDescriptor = $convert.base64Decode(
    'CgxDb252ZXJzYXRpb24SDgoCaWQYASABKAlSAmlkEjoKBGtpbmQYAiABKA4yJi5kemVyb3RoLm'
    '1lc3NhZ2luZy52MS5Db252ZXJzYXRpb25LaW5kUgRraW5kEjUKBHBlZXIYAyABKAsyIS5kemVy'
    'b3RoLmNvbW1vbi52MS5BdXRob3JTbmFwc2hvdFIEcGVlchI9CgVzdGF0ZRgEIAEoDjInLmR6ZX'
    'JvdGgubWVzc2FnaW5nLnYxLkNvbnZlcnNhdGlvblN0YXRlUgVzdGF0ZRI0CgZmb2xkZXIYBSAB'
    'KA4yHC5kemVyb3RoLm1lc3NhZ2luZy52MS5Gb2xkZXJSBmZvbGRlchJHCgxsYXN0X21lc3NhZ2'
    'UYBiABKAsyJC5kemVyb3RoLm1lc3NhZ2luZy52MS5NZXNzYWdlUHJldmlld1ILbGFzdE1lc3Nh'
    'Z2USIQoMdW5yZWFkX2NvdW50GAcgASgDUgt1bnJlYWRDb3VudBIbCgljYW5fcmVwbHkYCCABKA'
    'hSCGNhblJlcGx5EhYKBnNpbGVudBgJIAEoCFIGc2lsZW50EjkKCnVwZGF0ZWRfYXQYCiABKAsy'
    'Gi5nb29nbGUucHJvdG9idWYuVGltZXN0YW1wUgl1cGRhdGVkQXQSPAoMcGVlcl9yZWFkX2F0GA'
    'sgASgLMhouZ29vZ2xlLnByb3RvYnVmLlRpbWVzdGFtcFIKcGVlclJlYWRBdBJMCgplbmNyeXB0'
    'aW9uGAwgASgOMiwuZHplcm90aC5tZXNzYWdpbmcudjEuQ29udmVyc2F0aW9uRW5jcnlwdGlvbl'
    'IKZW5jcnlwdGlvbhIlCg5tbHNfZ2VuZXJhdGlvbhgNIAEoBFINbWxzR2VuZXJhdGlvbhIbCglt'
    'bHNfZXBvY2gYDiABKARSCG1sc0Vwb2No');

@$core.Deprecated('Use messagePreviewDescriptor instead')
const MessagePreview$json = {
  '1': 'MessagePreview',
  '2': [
    {'1': 'snippet', '3': 1, '4': 1, '5': 9, '10': 'snippet'},
    {'1': 'from_self', '3': 2, '4': 1, '5': 8, '10': 'fromSelf'},
    {
      '1': 'state',
      '3': 3,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.messaging.v1.MessageState',
      '10': 'state'
    },
    {
      '1': 'created_at',
      '3': 4,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '10': 'createdAt'
    },
    {'1': 'shared_post', '3': 5, '4': 1, '5': 8, '10': 'sharedPost'},
    {'1': 'encrypted', '3': 6, '4': 1, '5': 8, '10': 'encrypted'},
  ],
};

/// Descriptor for `MessagePreview`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List messagePreviewDescriptor = $convert.base64Decode(
    'Cg5NZXNzYWdlUHJldmlldxIYCgdzbmlwcGV0GAEgASgJUgdzbmlwcGV0EhsKCWZyb21fc2VsZh'
    'gCIAEoCFIIZnJvbVNlbGYSOAoFc3RhdGUYAyABKA4yIi5kemVyb3RoLm1lc3NhZ2luZy52MS5N'
    'ZXNzYWdlU3RhdGVSBXN0YXRlEjkKCmNyZWF0ZWRfYXQYBCABKAsyGi5nb29nbGUucHJvdG9idW'
    'YuVGltZXN0YW1wUgljcmVhdGVkQXQSHwoLc2hhcmVkX3Bvc3QYBSABKAhSCnNoYXJlZFBvc3QS'
    'HAoJZW5jcnlwdGVkGAYgASgIUgllbmNyeXB0ZWQ=');

@$core.Deprecated('Use messageDescriptor instead')
const Message$json = {
  '1': 'Message',
  '2': [
    {'1': 'id', '3': 1, '4': 1, '5': 9, '10': 'id'},
    {'1': 'conversation_id', '3': 2, '4': 1, '5': 9, '10': 'conversationId'},
    {'1': 'from_self', '3': 3, '4': 1, '5': 8, '10': 'fromSelf'},
    {'1': 'text', '3': 4, '4': 1, '5': 9, '10': 'text'},
    {
      '1': 'state',
      '3': 5,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.messaging.v1.MessageState',
      '10': 'state'
    },
    {
      '1': 'created_at',
      '3': 6,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '10': 'createdAt'
    },
    {
      '1': 'shared_post',
      '3': 8,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.posts.v1.EmbeddedPost',
      '10': 'sharedPost'
    },
    {'1': 'ciphertext', '3': 9, '4': 1, '5': 12, '10': 'ciphertext'},
    {'1': 'mls_generation', '3': 10, '4': 1, '5': 4, '10': 'mlsGeneration'},
    {'1': 'mls_epoch', '3': 11, '4': 1, '5': 4, '10': 'mlsEpoch'},
    {
      '1': 'report_commitment',
      '3': 12,
      '4': 1,
      '5': 12,
      '10': 'reportCommitment'
    },
    {
      '1': 'ciphertext_removed',
      '3': 13,
      '4': 1,
      '5': 8,
      '10': 'ciphertextRemoved'
    },
  ],
  '9': [
    {'1': 7, '2': 8},
  ],
};

/// Descriptor for `Message`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List messageDescriptor = $convert.base64Decode(
    'CgdNZXNzYWdlEg4KAmlkGAEgASgJUgJpZBInCg9jb252ZXJzYXRpb25faWQYAiABKAlSDmNvbn'
    'ZlcnNhdGlvbklkEhsKCWZyb21fc2VsZhgDIAEoCFIIZnJvbVNlbGYSEgoEdGV4dBgEIAEoCVIE'
    'dGV4dBI4CgVzdGF0ZRgFIAEoDjIiLmR6ZXJvdGgubWVzc2FnaW5nLnYxLk1lc3NhZ2VTdGF0ZV'
    'IFc3RhdGUSOQoKY3JlYXRlZF9hdBgGIAEoCzIaLmdvb2dsZS5wcm90b2J1Zi5UaW1lc3RhbXBS'
    'CWNyZWF0ZWRBdBI/CgtzaGFyZWRfcG9zdBgIIAEoCzIeLmR6ZXJvdGgucG9zdHMudjEuRW1iZW'
    'RkZWRQb3N0UgpzaGFyZWRQb3N0Eh4KCmNpcGhlcnRleHQYCSABKAxSCmNpcGhlcnRleHQSJQoO'
    'bWxzX2dlbmVyYXRpb24YCiABKARSDW1sc0dlbmVyYXRpb24SGwoJbWxzX2Vwb2NoGAsgASgEUg'
    'htbHNFcG9jaBIrChFyZXBvcnRfY29tbWl0bWVudBgMIAEoDFIQcmVwb3J0Q29tbWl0bWVudBIt'
    'ChJjaXBoZXJ0ZXh0X3JlbW92ZWQYDSABKAhSEWNpcGhlcnRleHRSZW1vdmVkSgQIBxAI');

@$core.Deprecated('Use messageContentDescriptor instead')
const MessageContent$json = {
  '1': 'MessageContent',
  '2': [
    {'1': 'text', '3': 1, '4': 1, '5': 9, '10': 'text'},
    {'1': 'shared_post_id', '3': 2, '4': 1, '5': 9, '10': 'sharedPostId'},
    {'1': 'report_key', '3': 3, '4': 1, '5': 12, '10': 'reportKey'},
  ],
};

/// Descriptor for `MessageContent`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List messageContentDescriptor = $convert.base64Decode(
    'Cg5NZXNzYWdlQ29udGVudBISCgR0ZXh0GAEgASgJUgR0ZXh0EiQKDnNoYXJlZF9wb3N0X2lkGA'
    'IgASgJUgxzaGFyZWRQb3N0SWQSHQoKcmVwb3J0X2tleRgDIAEoDFIJcmVwb3J0S2V5');

@$core.Deprecated('Use sendMessageRequestDescriptor instead')
const SendMessageRequest$json = {
  '1': 'SendMessageRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {
      '1': 'conversation_id',
      '3': 2,
      '4': 1,
      '5': 9,
      '9': 0,
      '10': 'conversationId'
    },
    {
      '1': 'recipient_user_id',
      '3': 3,
      '4': 1,
      '5': 9,
      '8': {},
      '9': 0,
      '10': 'recipientUserId'
    },
    {'1': 'text', '3': 4, '4': 1, '5': 9, '10': 'text'},
    {'1': 'shared_post_id', '3': 5, '4': 1, '5': 9, '10': 'sharedPostId'},
    {'1': 'ciphertext', '3': 6, '4': 1, '5': 12, '10': 'ciphertext'},
    {'1': 'mls_generation', '3': 7, '4': 1, '5': 4, '10': 'mlsGeneration'},
    {'1': 'mls_epoch', '3': 8, '4': 1, '5': 4, '10': 'mlsEpoch'},
    {
      '1': 'report_commitment',
      '3': 9,
      '4': 1,
      '5': 12,
      '10': 'reportCommitment'
    },
    {
      '1': 'mls_init',
      '3': 10,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.messaging.v1.MlsInit',
      '10': 'mlsInit'
    },
  ],
  '8': [
    {'1': 'target'},
  ],
};

/// Descriptor for `SendMessageRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List sendMessageRequestDescriptor = $convert.base64Decode(
    'ChJTZW5kTWVzc2FnZVJlcXVlc3QSJwoPaWRlbXBvdGVuY3lfa2V5GAEgASgJUg5pZGVtcG90ZW'
    '5jeUtleRIpCg9jb252ZXJzYXRpb25faWQYAiABKAlIAFIOY29udmVyc2F0aW9uSWQSMgoRcmVj'
    'aXBpZW50X3VzZXJfaWQYAyABKAlCBOjgGAFIAFIPcmVjaXBpZW50VXNlcklkEhIKBHRleHQYBC'
    'ABKAlSBHRleHQSJAoOc2hhcmVkX3Bvc3RfaWQYBSABKAlSDHNoYXJlZFBvc3RJZBIeCgpjaXBo'
    'ZXJ0ZXh0GAYgASgMUgpjaXBoZXJ0ZXh0EiUKDm1sc19nZW5lcmF0aW9uGAcgASgEUg1tbHNHZW'
    '5lcmF0aW9uEhsKCW1sc19lcG9jaBgIIAEoBFIIbWxzRXBvY2gSKwoRcmVwb3J0X2NvbW1pdG1l'
    'bnQYCSABKAxSEHJlcG9ydENvbW1pdG1lbnQSOAoIbWxzX2luaXQYCiABKAsyHS5kemVyb3RoLm'
    '1lc3NhZ2luZy52MS5NbHNJbml0UgdtbHNJbml0QggKBnRhcmdldA==');

@$core.Deprecated('Use mlsInitDescriptor instead')
const MlsInit$json = {
  '1': 'MlsInit',
  '2': [
    {'1': 'commit', '3': 1, '4': 1, '5': 12, '10': 'commit'},
    {'1': 'welcome', '3': 2, '4': 1, '5': 12, '10': 'welcome'},
    {
      '1': 'welcome_device_ids',
      '3': 3,
      '4': 3,
      '5': 9,
      '10': 'welcomeDeviceIds'
    },
  ],
};

/// Descriptor for `MlsInit`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List mlsInitDescriptor = $convert.base64Decode(
    'CgdNbHNJbml0EhYKBmNvbW1pdBgBIAEoDFIGY29tbWl0EhgKB3dlbGNvbWUYAiABKAxSB3dlbG'
    'NvbWUSLAoSd2VsY29tZV9kZXZpY2VfaWRzGAMgAygJUhB3ZWxjb21lRGV2aWNlSWRz');

@$core.Deprecated('Use sendMessageResponseDescriptor instead')
const SendMessageResponse$json = {
  '1': 'SendMessageResponse',
  '2': [
    {
      '1': 'message',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.messaging.v1.Message',
      '10': 'message'
    },
    {
      '1': 'conversation',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.messaging.v1.Conversation',
      '10': 'conversation'
    },
  ],
};

/// Descriptor for `SendMessageResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List sendMessageResponseDescriptor = $convert.base64Decode(
    'ChNTZW5kTWVzc2FnZVJlc3BvbnNlEjcKB21lc3NhZ2UYASABKAsyHS5kemVyb3RoLm1lc3NhZ2'
    'luZy52MS5NZXNzYWdlUgdtZXNzYWdlEkYKDGNvbnZlcnNhdGlvbhgCIAEoCzIiLmR6ZXJvdGgu'
    'bWVzc2FnaW5nLnYxLkNvbnZlcnNhdGlvblIMY29udmVyc2F0aW9u');

@$core.Deprecated('Use checkPostShareRequestDescriptor instead')
const CheckPostShareRequest$json = {
  '1': 'CheckPostShareRequest',
  '2': [
    {'1': 'post_id', '3': 1, '4': 1, '5': 9, '10': 'postId'},
  ],
};

/// Descriptor for `CheckPostShareRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List checkPostShareRequestDescriptor =
    $convert.base64Decode(
        'ChVDaGVja1Bvc3RTaGFyZVJlcXVlc3QSFwoHcG9zdF9pZBgBIAEoCVIGcG9zdElk');

@$core.Deprecated('Use checkPostShareResponseDescriptor instead')
const CheckPostShareResponse$json = {
  '1': 'CheckPostShareResponse',
  '2': [
    {'1': 'shared_post_id', '3': 1, '4': 1, '5': 9, '10': 'sharedPostId'},
  ],
};

/// Descriptor for `CheckPostShareResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List checkPostShareResponseDescriptor =
    $convert.base64Decode(
        'ChZDaGVja1Bvc3RTaGFyZVJlc3BvbnNlEiQKDnNoYXJlZF9wb3N0X2lkGAEgASgJUgxzaGFyZW'
        'RQb3N0SWQ=');

@$core.Deprecated('Use listConversationsRequestDescriptor instead')
const ListConversationsRequest$json = {
  '1': 'ListConversationsRequest',
  '2': [
    {
      '1': 'folder',
      '3': 1,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.messaging.v1.Folder',
      '10': 'folder'
    },
    {'1': 'page_size', '3': 2, '4': 1, '5': 5, '10': 'pageSize'},
    {'1': 'page_token', '3': 3, '4': 1, '5': 9, '10': 'pageToken'},
    {'1': 'since_token', '3': 4, '4': 1, '5': 9, '10': 'sinceToken'},
  ],
};

/// Descriptor for `ListConversationsRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listConversationsRequestDescriptor = $convert.base64Decode(
    'ChhMaXN0Q29udmVyc2F0aW9uc1JlcXVlc3QSNAoGZm9sZGVyGAEgASgOMhwuZHplcm90aC5tZX'
    'NzYWdpbmcudjEuRm9sZGVyUgZmb2xkZXISGwoJcGFnZV9zaXplGAIgASgFUghwYWdlU2l6ZRId'
    'CgpwYWdlX3Rva2VuGAMgASgJUglwYWdlVG9rZW4SHwoLc2luY2VfdG9rZW4YBCABKAlSCnNpbm'
    'NlVG9rZW4=');

@$core.Deprecated('Use listConversationsResponseDescriptor instead')
const ListConversationsResponse$json = {
  '1': 'ListConversationsResponse',
  '2': [
    {
      '1': 'conversations',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.messaging.v1.Conversation',
      '10': 'conversations'
    },
    {'1': 'next_page_token', '3': 2, '4': 1, '5': 9, '10': 'nextPageToken'},
    {'1': 'since_token', '3': 3, '4': 1, '5': 9, '10': 'sinceToken'},
    {'1': 'request_count', '3': 4, '4': 1, '5': 3, '10': 'requestCount'},
  ],
};

/// Descriptor for `ListConversationsResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listConversationsResponseDescriptor = $convert.base64Decode(
    'ChlMaXN0Q29udmVyc2F0aW9uc1Jlc3BvbnNlEkgKDWNvbnZlcnNhdGlvbnMYASADKAsyIi5kem'
    'Vyb3RoLm1lc3NhZ2luZy52MS5Db252ZXJzYXRpb25SDWNvbnZlcnNhdGlvbnMSJgoPbmV4dF9w'
    'YWdlX3Rva2VuGAIgASgJUg1uZXh0UGFnZVRva2VuEh8KC3NpbmNlX3Rva2VuGAMgASgJUgpzaW'
    '5jZVRva2VuEiMKDXJlcXVlc3RfY291bnQYBCABKANSDHJlcXVlc3RDb3VudA==');

@$core.Deprecated('Use listMessagesRequestDescriptor instead')
const ListMessagesRequest$json = {
  '1': 'ListMessagesRequest',
  '2': [
    {'1': 'conversation_id', '3': 1, '4': 1, '5': 9, '10': 'conversationId'},
    {'1': 'page_size', '3': 2, '4': 1, '5': 5, '10': 'pageSize'},
    {'1': 'page_token', '3': 3, '4': 1, '5': 9, '10': 'pageToken'},
    {'1': 'since_token', '3': 4, '4': 1, '5': 9, '10': 'sinceToken'},
  ],
};

/// Descriptor for `ListMessagesRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listMessagesRequestDescriptor = $convert.base64Decode(
    'ChNMaXN0TWVzc2FnZXNSZXF1ZXN0EicKD2NvbnZlcnNhdGlvbl9pZBgBIAEoCVIOY29udmVyc2'
    'F0aW9uSWQSGwoJcGFnZV9zaXplGAIgASgFUghwYWdlU2l6ZRIdCgpwYWdlX3Rva2VuGAMgASgJ'
    'UglwYWdlVG9rZW4SHwoLc2luY2VfdG9rZW4YBCABKAlSCnNpbmNlVG9rZW4=');

@$core.Deprecated('Use listMessagesResponseDescriptor instead')
const ListMessagesResponse$json = {
  '1': 'ListMessagesResponse',
  '2': [
    {
      '1': 'messages',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.messaging.v1.Message',
      '10': 'messages'
    },
    {
      '1': 'conversation',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.messaging.v1.Conversation',
      '10': 'conversation'
    },
    {'1': 'next_page_token', '3': 3, '4': 1, '5': 9, '10': 'nextPageToken'},
    {'1': 'since_token', '3': 4, '4': 1, '5': 9, '10': 'sinceToken'},
    {'1': 'gap_page_token', '3': 5, '4': 1, '5': 9, '10': 'gapPageToken'},
  ],
};

/// Descriptor for `ListMessagesResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listMessagesResponseDescriptor = $convert.base64Decode(
    'ChRMaXN0TWVzc2FnZXNSZXNwb25zZRI5CghtZXNzYWdlcxgBIAMoCzIdLmR6ZXJvdGgubWVzc2'
    'FnaW5nLnYxLk1lc3NhZ2VSCG1lc3NhZ2VzEkYKDGNvbnZlcnNhdGlvbhgCIAEoCzIiLmR6ZXJv'
    'dGgubWVzc2FnaW5nLnYxLkNvbnZlcnNhdGlvblIMY29udmVyc2F0aW9uEiYKD25leHRfcGFnZV'
    '90b2tlbhgDIAEoCVINbmV4dFBhZ2VUb2tlbhIfCgtzaW5jZV90b2tlbhgEIAEoCVIKc2luY2VU'
    'b2tlbhIkCg5nYXBfcGFnZV90b2tlbhgFIAEoCVIMZ2FwUGFnZVRva2Vu');

@$core.Deprecated('Use markConversationReadRequestDescriptor instead')
const MarkConversationReadRequest$json = {
  '1': 'MarkConversationReadRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'conversation_id', '3': 2, '4': 1, '5': 9, '10': 'conversationId'},
  ],
};

/// Descriptor for `MarkConversationReadRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List markConversationReadRequestDescriptor =
    $convert.base64Decode(
        'ChtNYXJrQ29udmVyc2F0aW9uUmVhZFJlcXVlc3QSJwoPaWRlbXBvdGVuY3lfa2V5GAEgASgJUg'
        '5pZGVtcG90ZW5jeUtleRInCg9jb252ZXJzYXRpb25faWQYAiABKAlSDmNvbnZlcnNhdGlvbklk');

@$core.Deprecated('Use markConversationReadResponseDescriptor instead')
const MarkConversationReadResponse$json = {
  '1': 'MarkConversationReadResponse',
};

/// Descriptor for `MarkConversationReadResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List markConversationReadResponseDescriptor =
    $convert.base64Decode('ChxNYXJrQ29udmVyc2F0aW9uUmVhZFJlc3BvbnNl');

@$core.Deprecated('Use acceptMessageRequestRequestDescriptor instead')
const AcceptMessageRequestRequest$json = {
  '1': 'AcceptMessageRequestRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'conversation_id', '3': 2, '4': 1, '5': 9, '10': 'conversationId'},
  ],
};

/// Descriptor for `AcceptMessageRequestRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List acceptMessageRequestRequestDescriptor =
    $convert.base64Decode(
        'ChtBY2NlcHRNZXNzYWdlUmVxdWVzdFJlcXVlc3QSJwoPaWRlbXBvdGVuY3lfa2V5GAEgASgJUg'
        '5pZGVtcG90ZW5jeUtleRInCg9jb252ZXJzYXRpb25faWQYAiABKAlSDmNvbnZlcnNhdGlvbklk');

@$core.Deprecated('Use acceptMessageRequestResponseDescriptor instead')
const AcceptMessageRequestResponse$json = {
  '1': 'AcceptMessageRequestResponse',
};

/// Descriptor for `AcceptMessageRequestResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List acceptMessageRequestResponseDescriptor =
    $convert.base64Decode('ChxBY2NlcHRNZXNzYWdlUmVxdWVzdFJlc3BvbnNl');

@$core.Deprecated('Use deleteConversationRequestDescriptor instead')
const DeleteConversationRequest$json = {
  '1': 'DeleteConversationRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'conversation_id', '3': 2, '4': 1, '5': 9, '10': 'conversationId'},
  ],
};

/// Descriptor for `DeleteConversationRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List deleteConversationRequestDescriptor = $convert.base64Decode(
    'ChlEZWxldGVDb252ZXJzYXRpb25SZXF1ZXN0EicKD2lkZW1wb3RlbmN5X2tleRgBIAEoCVIOaW'
    'RlbXBvdGVuY3lLZXkSJwoPY29udmVyc2F0aW9uX2lkGAIgASgJUg5jb252ZXJzYXRpb25JZA==');

@$core.Deprecated('Use deleteConversationResponseDescriptor instead')
const DeleteConversationResponse$json = {
  '1': 'DeleteConversationResponse',
};

/// Descriptor for `DeleteConversationResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List deleteConversationResponseDescriptor =
    $convert.base64Decode('ChpEZWxldGVDb252ZXJzYXRpb25SZXNwb25zZQ==');

@$core.Deprecated('Use listMessageSuggestionsRequestDescriptor instead')
const ListMessageSuggestionsRequest$json = {
  '1': 'ListMessageSuggestionsRequest',
  '2': [
    {'1': 'limit', '3': 1, '4': 1, '5': 5, '10': 'limit'},
  ],
};

/// Descriptor for `ListMessageSuggestionsRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listMessageSuggestionsRequestDescriptor =
    $convert.base64Decode(
        'Ch1MaXN0TWVzc2FnZVN1Z2dlc3Rpb25zUmVxdWVzdBIUCgVsaW1pdBgBIAEoBVIFbGltaXQ=');

@$core.Deprecated('Use messageSuggestionDescriptor instead')
const MessageSuggestion$json = {
  '1': 'MessageSuggestion',
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
      '1': 'reason',
      '3': 2,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.messaging.v1.MessageSuggestionReason',
      '10': 'reason'
    },
    {
      '1': 'plan_activity',
      '3': 3,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.beacons.v1.BeaconActivity',
      '10': 'planActivity'
    },
    {'1': 'community_id', '3': 4, '4': 1, '5': 9, '10': 'communityId'},
    {'1': 'community_name', '3': 5, '4': 1, '5': 9, '10': 'communityName'},
  ],
};

/// Descriptor for `MessageSuggestion`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List messageSuggestionDescriptor = $convert.base64Decode(
    'ChFNZXNzYWdlU3VnZ2VzdGlvbhI1CgR1c2VyGAEgASgLMiEuZHplcm90aC5jb21tb24udjEuQX'
    'V0aG9yU25hcHNob3RSBHVzZXISRQoGcmVhc29uGAIgASgOMi0uZHplcm90aC5tZXNzYWdpbmcu'
    'djEuTWVzc2FnZVN1Z2dlc3Rpb25SZWFzb25SBnJlYXNvbhJHCg1wbGFuX2FjdGl2aXR5GAMgAS'
    'gOMiIuZHplcm90aC5iZWFjb25zLnYxLkJlYWNvbkFjdGl2aXR5UgxwbGFuQWN0aXZpdHkSIQoM'
    'Y29tbXVuaXR5X2lkGAQgASgJUgtjb21tdW5pdHlJZBIlCg5jb21tdW5pdHlfbmFtZRgFIAEoCV'
    'INY29tbXVuaXR5TmFtZQ==');

@$core.Deprecated('Use listMessageSuggestionsResponseDescriptor instead')
const ListMessageSuggestionsResponse$json = {
  '1': 'ListMessageSuggestionsResponse',
  '2': [
    {
      '1': 'suggestions',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.messaging.v1.MessageSuggestion',
      '10': 'suggestions'
    },
  ],
};

/// Descriptor for `ListMessageSuggestionsResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listMessageSuggestionsResponseDescriptor =
    $convert.base64Decode(
        'Ch5MaXN0TWVzc2FnZVN1Z2dlc3Rpb25zUmVzcG9uc2USSQoLc3VnZ2VzdGlvbnMYASADKAsyJy'
        '5kemVyb3RoLm1lc3NhZ2luZy52MS5NZXNzYWdlU3VnZ2VzdGlvblILc3VnZ2VzdGlvbnM=');

@$core.Deprecated('Use commitConversationRequestDescriptor instead')
const CommitConversationRequest$json = {
  '1': 'CommitConversationRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'conversation_id', '3': 2, '4': 1, '5': 9, '10': 'conversationId'},
    {'1': 'mls_generation', '3': 3, '4': 1, '5': 4, '10': 'mlsGeneration'},
    {'1': 'mls_epoch', '3': 4, '4': 1, '5': 4, '10': 'mlsEpoch'},
    {'1': 'commit', '3': 5, '4': 1, '5': 12, '10': 'commit'},
    {'1': 'welcome', '3': 6, '4': 1, '5': 12, '10': 'welcome'},
    {
      '1': 'welcome_device_ids',
      '3': 7,
      '4': 3,
      '5': 9,
      '10': 'welcomeDeviceIds'
    },
    {'1': 'reset', '3': 8, '4': 1, '5': 8, '10': 'reset'},
  ],
};

/// Descriptor for `CommitConversationRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List commitConversationRequestDescriptor = $convert.base64Decode(
    'ChlDb21taXRDb252ZXJzYXRpb25SZXF1ZXN0EicKD2lkZW1wb3RlbmN5X2tleRgBIAEoCVIOaW'
    'RlbXBvdGVuY3lLZXkSJwoPY29udmVyc2F0aW9uX2lkGAIgASgJUg5jb252ZXJzYXRpb25JZBIl'
    'Cg5tbHNfZ2VuZXJhdGlvbhgDIAEoBFINbWxzR2VuZXJhdGlvbhIbCgltbHNfZXBvY2gYBCABKA'
    'RSCG1sc0Vwb2NoEhYKBmNvbW1pdBgFIAEoDFIGY29tbWl0EhgKB3dlbGNvbWUYBiABKAxSB3dl'
    'bGNvbWUSLAoSd2VsY29tZV9kZXZpY2VfaWRzGAcgAygJUhB3ZWxjb21lRGV2aWNlSWRzEhQKBX'
    'Jlc2V0GAggASgIUgVyZXNldA==');

@$core.Deprecated('Use commitConversationResponseDescriptor instead')
const CommitConversationResponse$json = {
  '1': 'CommitConversationResponse',
  '2': [
    {'1': 'mls_generation', '3': 1, '4': 1, '5': 4, '10': 'mlsGeneration'},
    {'1': 'mls_epoch', '3': 2, '4': 1, '5': 4, '10': 'mlsEpoch'},
  ],
};

/// Descriptor for `CommitConversationResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List commitConversationResponseDescriptor =
    $convert.base64Decode(
        'ChpDb21taXRDb252ZXJzYXRpb25SZXNwb25zZRIlCg5tbHNfZ2VuZXJhdGlvbhgBIAEoBFINbW'
        'xzR2VuZXJhdGlvbhIbCgltbHNfZXBvY2gYAiABKARSCG1sc0Vwb2No');

@$core.Deprecated('Use conversationCommitDescriptor instead')
const ConversationCommit$json = {
  '1': 'ConversationCommit',
  '2': [
    {'1': 'mls_generation', '3': 1, '4': 1, '5': 4, '10': 'mlsGeneration'},
    {'1': 'mls_epoch', '3': 2, '4': 1, '5': 4, '10': 'mlsEpoch'},
    {'1': 'commit', '3': 3, '4': 1, '5': 12, '10': 'commit'},
    {'1': 'from_self', '3': 4, '4': 1, '5': 8, '10': 'fromSelf'},
    {
      '1': 'created_at',
      '3': 5,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '10': 'createdAt'
    },
  ],
};

/// Descriptor for `ConversationCommit`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List conversationCommitDescriptor = $convert.base64Decode(
    'ChJDb252ZXJzYXRpb25Db21taXQSJQoObWxzX2dlbmVyYXRpb24YASABKARSDW1sc0dlbmVyYX'
    'Rpb24SGwoJbWxzX2Vwb2NoGAIgASgEUghtbHNFcG9jaBIWCgZjb21taXQYAyABKAxSBmNvbW1p'
    'dBIbCglmcm9tX3NlbGYYBCABKAhSCGZyb21TZWxmEjkKCmNyZWF0ZWRfYXQYBSABKAsyGi5nb2'
    '9nbGUucHJvdG9idWYuVGltZXN0YW1wUgljcmVhdGVkQXQ=');

@$core.Deprecated('Use listConversationCommitsRequestDescriptor instead')
const ListConversationCommitsRequest$json = {
  '1': 'ListConversationCommitsRequest',
  '2': [
    {'1': 'conversation_id', '3': 1, '4': 1, '5': 9, '10': 'conversationId'},
    {'1': 'after_generation', '3': 2, '4': 1, '5': 4, '10': 'afterGeneration'},
    {'1': 'after_epoch', '3': 3, '4': 1, '5': 4, '10': 'afterEpoch'},
    {'1': 'page_size', '3': 4, '4': 1, '5': 5, '10': 'pageSize'},
  ],
};

/// Descriptor for `ListConversationCommitsRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listConversationCommitsRequestDescriptor =
    $convert.base64Decode(
        'Ch5MaXN0Q29udmVyc2F0aW9uQ29tbWl0c1JlcXVlc3QSJwoPY29udmVyc2F0aW9uX2lkGAEgAS'
        'gJUg5jb252ZXJzYXRpb25JZBIpChBhZnRlcl9nZW5lcmF0aW9uGAIgASgEUg9hZnRlckdlbmVy'
        'YXRpb24SHwoLYWZ0ZXJfZXBvY2gYAyABKARSCmFmdGVyRXBvY2gSGwoJcGFnZV9zaXplGAQgAS'
        'gFUghwYWdlU2l6ZQ==');

@$core.Deprecated('Use listConversationCommitsResponseDescriptor instead')
const ListConversationCommitsResponse$json = {
  '1': 'ListConversationCommitsResponse',
  '2': [
    {
      '1': 'commits',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.messaging.v1.ConversationCommit',
      '10': 'commits'
    },
    {'1': 'more', '3': 2, '4': 1, '5': 8, '10': 'more'},
    {'1': 'mls_generation', '3': 3, '4': 1, '5': 4, '10': 'mlsGeneration'},
    {'1': 'mls_epoch', '3': 4, '4': 1, '5': 4, '10': 'mlsEpoch'},
  ],
};

/// Descriptor for `ListConversationCommitsResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listConversationCommitsResponseDescriptor =
    $convert.base64Decode(
        'Ch9MaXN0Q29udmVyc2F0aW9uQ29tbWl0c1Jlc3BvbnNlEkIKB2NvbW1pdHMYASADKAsyKC5kem'
        'Vyb3RoLm1lc3NhZ2luZy52MS5Db252ZXJzYXRpb25Db21taXRSB2NvbW1pdHMSEgoEbW9yZRgC'
        'IAEoCFIEbW9yZRIlCg5tbHNfZ2VuZXJhdGlvbhgDIAEoBFINbWxzR2VuZXJhdGlvbhIbCgltbH'
        'NfZXBvY2gYBCABKARSCG1sc0Vwb2No');

@$core.Deprecated('Use listEpochMessagesRequestDescriptor instead')
const ListEpochMessagesRequest$json = {
  '1': 'ListEpochMessagesRequest',
  '2': [
    {'1': 'conversation_id', '3': 1, '4': 1, '5': 9, '10': 'conversationId'},
    {'1': 'mls_generation', '3': 2, '4': 1, '5': 4, '10': 'mlsGeneration'},
    {'1': 'mls_epoch', '3': 3, '4': 1, '5': 4, '10': 'mlsEpoch'},
    {'1': 'page_size', '3': 4, '4': 1, '5': 5, '10': 'pageSize'},
    {'1': 'page_token', '3': 5, '4': 1, '5': 9, '10': 'pageToken'},
    {
      '1': 'order',
      '3': 6,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.messaging.v1.EpochMessageOrder',
      '10': 'order'
    },
  ],
};

/// Descriptor for `ListEpochMessagesRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listEpochMessagesRequestDescriptor = $convert.base64Decode(
    'ChhMaXN0RXBvY2hNZXNzYWdlc1JlcXVlc3QSJwoPY29udmVyc2F0aW9uX2lkGAEgASgJUg5jb2'
    '52ZXJzYXRpb25JZBIlCg5tbHNfZ2VuZXJhdGlvbhgCIAEoBFINbWxzR2VuZXJhdGlvbhIbCglt'
    'bHNfZXBvY2gYAyABKARSCG1sc0Vwb2NoEhsKCXBhZ2Vfc2l6ZRgEIAEoBVIIcGFnZVNpemUSHQ'
    'oKcGFnZV90b2tlbhgFIAEoCVIJcGFnZVRva2VuEj0KBW9yZGVyGAYgASgOMicuZHplcm90aC5t'
    'ZXNzYWdpbmcudjEuRXBvY2hNZXNzYWdlT3JkZXJSBW9yZGVy');

@$core.Deprecated('Use listEpochMessagesResponseDescriptor instead')
const ListEpochMessagesResponse$json = {
  '1': 'ListEpochMessagesResponse',
  '2': [
    {
      '1': 'messages',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.messaging.v1.Message',
      '10': 'messages'
    },
    {'1': 'next_page_token', '3': 2, '4': 1, '5': 9, '10': 'nextPageToken'},
    {
      '1': 'cleared_at',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '10': 'clearedAt'
    },
    {
      '1': 'order',
      '3': 4,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.messaging.v1.EpochMessageOrder',
      '10': 'order'
    },
    {'1': 'resume_page_token', '3': 5, '4': 1, '5': 9, '10': 'resumePageToken'},
    {'1': 'resume_settled', '3': 6, '4': 1, '5': 8, '10': 'resumeSettled'},
  ],
};

/// Descriptor for `ListEpochMessagesResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listEpochMessagesResponseDescriptor = $convert.base64Decode(
    'ChlMaXN0RXBvY2hNZXNzYWdlc1Jlc3BvbnNlEjkKCG1lc3NhZ2VzGAEgAygLMh0uZHplcm90aC'
    '5tZXNzYWdpbmcudjEuTWVzc2FnZVIIbWVzc2FnZXMSJgoPbmV4dF9wYWdlX3Rva2VuGAIgASgJ'
    'Ug1uZXh0UGFnZVRva2VuEjkKCmNsZWFyZWRfYXQYAyABKAsyGi5nb29nbGUucHJvdG9idWYuVG'
    'ltZXN0YW1wUgljbGVhcmVkQXQSPQoFb3JkZXIYBCABKA4yJy5kemVyb3RoLm1lc3NhZ2luZy52'
    'MS5FcG9jaE1lc3NhZ2VPcmRlclIFb3JkZXISKgoRcmVzdW1lX3BhZ2VfdG9rZW4YBSABKAlSD3'
    'Jlc3VtZVBhZ2VUb2tlbhIlCg5yZXN1bWVfc2V0dGxlZBgGIAEoCFINcmVzdW1lU2V0dGxlZA==');

@$core.Deprecated('Use listMessageTombstonesRequestDescriptor instead')
const ListMessageTombstonesRequest$json = {
  '1': 'ListMessageTombstonesRequest',
  '2': [
    {'1': 'conversation_id', '3': 1, '4': 1, '5': 9, '10': 'conversationId'},
    {'1': 'page_size', '3': 2, '4': 1, '5': 5, '10': 'pageSize'},
    {'1': 'page_token', '3': 3, '4': 1, '5': 9, '10': 'pageToken'},
  ],
};

/// Descriptor for `ListMessageTombstonesRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listMessageTombstonesRequestDescriptor =
    $convert.base64Decode(
        'ChxMaXN0TWVzc2FnZVRvbWJzdG9uZXNSZXF1ZXN0EicKD2NvbnZlcnNhdGlvbl9pZBgBIAEoCV'
        'IOY29udmVyc2F0aW9uSWQSGwoJcGFnZV9zaXplGAIgASgFUghwYWdlU2l6ZRIdCgpwYWdlX3Rv'
        'a2VuGAMgASgJUglwYWdlVG9rZW4=');

@$core.Deprecated('Use messageTombstoneDescriptor instead')
const MessageTombstone$json = {
  '1': 'MessageTombstone',
  '2': [
    {'1': 'id', '3': 1, '4': 1, '5': 9, '10': 'id'},
    {
      '1': 'state',
      '3': 2,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.messaging.v1.MessageState',
      '10': 'state'
    },
  ],
};

/// Descriptor for `MessageTombstone`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List messageTombstoneDescriptor = $convert.base64Decode(
    'ChBNZXNzYWdlVG9tYnN0b25lEg4KAmlkGAEgASgJUgJpZBI4CgVzdGF0ZRgCIAEoDjIiLmR6ZX'
    'JvdGgubWVzc2FnaW5nLnYxLk1lc3NhZ2VTdGF0ZVIFc3RhdGU=');

@$core.Deprecated('Use listMessageTombstonesResponseDescriptor instead')
const ListMessageTombstonesResponse$json = {
  '1': 'ListMessageTombstonesResponse',
  '2': [
    {
      '1': 'tombstones',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.messaging.v1.MessageTombstone',
      '10': 'tombstones'
    },
    {'1': 'next_page_token', '3': 2, '4': 1, '5': 9, '10': 'nextPageToken'},
  ],
};

/// Descriptor for `ListMessageTombstonesResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listMessageTombstonesResponseDescriptor =
    $convert.base64Decode(
        'Ch1MaXN0TWVzc2FnZVRvbWJzdG9uZXNSZXNwb25zZRJGCgp0b21ic3RvbmVzGAEgAygLMiYuZH'
        'plcm90aC5tZXNzYWdpbmcudjEuTWVzc2FnZVRvbWJzdG9uZVIKdG9tYnN0b25lcxImCg9uZXh0'
        'X3BhZ2VfdG9rZW4YAiABKAlSDW5leHRQYWdlVG9rZW4=');

@$core.Deprecated('Use welcomeDescriptor instead')
const Welcome$json = {
  '1': 'Welcome',
  '2': [
    {'1': 'id', '3': 1, '4': 1, '5': 9, '10': 'id'},
    {'1': 'conversation_id', '3': 2, '4': 1, '5': 9, '10': 'conversationId'},
    {'1': 'mls_generation', '3': 3, '4': 1, '5': 4, '10': 'mlsGeneration'},
    {'1': 'mls_epoch', '3': 4, '4': 1, '5': 4, '10': 'mlsEpoch'},
    {'1': 'welcome', '3': 5, '4': 1, '5': 12, '10': 'welcome'},
    {
      '1': 'created_at',
      '3': 6,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '10': 'createdAt'
    },
  ],
};

/// Descriptor for `Welcome`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List welcomeDescriptor = $convert.base64Decode(
    'CgdXZWxjb21lEg4KAmlkGAEgASgJUgJpZBInCg9jb252ZXJzYXRpb25faWQYAiABKAlSDmNvbn'
    'ZlcnNhdGlvbklkEiUKDm1sc19nZW5lcmF0aW9uGAMgASgEUg1tbHNHZW5lcmF0aW9uEhsKCW1s'
    'c19lcG9jaBgEIAEoBFIIbWxzRXBvY2gSGAoHd2VsY29tZRgFIAEoDFIHd2VsY29tZRI5Cgpjcm'
    'VhdGVkX2F0GAYgASgLMhouZ29vZ2xlLnByb3RvYnVmLlRpbWVzdGFtcFIJY3JlYXRlZEF0');

@$core.Deprecated('Use listWelcomesRequestDescriptor instead')
const ListWelcomesRequest$json = {
  '1': 'ListWelcomesRequest',
  '2': [
    {'1': 'device_id', '3': 1, '4': 1, '5': 9, '10': 'deviceId'},
    {'1': 'page_size', '3': 2, '4': 1, '5': 5, '10': 'pageSize'},
  ],
};

/// Descriptor for `ListWelcomesRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listWelcomesRequestDescriptor = $convert.base64Decode(
    'ChNMaXN0V2VsY29tZXNSZXF1ZXN0EhsKCWRldmljZV9pZBgBIAEoCVIIZGV2aWNlSWQSGwoJcG'
    'FnZV9zaXplGAIgASgFUghwYWdlU2l6ZQ==');

@$core.Deprecated('Use listWelcomesResponseDescriptor instead')
const ListWelcomesResponse$json = {
  '1': 'ListWelcomesResponse',
  '2': [
    {
      '1': 'welcomes',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.messaging.v1.Welcome',
      '10': 'welcomes'
    },
    {'1': 'more', '3': 2, '4': 1, '5': 8, '10': 'more'},
  ],
};

/// Descriptor for `ListWelcomesResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listWelcomesResponseDescriptor = $convert.base64Decode(
    'ChRMaXN0V2VsY29tZXNSZXNwb25zZRI5Cgh3ZWxjb21lcxgBIAMoCzIdLmR6ZXJvdGgubWVzc2'
    'FnaW5nLnYxLldlbGNvbWVSCHdlbGNvbWVzEhIKBG1vcmUYAiABKAhSBG1vcmU=');

@$core.Deprecated('Use ackWelcomesRequestDescriptor instead')
const AckWelcomesRequest$json = {
  '1': 'AckWelcomesRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'device_id', '3': 2, '4': 1, '5': 9, '10': 'deviceId'},
    {'1': 'ids', '3': 3, '4': 3, '5': 9, '10': 'ids'},
  ],
};

/// Descriptor for `AckWelcomesRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List ackWelcomesRequestDescriptor = $convert.base64Decode(
    'ChJBY2tXZWxjb21lc1JlcXVlc3QSJwoPaWRlbXBvdGVuY3lfa2V5GAEgASgJUg5pZGVtcG90ZW'
    '5jeUtleRIbCglkZXZpY2VfaWQYAiABKAlSCGRldmljZUlkEhAKA2lkcxgDIAMoCVIDaWRz');

@$core.Deprecated('Use ackWelcomesResponseDescriptor instead')
const AckWelcomesResponse$json = {
  '1': 'AckWelcomesResponse',
};

/// Descriptor for `AckWelcomesResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List ackWelcomesResponseDescriptor =
    $convert.base64Decode('ChNBY2tXZWxjb21lc1Jlc3BvbnNl');

const $core.Map<$core.String, $core.dynamic> MessagingServiceBase$json = {
  '1': 'MessagingService',
  '2': [
    {
      '1': 'SendMessage',
      '2': '.dzeroth.messaging.v1.SendMessageRequest',
      '3': '.dzeroth.messaging.v1.SendMessageResponse'
    },
    {
      '1': 'CheckPostShare',
      '2': '.dzeroth.messaging.v1.CheckPostShareRequest',
      '3': '.dzeroth.messaging.v1.CheckPostShareResponse',
      '4': {'34': 1},
    },
    {
      '1': 'ListConversations',
      '2': '.dzeroth.messaging.v1.ListConversationsRequest',
      '3': '.dzeroth.messaging.v1.ListConversationsResponse',
      '4': {'34': 1},
    },
    {
      '1': 'ListMessages',
      '2': '.dzeroth.messaging.v1.ListMessagesRequest',
      '3': '.dzeroth.messaging.v1.ListMessagesResponse',
      '4': {'34': 1},
    },
    {
      '1': 'MarkConversationRead',
      '2': '.dzeroth.messaging.v1.MarkConversationReadRequest',
      '3': '.dzeroth.messaging.v1.MarkConversationReadResponse'
    },
    {
      '1': 'AcceptMessageRequest',
      '2': '.dzeroth.messaging.v1.AcceptMessageRequestRequest',
      '3': '.dzeroth.messaging.v1.AcceptMessageRequestResponse'
    },
    {
      '1': 'DeleteConversation',
      '2': '.dzeroth.messaging.v1.DeleteConversationRequest',
      '3': '.dzeroth.messaging.v1.DeleteConversationResponse'
    },
    {
      '1': 'ListMessageSuggestions',
      '2': '.dzeroth.messaging.v1.ListMessageSuggestionsRequest',
      '3': '.dzeroth.messaging.v1.ListMessageSuggestionsResponse',
      '4': {'34': 1},
    },
    {
      '1': 'CommitConversation',
      '2': '.dzeroth.messaging.v1.CommitConversationRequest',
      '3': '.dzeroth.messaging.v1.CommitConversationResponse'
    },
    {
      '1': 'ListConversationCommits',
      '2': '.dzeroth.messaging.v1.ListConversationCommitsRequest',
      '3': '.dzeroth.messaging.v1.ListConversationCommitsResponse',
      '4': {'34': 1},
    },
    {
      '1': 'ListEpochMessages',
      '2': '.dzeroth.messaging.v1.ListEpochMessagesRequest',
      '3': '.dzeroth.messaging.v1.ListEpochMessagesResponse',
      '4': {'34': 1},
    },
    {
      '1': 'ListWelcomes',
      '2': '.dzeroth.messaging.v1.ListWelcomesRequest',
      '3': '.dzeroth.messaging.v1.ListWelcomesResponse',
      '4': {'34': 1},
    },
    {
      '1': 'AckWelcomes',
      '2': '.dzeroth.messaging.v1.AckWelcomesRequest',
      '3': '.dzeroth.messaging.v1.AckWelcomesResponse'
    },
    {
      '1': 'ListMessageTombstones',
      '2': '.dzeroth.messaging.v1.ListMessageTombstonesRequest',
      '3': '.dzeroth.messaging.v1.ListMessageTombstonesResponse',
      '4': {'34': 1},
    },
  ],
};

@$core.Deprecated('Use messagingServiceDescriptor instead')
const $core.Map<$core.String, $core.Map<$core.String, $core.dynamic>>
    MessagingServiceBase$messageJson = {
  '.dzeroth.messaging.v1.SendMessageRequest': SendMessageRequest$json,
  '.dzeroth.messaging.v1.MlsInit': MlsInit$json,
  '.dzeroth.messaging.v1.SendMessageResponse': SendMessageResponse$json,
  '.dzeroth.messaging.v1.Message': Message$json,
  '.google.protobuf.Timestamp': $1.Timestamp$json,
  '.dzeroth.posts.v1.EmbeddedPost': $2.EmbeddedPost$json,
  '.dzeroth.common.v1.AuthorSnapshot': $0.AuthorSnapshot$json,
  '.dzeroth.common.v1.MediaRef': $0.MediaRef$json,
  '.dzeroth.posts.v1.Poll': $2.Poll$json,
  '.dzeroth.posts.v1.PollChoice': $2.PollChoice$json,
  '.dzeroth.posts.v1.ArticlePreview': $2.ArticlePreview$json,
  '.dzeroth.messaging.v1.Conversation': Conversation$json,
  '.dzeroth.messaging.v1.MessagePreview': MessagePreview$json,
  '.dzeroth.messaging.v1.CheckPostShareRequest': CheckPostShareRequest$json,
  '.dzeroth.messaging.v1.CheckPostShareResponse': CheckPostShareResponse$json,
  '.dzeroth.messaging.v1.ListConversationsRequest':
      ListConversationsRequest$json,
  '.dzeroth.messaging.v1.ListConversationsResponse':
      ListConversationsResponse$json,
  '.dzeroth.messaging.v1.ListMessagesRequest': ListMessagesRequest$json,
  '.dzeroth.messaging.v1.ListMessagesResponse': ListMessagesResponse$json,
  '.dzeroth.messaging.v1.MarkConversationReadRequest':
      MarkConversationReadRequest$json,
  '.dzeroth.messaging.v1.MarkConversationReadResponse':
      MarkConversationReadResponse$json,
  '.dzeroth.messaging.v1.AcceptMessageRequestRequest':
      AcceptMessageRequestRequest$json,
  '.dzeroth.messaging.v1.AcceptMessageRequestResponse':
      AcceptMessageRequestResponse$json,
  '.dzeroth.messaging.v1.DeleteConversationRequest':
      DeleteConversationRequest$json,
  '.dzeroth.messaging.v1.DeleteConversationResponse':
      DeleteConversationResponse$json,
  '.dzeroth.messaging.v1.ListMessageSuggestionsRequest':
      ListMessageSuggestionsRequest$json,
  '.dzeroth.messaging.v1.ListMessageSuggestionsResponse':
      ListMessageSuggestionsResponse$json,
  '.dzeroth.messaging.v1.MessageSuggestion': MessageSuggestion$json,
  '.dzeroth.messaging.v1.CommitConversationRequest':
      CommitConversationRequest$json,
  '.dzeroth.messaging.v1.CommitConversationResponse':
      CommitConversationResponse$json,
  '.dzeroth.messaging.v1.ListConversationCommitsRequest':
      ListConversationCommitsRequest$json,
  '.dzeroth.messaging.v1.ListConversationCommitsResponse':
      ListConversationCommitsResponse$json,
  '.dzeroth.messaging.v1.ConversationCommit': ConversationCommit$json,
  '.dzeroth.messaging.v1.ListEpochMessagesRequest':
      ListEpochMessagesRequest$json,
  '.dzeroth.messaging.v1.ListEpochMessagesResponse':
      ListEpochMessagesResponse$json,
  '.dzeroth.messaging.v1.ListWelcomesRequest': ListWelcomesRequest$json,
  '.dzeroth.messaging.v1.ListWelcomesResponse': ListWelcomesResponse$json,
  '.dzeroth.messaging.v1.Welcome': Welcome$json,
  '.dzeroth.messaging.v1.AckWelcomesRequest': AckWelcomesRequest$json,
  '.dzeroth.messaging.v1.AckWelcomesResponse': AckWelcomesResponse$json,
  '.dzeroth.messaging.v1.ListMessageTombstonesRequest':
      ListMessageTombstonesRequest$json,
  '.dzeroth.messaging.v1.ListMessageTombstonesResponse':
      ListMessageTombstonesResponse$json,
  '.dzeroth.messaging.v1.MessageTombstone': MessageTombstone$json,
};

/// Descriptor for `MessagingService`. Decode as a `google.protobuf.ServiceDescriptorProto`.
final $typed_data.Uint8List messagingServiceDescriptor = $convert.base64Decode(
    'ChBNZXNzYWdpbmdTZXJ2aWNlEmIKC1NlbmRNZXNzYWdlEiguZHplcm90aC5tZXNzYWdpbmcudj'
    'EuU2VuZE1lc3NhZ2VSZXF1ZXN0GikuZHplcm90aC5tZXNzYWdpbmcudjEuU2VuZE1lc3NhZ2VS'
    'ZXNwb25zZRJwCg5DaGVja1Bvc3RTaGFyZRIrLmR6ZXJvdGgubWVzc2FnaW5nLnYxLkNoZWNrUG'
    '9zdFNoYXJlUmVxdWVzdBosLmR6ZXJvdGgubWVzc2FnaW5nLnYxLkNoZWNrUG9zdFNoYXJlUmVz'
    'cG9uc2UiA5ACARJ5ChFMaXN0Q29udmVyc2F0aW9ucxIuLmR6ZXJvdGgubWVzc2FnaW5nLnYxLk'
    'xpc3RDb252ZXJzYXRpb25zUmVxdWVzdBovLmR6ZXJvdGgubWVzc2FnaW5nLnYxLkxpc3RDb252'
    'ZXJzYXRpb25zUmVzcG9uc2UiA5ACARJqCgxMaXN0TWVzc2FnZXMSKS5kemVyb3RoLm1lc3NhZ2'
    'luZy52MS5MaXN0TWVzc2FnZXNSZXF1ZXN0GiouZHplcm90aC5tZXNzYWdpbmcudjEuTGlzdE1l'
    'c3NhZ2VzUmVzcG9uc2UiA5ACARJ9ChRNYXJrQ29udmVyc2F0aW9uUmVhZBIxLmR6ZXJvdGgubW'
    'Vzc2FnaW5nLnYxLk1hcmtDb252ZXJzYXRpb25SZWFkUmVxdWVzdBoyLmR6ZXJvdGgubWVzc2Fn'
    'aW5nLnYxLk1hcmtDb252ZXJzYXRpb25SZWFkUmVzcG9uc2USfQoUQWNjZXB0TWVzc2FnZVJlcX'
    'Vlc3QSMS5kemVyb3RoLm1lc3NhZ2luZy52MS5BY2NlcHRNZXNzYWdlUmVxdWVzdFJlcXVlc3Qa'
    'Mi5kemVyb3RoLm1lc3NhZ2luZy52MS5BY2NlcHRNZXNzYWdlUmVxdWVzdFJlc3BvbnNlEncKEk'
    'RlbGV0ZUNvbnZlcnNhdGlvbhIvLmR6ZXJvdGgubWVzc2FnaW5nLnYxLkRlbGV0ZUNvbnZlcnNh'
    'dGlvblJlcXVlc3QaMC5kemVyb3RoLm1lc3NhZ2luZy52MS5EZWxldGVDb252ZXJzYXRpb25SZX'
    'Nwb25zZRKIAQoWTGlzdE1lc3NhZ2VTdWdnZXN0aW9ucxIzLmR6ZXJvdGgubWVzc2FnaW5nLnYx'
    'Lkxpc3RNZXNzYWdlU3VnZ2VzdGlvbnNSZXF1ZXN0GjQuZHplcm90aC5tZXNzYWdpbmcudjEuTG'
    'lzdE1lc3NhZ2VTdWdnZXN0aW9uc1Jlc3BvbnNlIgOQAgESdwoSQ29tbWl0Q29udmVyc2F0aW9u'
    'Ei8uZHplcm90aC5tZXNzYWdpbmcudjEuQ29tbWl0Q29udmVyc2F0aW9uUmVxdWVzdBowLmR6ZX'
    'JvdGgubWVzc2FnaW5nLnYxLkNvbW1pdENvbnZlcnNhdGlvblJlc3BvbnNlEosBChdMaXN0Q29u'
    'dmVyc2F0aW9uQ29tbWl0cxI0LmR6ZXJvdGgubWVzc2FnaW5nLnYxLkxpc3RDb252ZXJzYXRpb2'
    '5Db21taXRzUmVxdWVzdBo1LmR6ZXJvdGgubWVzc2FnaW5nLnYxLkxpc3RDb252ZXJzYXRpb25D'
    'b21taXRzUmVzcG9uc2UiA5ACARJ5ChFMaXN0RXBvY2hNZXNzYWdlcxIuLmR6ZXJvdGgubWVzc2'
    'FnaW5nLnYxLkxpc3RFcG9jaE1lc3NhZ2VzUmVxdWVzdBovLmR6ZXJvdGgubWVzc2FnaW5nLnYx'
    'Lkxpc3RFcG9jaE1lc3NhZ2VzUmVzcG9uc2UiA5ACARJqCgxMaXN0V2VsY29tZXMSKS5kemVyb3'
    'RoLm1lc3NhZ2luZy52MS5MaXN0V2VsY29tZXNSZXF1ZXN0GiouZHplcm90aC5tZXNzYWdpbmcu'
    'djEuTGlzdFdlbGNvbWVzUmVzcG9uc2UiA5ACARJiCgtBY2tXZWxjb21lcxIoLmR6ZXJvdGgubW'
    'Vzc2FnaW5nLnYxLkFja1dlbGNvbWVzUmVxdWVzdBopLmR6ZXJvdGgubWVzc2FnaW5nLnYxLkFj'
    'a1dlbGNvbWVzUmVzcG9uc2UShQEKFUxpc3RNZXNzYWdlVG9tYnN0b25lcxIyLmR6ZXJvdGgubW'
    'Vzc2FnaW5nLnYxLkxpc3RNZXNzYWdlVG9tYnN0b25lc1JlcXVlc3QaMy5kemVyb3RoLm1lc3Nh'
    'Z2luZy52MS5MaXN0TWVzc2FnZVRvbWJzdG9uZXNSZXNwb25zZSIDkAIB');
