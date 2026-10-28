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
    'Gi5nb29nbGUucHJvdG9idWYuVGltZXN0YW1wUgl1cGRhdGVkQXQ=');

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
  ],
};

/// Descriptor for `MessagePreview`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List messagePreviewDescriptor = $convert.base64Decode(
    'Cg5NZXNzYWdlUHJldmlldxIYCgdzbmlwcGV0GAEgASgJUgdzbmlwcGV0EhsKCWZyb21fc2VsZh'
    'gCIAEoCFIIZnJvbVNlbGYSOAoFc3RhdGUYAyABKA4yIi5kemVyb3RoLm1lc3NhZ2luZy52MS5N'
    'ZXNzYWdlU3RhdGVSBXN0YXRlEjkKCmNyZWF0ZWRfYXQYBCABKAsyGi5nb29nbGUucHJvdG9idW'
    'YuVGltZXN0YW1wUgljcmVhdGVkQXQ=');

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
    'CWNyZWF0ZWRBdEoECAcQCA==');

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
      '9': 0,
      '10': 'recipientUserId'
    },
    {'1': 'text', '3': 4, '4': 1, '5': 9, '10': 'text'},
  ],
  '8': [
    {'1': 'target'},
  ],
};

/// Descriptor for `SendMessageRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List sendMessageRequestDescriptor = $convert.base64Decode(
    'ChJTZW5kTWVzc2FnZVJlcXVlc3QSJwoPaWRlbXBvdGVuY3lfa2V5GAEgASgJUg5pZGVtcG90ZW'
    '5jeUtleRIpCg9jb252ZXJzYXRpb25faWQYAiABKAlIAFIOY29udmVyc2F0aW9uSWQSLAoRcmVj'
    'aXBpZW50X3VzZXJfaWQYAyABKAlIAFIPcmVjaXBpZW50VXNlcklkEhIKBHRleHQYBCABKAlSBH'
    'RleHRCCAoGdGFyZ2V0');

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

const $core.Map<$core.String, $core.dynamic> MessagingServiceBase$json = {
  '1': 'MessagingService',
  '2': [
    {
      '1': 'SendMessage',
      '2': '.dzeroth.messaging.v1.SendMessageRequest',
      '3': '.dzeroth.messaging.v1.SendMessageResponse'
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
  ],
};

@$core.Deprecated('Use messagingServiceDescriptor instead')
const $core.Map<$core.String, $core.Map<$core.String, $core.dynamic>>
    MessagingServiceBase$messageJson = {
  '.dzeroth.messaging.v1.SendMessageRequest': SendMessageRequest$json,
  '.dzeroth.messaging.v1.SendMessageResponse': SendMessageResponse$json,
  '.dzeroth.messaging.v1.Message': Message$json,
  '.google.protobuf.Timestamp': $1.Timestamp$json,
  '.dzeroth.messaging.v1.Conversation': Conversation$json,
  '.dzeroth.common.v1.AuthorSnapshot': $0.AuthorSnapshot$json,
  '.dzeroth.messaging.v1.MessagePreview': MessagePreview$json,
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
};

/// Descriptor for `MessagingService`. Decode as a `google.protobuf.ServiceDescriptorProto`.
final $typed_data.Uint8List messagingServiceDescriptor = $convert.base64Decode(
    'ChBNZXNzYWdpbmdTZXJ2aWNlEmIKC1NlbmRNZXNzYWdlEiguZHplcm90aC5tZXNzYWdpbmcudj'
    'EuU2VuZE1lc3NhZ2VSZXF1ZXN0GikuZHplcm90aC5tZXNzYWdpbmcudjEuU2VuZE1lc3NhZ2VS'
    'ZXNwb25zZRJ5ChFMaXN0Q29udmVyc2F0aW9ucxIuLmR6ZXJvdGgubWVzc2FnaW5nLnYxLkxpc3'
    'RDb252ZXJzYXRpb25zUmVxdWVzdBovLmR6ZXJvdGgubWVzc2FnaW5nLnYxLkxpc3RDb252ZXJz'
    'YXRpb25zUmVzcG9uc2UiA5ACARJqCgxMaXN0TWVzc2FnZXMSKS5kemVyb3RoLm1lc3NhZ2luZy'
    '52MS5MaXN0TWVzc2FnZXNSZXF1ZXN0GiouZHplcm90aC5tZXNzYWdpbmcudjEuTGlzdE1lc3Nh'
    'Z2VzUmVzcG9uc2UiA5ACARJ9ChRNYXJrQ29udmVyc2F0aW9uUmVhZBIxLmR6ZXJvdGgubWVzc2'
    'FnaW5nLnYxLk1hcmtDb252ZXJzYXRpb25SZWFkUmVxdWVzdBoyLmR6ZXJvdGgubWVzc2FnaW5n'
    'LnYxLk1hcmtDb252ZXJzYXRpb25SZWFkUmVzcG9uc2USfQoUQWNjZXB0TWVzc2FnZVJlcXVlc3'
    'QSMS5kemVyb3RoLm1lc3NhZ2luZy52MS5BY2NlcHRNZXNzYWdlUmVxdWVzdFJlcXVlc3QaMi5k'
    'emVyb3RoLm1lc3NhZ2luZy52MS5BY2NlcHRNZXNzYWdlUmVxdWVzdFJlc3BvbnNlEncKEkRlbG'
    'V0ZUNvbnZlcnNhdGlvbhIvLmR6ZXJvdGgubWVzc2FnaW5nLnYxLkRlbGV0ZUNvbnZlcnNhdGlv'
    'blJlcXVlc3QaMC5kemVyb3RoLm1lc3NhZ2luZy52MS5EZWxldGVDb252ZXJzYXRpb25SZXNwb2'
    '5zZQ==');
