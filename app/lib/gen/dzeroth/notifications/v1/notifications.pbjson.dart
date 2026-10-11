// This is a generated file - do not edit.
//
// Generated from dzeroth/notifications/v1/notifications.proto.

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

@$core.Deprecated('Use notificationTypeDescriptor instead')
const NotificationType$json = {
  '1': 'NotificationType',
  '2': [
    {'1': 'NOTIFICATION_TYPE_UNSPECIFIED', '2': 0},
    {'1': 'NOTIFICATION_TYPE_FOLLOW', '2': 1},
    {'1': 'NOTIFICATION_TYPE_MENTION', '2': 2},
    {'1': 'NOTIFICATION_TYPE_REPLY', '2': 3},
    {'1': 'NOTIFICATION_TYPE_LIKE', '2': 4},
    {'1': 'NOTIFICATION_TYPE_REPOST', '2': 5},
    {'1': 'NOTIFICATION_TYPE_QUOTE', '2': 6},
  ],
};

/// Descriptor for `NotificationType`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List notificationTypeDescriptor = $convert.base64Decode(
    'ChBOb3RpZmljYXRpb25UeXBlEiEKHU5PVElGSUNBVElPTl9UWVBFX1VOU1BFQ0lGSUVEEAASHA'
    'oYTk9USUZJQ0FUSU9OX1RZUEVfRk9MTE9XEAESHQoZTk9USUZJQ0FUSU9OX1RZUEVfTUVOVElP'
    'ThACEhsKF05PVElGSUNBVElPTl9UWVBFX1JFUExZEAMSGgoWTk9USUZJQ0FUSU9OX1RZUEVfTE'
    'lLRRAEEhwKGE5PVElGSUNBVElPTl9UWVBFX1JFUE9TVBAFEhsKF05PVElGSUNBVElPTl9UWVBF'
    'X1FVT1RFEAY=');

@$core.Deprecated('Use devicePlatformDescriptor instead')
const DevicePlatform$json = {
  '1': 'DevicePlatform',
  '2': [
    {'1': 'DEVICE_PLATFORM_UNSPECIFIED', '2': 0},
    {'1': 'DEVICE_PLATFORM_IOS', '2': 1},
    {'1': 'DEVICE_PLATFORM_ANDROID', '2': 2},
  ],
};

/// Descriptor for `DevicePlatform`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List devicePlatformDescriptor = $convert.base64Decode(
    'Cg5EZXZpY2VQbGF0Zm9ybRIfChtERVZJQ0VfUExBVEZPUk1fVU5TUEVDSUZJRUQQABIXChNERV'
    'ZJQ0VfUExBVEZPUk1fSU9TEAESGwoXREVWSUNFX1BMQVRGT1JNX0FORFJPSUQQAg==');

@$core.Deprecated('Use notificationDescriptor instead')
const Notification$json = {
  '1': 'Notification',
  '2': [
    {'1': 'id', '3': 1, '4': 1, '5': 9, '10': 'id'},
    {
      '1': 'type',
      '3': 2,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.notifications.v1.NotificationType',
      '10': 'type'
    },
    {
      '1': 'actor',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.common.v1.AuthorSnapshot',
      '10': 'actor'
    },
    {'1': 'actor_count', '3': 4, '4': 1, '5': 5, '10': 'actorCount'},
    {'1': 'post_id', '3': 5, '4': 1, '5': 9, '10': 'postId'},
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

/// Descriptor for `Notification`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List notificationDescriptor = $convert.base64Decode(
    'CgxOb3RpZmljYXRpb24SDgoCaWQYASABKAlSAmlkEj4KBHR5cGUYAiABKA4yKi5kemVyb3RoLm'
    '5vdGlmaWNhdGlvbnMudjEuTm90aWZpY2F0aW9uVHlwZVIEdHlwZRI3CgVhY3RvchgDIAEoCzIh'
    'LmR6ZXJvdGguY29tbW9uLnYxLkF1dGhvclNuYXBzaG90UgVhY3RvchIfCgthY3Rvcl9jb3VudB'
    'gEIAEoBVIKYWN0b3JDb3VudBIXCgdwb3N0X2lkGAUgASgJUgZwb3N0SWQSOQoKY3JlYXRlZF9h'
    'dBgGIAEoCzIaLmdvb2dsZS5wcm90b2J1Zi5UaW1lc3RhbXBSCWNyZWF0ZWRBdA==');

@$core.Deprecated('Use listNotificationsRequestDescriptor instead')
const ListNotificationsRequest$json = {
  '1': 'ListNotificationsRequest',
  '2': [
    {'1': 'page_size', '3': 1, '4': 1, '5': 5, '10': 'pageSize'},
    {'1': 'page_token', '3': 2, '4': 1, '5': 9, '10': 'pageToken'},
    {'1': 'since_token', '3': 3, '4': 1, '5': 9, '10': 'sinceToken'},
  ],
};

/// Descriptor for `ListNotificationsRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listNotificationsRequestDescriptor = $convert.base64Decode(
    'ChhMaXN0Tm90aWZpY2F0aW9uc1JlcXVlc3QSGwoJcGFnZV9zaXplGAEgASgFUghwYWdlU2l6ZR'
    'IdCgpwYWdlX3Rva2VuGAIgASgJUglwYWdlVG9rZW4SHwoLc2luY2VfdG9rZW4YAyABKAlSCnNp'
    'bmNlVG9rZW4=');

@$core.Deprecated('Use listNotificationsResponseDescriptor instead')
const ListNotificationsResponse$json = {
  '1': 'ListNotificationsResponse',
  '2': [
    {
      '1': 'notifications',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.notifications.v1.Notification',
      '10': 'notifications'
    },
    {'1': 'next_page_token', '3': 2, '4': 1, '5': 9, '10': 'nextPageToken'},
    {'1': 'since_token', '3': 3, '4': 1, '5': 9, '10': 'sinceToken'},
    {'1': 'gap_page_token', '3': 4, '4': 1, '5': 9, '10': 'gapPageToken'},
    {
      '1': 'seen_at',
      '3': 5,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '10': 'seenAt'
    },
  ],
};

/// Descriptor for `ListNotificationsResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listNotificationsResponseDescriptor = $convert.base64Decode(
    'ChlMaXN0Tm90aWZpY2F0aW9uc1Jlc3BvbnNlEkwKDW5vdGlmaWNhdGlvbnMYASADKAsyJi5kem'
    'Vyb3RoLm5vdGlmaWNhdGlvbnMudjEuTm90aWZpY2F0aW9uUg1ub3RpZmljYXRpb25zEiYKD25l'
    'eHRfcGFnZV90b2tlbhgCIAEoCVINbmV4dFBhZ2VUb2tlbhIfCgtzaW5jZV90b2tlbhgDIAEoCV'
    'IKc2luY2VUb2tlbhIkCg5nYXBfcGFnZV90b2tlbhgEIAEoCVIMZ2FwUGFnZVRva2VuEjMKB3Nl'
    'ZW5fYXQYBSABKAsyGi5nb29nbGUucHJvdG9idWYuVGltZXN0YW1wUgZzZWVuQXQ=');

@$core.Deprecated('Use markNotificationsSeenRequestDescriptor instead')
const MarkNotificationsSeenRequest$json = {
  '1': 'MarkNotificationsSeenRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
  ],
};

/// Descriptor for `MarkNotificationsSeenRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List markNotificationsSeenRequestDescriptor =
    $convert.base64Decode(
        'ChxNYXJrTm90aWZpY2F0aW9uc1NlZW5SZXF1ZXN0EicKD2lkZW1wb3RlbmN5X2tleRgBIAEoCV'
        'IOaWRlbXBvdGVuY3lLZXk=');

@$core.Deprecated('Use markNotificationsSeenResponseDescriptor instead')
const MarkNotificationsSeenResponse$json = {
  '1': 'MarkNotificationsSeenResponse',
  '2': [
    {
      '1': 'seen_at',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '10': 'seenAt'
    },
  ],
};

/// Descriptor for `MarkNotificationsSeenResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List markNotificationsSeenResponseDescriptor =
    $convert.base64Decode(
        'Ch1NYXJrTm90aWZpY2F0aW9uc1NlZW5SZXNwb25zZRIzCgdzZWVuX2F0GAEgASgLMhouZ29vZ2'
        'xlLnByb3RvYnVmLlRpbWVzdGFtcFIGc2VlbkF0');

@$core.Deprecated('Use registerDeviceRequestDescriptor instead')
const RegisterDeviceRequest$json = {
  '1': 'RegisterDeviceRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'device_id', '3': 2, '4': 1, '5': 9, '10': 'deviceId'},
    {'1': 'fcm_token', '3': 3, '4': 1, '5': 9, '10': 'fcmToken'},
    {
      '1': 'platform',
      '3': 4,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.notifications.v1.DevicePlatform',
      '10': 'platform'
    },
  ],
};

/// Descriptor for `RegisterDeviceRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List registerDeviceRequestDescriptor = $convert.base64Decode(
    'ChVSZWdpc3RlckRldmljZVJlcXVlc3QSJwoPaWRlbXBvdGVuY3lfa2V5GAEgASgJUg5pZGVtcG'
    '90ZW5jeUtleRIbCglkZXZpY2VfaWQYAiABKAlSCGRldmljZUlkEhsKCWZjbV90b2tlbhgDIAEo'
    'CVIIZmNtVG9rZW4SRAoIcGxhdGZvcm0YBCABKA4yKC5kemVyb3RoLm5vdGlmaWNhdGlvbnMudj'
    'EuRGV2aWNlUGxhdGZvcm1SCHBsYXRmb3Jt');

@$core.Deprecated('Use registerDeviceResponseDescriptor instead')
const RegisterDeviceResponse$json = {
  '1': 'RegisterDeviceResponse',
};

/// Descriptor for `RegisterDeviceResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List registerDeviceResponseDescriptor =
    $convert.base64Decode('ChZSZWdpc3RlckRldmljZVJlc3BvbnNl');

@$core.Deprecated('Use unregisterDeviceRequestDescriptor instead')
const UnregisterDeviceRequest$json = {
  '1': 'UnregisterDeviceRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'device_id', '3': 2, '4': 1, '5': 9, '10': 'deviceId'},
  ],
};

/// Descriptor for `UnregisterDeviceRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List unregisterDeviceRequestDescriptor =
    $convert.base64Decode(
        'ChdVbnJlZ2lzdGVyRGV2aWNlUmVxdWVzdBInCg9pZGVtcG90ZW5jeV9rZXkYASABKAlSDmlkZW'
        '1wb3RlbmN5S2V5EhsKCWRldmljZV9pZBgCIAEoCVIIZGV2aWNlSWQ=');

@$core.Deprecated('Use unregisterDeviceResponseDescriptor instead')
const UnregisterDeviceResponse$json = {
  '1': 'UnregisterDeviceResponse',
};

/// Descriptor for `UnregisterDeviceResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List unregisterDeviceResponseDescriptor =
    $convert.base64Decode('ChhVbnJlZ2lzdGVyRGV2aWNlUmVzcG9uc2U=');

const $core.Map<$core.String, $core.dynamic> NotificationServiceBase$json = {
  '1': 'NotificationService',
  '2': [
    {
      '1': 'ListNotifications',
      '2': '.dzeroth.notifications.v1.ListNotificationsRequest',
      '3': '.dzeroth.notifications.v1.ListNotificationsResponse',
      '4': {'34': 1},
    },
    {
      '1': 'MarkNotificationsSeen',
      '2': '.dzeroth.notifications.v1.MarkNotificationsSeenRequest',
      '3': '.dzeroth.notifications.v1.MarkNotificationsSeenResponse'
    },
    {
      '1': 'RegisterDevice',
      '2': '.dzeroth.notifications.v1.RegisterDeviceRequest',
      '3': '.dzeroth.notifications.v1.RegisterDeviceResponse'
    },
    {
      '1': 'UnregisterDevice',
      '2': '.dzeroth.notifications.v1.UnregisterDeviceRequest',
      '3': '.dzeroth.notifications.v1.UnregisterDeviceResponse'
    },
  ],
};

@$core.Deprecated('Use notificationServiceDescriptor instead')
const $core.Map<$core.String, $core.Map<$core.String, $core.dynamic>>
    NotificationServiceBase$messageJson = {
  '.dzeroth.notifications.v1.ListNotificationsRequest':
      ListNotificationsRequest$json,
  '.dzeroth.notifications.v1.ListNotificationsResponse':
      ListNotificationsResponse$json,
  '.dzeroth.notifications.v1.Notification': Notification$json,
  '.dzeroth.common.v1.AuthorSnapshot': $0.AuthorSnapshot$json,
  '.google.protobuf.Timestamp': $1.Timestamp$json,
  '.dzeroth.notifications.v1.MarkNotificationsSeenRequest':
      MarkNotificationsSeenRequest$json,
  '.dzeroth.notifications.v1.MarkNotificationsSeenResponse':
      MarkNotificationsSeenResponse$json,
  '.dzeroth.notifications.v1.RegisterDeviceRequest': RegisterDeviceRequest$json,
  '.dzeroth.notifications.v1.RegisterDeviceResponse':
      RegisterDeviceResponse$json,
  '.dzeroth.notifications.v1.UnregisterDeviceRequest':
      UnregisterDeviceRequest$json,
  '.dzeroth.notifications.v1.UnregisterDeviceResponse':
      UnregisterDeviceResponse$json,
};

/// Descriptor for `NotificationService`. Decode as a `google.protobuf.ServiceDescriptorProto`.
final $typed_data.Uint8List notificationServiceDescriptor = $convert.base64Decode(
    'ChNOb3RpZmljYXRpb25TZXJ2aWNlEoEBChFMaXN0Tm90aWZpY2F0aW9ucxIyLmR6ZXJvdGgubm'
    '90aWZpY2F0aW9ucy52MS5MaXN0Tm90aWZpY2F0aW9uc1JlcXVlc3QaMy5kemVyb3RoLm5vdGlm'
    'aWNhdGlvbnMudjEuTGlzdE5vdGlmaWNhdGlvbnNSZXNwb25zZSIDkAIBEogBChVNYXJrTm90aW'
    'ZpY2F0aW9uc1NlZW4SNi5kemVyb3RoLm5vdGlmaWNhdGlvbnMudjEuTWFya05vdGlmaWNhdGlv'
    'bnNTZWVuUmVxdWVzdBo3LmR6ZXJvdGgubm90aWZpY2F0aW9ucy52MS5NYXJrTm90aWZpY2F0aW'
    '9uc1NlZW5SZXNwb25zZRJzCg5SZWdpc3RlckRldmljZRIvLmR6ZXJvdGgubm90aWZpY2F0aW9u'
    'cy52MS5SZWdpc3RlckRldmljZVJlcXVlc3QaMC5kemVyb3RoLm5vdGlmaWNhdGlvbnMudjEuUm'
    'VnaXN0ZXJEZXZpY2VSZXNwb25zZRJ5ChBVbnJlZ2lzdGVyRGV2aWNlEjEuZHplcm90aC5ub3Rp'
    'ZmljYXRpb25zLnYxLlVucmVnaXN0ZXJEZXZpY2VSZXF1ZXN0GjIuZHplcm90aC5ub3RpZmljYX'
    'Rpb25zLnYxLlVucmVnaXN0ZXJEZXZpY2VSZXNwb25zZQ==');
