// This is a generated file - do not edit.
//
// Generated from dzeroth/identity/v1/identity.proto.

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

@$core.Deprecated('Use accountStatusDescriptor instead')
const AccountStatus$json = {
  '1': 'AccountStatus',
  '2': [
    {'1': 'ACCOUNT_STATUS_UNSPECIFIED', '2': 0},
    {'1': 'ACCOUNT_STATUS_ACTIVE', '2': 1},
    {'1': 'ACCOUNT_STATUS_SUSPENDED', '2': 2},
    {'1': 'ACCOUNT_STATUS_DELETING', '2': 3},
  ],
};

/// Descriptor for `AccountStatus`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List accountStatusDescriptor = $convert.base64Decode(
    'Cg1BY2NvdW50U3RhdHVzEh4KGkFDQ09VTlRfU1RBVFVTX1VOU1BFQ0lGSUVEEAASGQoVQUNDT1'
    'VOVF9TVEFUVVNfQUNUSVZFEAESHAoYQUNDT1VOVF9TVEFUVVNfU1VTUEVOREVEEAISGwoXQUND'
    'T1VOVF9TVEFUVVNfREVMRVRJTkcQAw==');

@$core.Deprecated('Use exportStatusDescriptor instead')
const ExportStatus$json = {
  '1': 'ExportStatus',
  '2': [
    {'1': 'EXPORT_STATUS_UNSPECIFIED', '2': 0},
    {'1': 'EXPORT_STATUS_PENDING', '2': 1},
    {'1': 'EXPORT_STATUS_READY', '2': 2},
    {'1': 'EXPORT_STATUS_FAILED', '2': 3},
  ],
};

/// Descriptor for `ExportStatus`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List exportStatusDescriptor = $convert.base64Decode(
    'CgxFeHBvcnRTdGF0dXMSHQoZRVhQT1JUX1NUQVRVU19VTlNQRUNJRklFRBAAEhkKFUVYUE9SVF'
    '9TVEFUVVNfUEVORElORxABEhcKE0VYUE9SVF9TVEFUVVNfUkVBRFkQAhIYChRFWFBPUlRfU1RB'
    'VFVTX0ZBSUxFRBAD');

@$core.Deprecated('Use profileDescriptor instead')
const Profile$json = {
  '1': 'Profile',
  '2': [
    {'1': 'user_id', '3': 1, '4': 1, '5': 9, '10': 'userId'},
    {'1': 'handle', '3': 2, '4': 1, '5': 9, '10': 'handle'},
    {'1': 'display_name', '3': 3, '4': 1, '5': 9, '10': 'displayName'},
    {'1': 'bio', '3': 4, '4': 1, '5': 9, '10': 'bio'},
    {'1': 'avatar_url', '3': 5, '4': 1, '5': 9, '10': 'avatarUrl'},
    {'1': 'avatar_thumb_url', '3': 6, '4': 1, '5': 9, '10': 'avatarThumbUrl'},
    {'1': 'is_private', '3': 7, '4': 1, '5': 8, '10': 'isPrivate'},
    {'1': 'verified', '3': 8, '4': 1, '5': 8, '10': 'verified'},
    {'1': 'followers_count', '3': 9, '4': 1, '5': 3, '10': 'followersCount'},
    {'1': 'following_count', '3': 10, '4': 1, '5': 3, '10': 'followingCount'},
    {'1': 'posts_count', '3': 11, '4': 1, '5': 3, '10': 'postsCount'},
    {
      '1': 'created_at',
      '3': 12,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '10': 'createdAt'
    },
  ],
};

/// Descriptor for `Profile`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List profileDescriptor = $convert.base64Decode(
    'CgdQcm9maWxlEhcKB3VzZXJfaWQYASABKAlSBnVzZXJJZBIWCgZoYW5kbGUYAiABKAlSBmhhbm'
    'RsZRIhCgxkaXNwbGF5X25hbWUYAyABKAlSC2Rpc3BsYXlOYW1lEhAKA2JpbxgEIAEoCVIDYmlv'
    'Eh0KCmF2YXRhcl91cmwYBSABKAlSCWF2YXRhclVybBIoChBhdmF0YXJfdGh1bWJfdXJsGAYgAS'
    'gJUg5hdmF0YXJUaHVtYlVybBIdCgppc19wcml2YXRlGAcgASgIUglpc1ByaXZhdGUSGgoIdmVy'
    'aWZpZWQYCCABKAhSCHZlcmlmaWVkEicKD2ZvbGxvd2Vyc19jb3VudBgJIAEoA1IOZm9sbG93ZX'
    'JzQ291bnQSJwoPZm9sbG93aW5nX2NvdW50GAogASgDUg5mb2xsb3dpbmdDb3VudBIfCgtwb3N0'
    'c19jb3VudBgLIAEoA1IKcG9zdHNDb3VudBI5CgpjcmVhdGVkX2F0GAwgASgLMhouZ29vZ2xlLn'
    'Byb3RvYnVmLlRpbWVzdGFtcFIJY3JlYXRlZEF0');

@$core.Deprecated('Use createProfileRequestDescriptor instead')
const CreateProfileRequest$json = {
  '1': 'CreateProfileRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'handle', '3': 2, '4': 1, '5': 9, '10': 'handle'},
    {'1': 'display_name', '3': 3, '4': 1, '5': 9, '10': 'displayName'},
  ],
};

/// Descriptor for `CreateProfileRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List createProfileRequestDescriptor = $convert.base64Decode(
    'ChRDcmVhdGVQcm9maWxlUmVxdWVzdBInCg9pZGVtcG90ZW5jeV9rZXkYASABKAlSDmlkZW1wb3'
    'RlbmN5S2V5EhYKBmhhbmRsZRgCIAEoCVIGaGFuZGxlEiEKDGRpc3BsYXlfbmFtZRgDIAEoCVIL'
    'ZGlzcGxheU5hbWU=');

@$core.Deprecated('Use createProfileResponseDescriptor instead')
const CreateProfileResponse$json = {
  '1': 'CreateProfileResponse',
  '2': [
    {
      '1': 'profile',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.identity.v1.Profile',
      '10': 'profile'
    },
  ],
};

/// Descriptor for `CreateProfileResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List createProfileResponseDescriptor = $convert.base64Decode(
    'ChVDcmVhdGVQcm9maWxlUmVzcG9uc2USNgoHcHJvZmlsZRgBIAEoCzIcLmR6ZXJvdGguaWRlbn'
    'RpdHkudjEuUHJvZmlsZVIHcHJvZmlsZQ==');

@$core.Deprecated('Use checkHandleAvailabilityRequestDescriptor instead')
const CheckHandleAvailabilityRequest$json = {
  '1': 'CheckHandleAvailabilityRequest',
  '2': [
    {'1': 'handle', '3': 1, '4': 1, '5': 9, '10': 'handle'},
  ],
};

/// Descriptor for `CheckHandleAvailabilityRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List checkHandleAvailabilityRequestDescriptor =
    $convert.base64Decode(
        'Ch5DaGVja0hhbmRsZUF2YWlsYWJpbGl0eVJlcXVlc3QSFgoGaGFuZGxlGAEgASgJUgZoYW5kbG'
        'U=');

@$core.Deprecated('Use checkHandleAvailabilityResponseDescriptor instead')
const CheckHandleAvailabilityResponse$json = {
  '1': 'CheckHandleAvailabilityResponse',
  '2': [
    {'1': 'available', '3': 1, '4': 1, '5': 8, '10': 'available'},
    {'1': 'reason', '3': 2, '4': 1, '5': 9, '10': 'reason'},
  ],
};

/// Descriptor for `CheckHandleAvailabilityResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List checkHandleAvailabilityResponseDescriptor =
    $convert.base64Decode(
        'Ch9DaGVja0hhbmRsZUF2YWlsYWJpbGl0eVJlc3BvbnNlEhwKCWF2YWlsYWJsZRgBIAEoCFIJYX'
        'ZhaWxhYmxlEhYKBnJlYXNvbhgCIAEoCVIGcmVhc29u');

@$core.Deprecated('Use getMeRequestDescriptor instead')
const GetMeRequest$json = {
  '1': 'GetMeRequest',
};

/// Descriptor for `GetMeRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getMeRequestDescriptor =
    $convert.base64Decode('CgxHZXRNZVJlcXVlc3Q=');

@$core.Deprecated('Use getMeResponseDescriptor instead')
const GetMeResponse$json = {
  '1': 'GetMeResponse',
  '2': [
    {
      '1': 'profile',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.identity.v1.Profile',
      '10': 'profile'
    },
    {
      '1': 'status',
      '3': 2,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.identity.v1.AccountStatus',
      '10': 'status'
    },
    {'1': 'email_verified', '3': 3, '4': 1, '5': 8, '10': 'emailVerified'},
    {
      '1': 'unread_notification_count',
      '3': 4,
      '4': 1,
      '5': 3,
      '10': 'unreadNotificationCount'
    },
    {'1': 'enabled_features', '3': 5, '4': 3, '5': 9, '10': 'enabledFeatures'},
  ],
};

/// Descriptor for `GetMeResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getMeResponseDescriptor = $convert.base64Decode(
    'Cg1HZXRNZVJlc3BvbnNlEjYKB3Byb2ZpbGUYASABKAsyHC5kemVyb3RoLmlkZW50aXR5LnYxLl'
    'Byb2ZpbGVSB3Byb2ZpbGUSOgoGc3RhdHVzGAIgASgOMiIuZHplcm90aC5pZGVudGl0eS52MS5B'
    'Y2NvdW50U3RhdHVzUgZzdGF0dXMSJQoOZW1haWxfdmVyaWZpZWQYAyABKAhSDWVtYWlsVmVyaW'
    'ZpZWQSOgoZdW5yZWFkX25vdGlmaWNhdGlvbl9jb3VudBgEIAEoA1IXdW5yZWFkTm90aWZpY2F0'
    'aW9uQ291bnQSKQoQZW5hYmxlZF9mZWF0dXJlcxgFIAMoCVIPZW5hYmxlZEZlYXR1cmVz');

@$core.Deprecated('Use getProfileRequestDescriptor instead')
const GetProfileRequest$json = {
  '1': 'GetProfileRequest',
  '2': [
    {'1': 'user_id', '3': 1, '4': 1, '5': 9, '9': 0, '10': 'userId'},
    {'1': 'handle', '3': 2, '4': 1, '5': 9, '9': 0, '10': 'handle'},
  ],
  '8': [
    {'1': 'target'},
  ],
};

/// Descriptor for `GetProfileRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getProfileRequestDescriptor = $convert.base64Decode(
    'ChFHZXRQcm9maWxlUmVxdWVzdBIZCgd1c2VyX2lkGAEgASgJSABSBnVzZXJJZBIYCgZoYW5kbG'
    'UYAiABKAlIAFIGaGFuZGxlQggKBnRhcmdldA==');

@$core.Deprecated('Use getProfileResponseDescriptor instead')
const GetProfileResponse$json = {
  '1': 'GetProfileResponse',
  '2': [
    {
      '1': 'profile',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.identity.v1.Profile',
      '10': 'profile'
    },
  ],
};

/// Descriptor for `GetProfileResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getProfileResponseDescriptor = $convert.base64Decode(
    'ChJHZXRQcm9maWxlUmVzcG9uc2USNgoHcHJvZmlsZRgBIAEoCzIcLmR6ZXJvdGguaWRlbnRpdH'
    'kudjEuUHJvZmlsZVIHcHJvZmlsZQ==');

@$core.Deprecated('Use updateProfileRequestDescriptor instead')
const UpdateProfileRequest$json = {
  '1': 'UpdateProfileRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {
      '1': 'display_name',
      '3': 2,
      '4': 1,
      '5': 9,
      '9': 0,
      '10': 'displayName',
      '17': true
    },
    {'1': 'bio', '3': 3, '4': 1, '5': 9, '9': 1, '10': 'bio', '17': true},
    {
      '1': 'avatar_media_id',
      '3': 4,
      '4': 1,
      '5': 9,
      '9': 2,
      '10': 'avatarMediaId',
      '17': true
    },
    {
      '1': 'is_private',
      '3': 5,
      '4': 1,
      '5': 8,
      '9': 3,
      '10': 'isPrivate',
      '17': true
    },
  ],
  '8': [
    {'1': '_display_name'},
    {'1': '_bio'},
    {'1': '_avatar_media_id'},
    {'1': '_is_private'},
  ],
};

/// Descriptor for `UpdateProfileRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List updateProfileRequestDescriptor = $convert.base64Decode(
    'ChRVcGRhdGVQcm9maWxlUmVxdWVzdBInCg9pZGVtcG90ZW5jeV9rZXkYASABKAlSDmlkZW1wb3'
    'RlbmN5S2V5EiYKDGRpc3BsYXlfbmFtZRgCIAEoCUgAUgtkaXNwbGF5TmFtZYgBARIVCgNiaW8Y'
    'AyABKAlIAVIDYmlviAEBEisKD2F2YXRhcl9tZWRpYV9pZBgEIAEoCUgCUg1hdmF0YXJNZWRpYU'
    'lkiAEBEiIKCmlzX3ByaXZhdGUYBSABKAhIA1IJaXNQcml2YXRliAEBQg8KDV9kaXNwbGF5X25h'
    'bWVCBgoEX2Jpb0ISChBfYXZhdGFyX21lZGlhX2lkQg0KC19pc19wcml2YXRl');

@$core.Deprecated('Use updateProfileResponseDescriptor instead')
const UpdateProfileResponse$json = {
  '1': 'UpdateProfileResponse',
  '2': [
    {
      '1': 'profile',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.identity.v1.Profile',
      '10': 'profile'
    },
  ],
};

/// Descriptor for `UpdateProfileResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List updateProfileResponseDescriptor = $convert.base64Decode(
    'ChVVcGRhdGVQcm9maWxlUmVzcG9uc2USNgoHcHJvZmlsZRgBIAEoCzIcLmR6ZXJvdGguaWRlbn'
    'RpdHkudjEuUHJvZmlsZVIHcHJvZmlsZQ==');

@$core.Deprecated('Use changeHandleRequestDescriptor instead')
const ChangeHandleRequest$json = {
  '1': 'ChangeHandleRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'new_handle', '3': 2, '4': 1, '5': 9, '10': 'newHandle'},
  ],
};

/// Descriptor for `ChangeHandleRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List changeHandleRequestDescriptor = $convert.base64Decode(
    'ChNDaGFuZ2VIYW5kbGVSZXF1ZXN0EicKD2lkZW1wb3RlbmN5X2tleRgBIAEoCVIOaWRlbXBvdG'
    'VuY3lLZXkSHQoKbmV3X2hhbmRsZRgCIAEoCVIJbmV3SGFuZGxl');

@$core.Deprecated('Use changeHandleResponseDescriptor instead')
const ChangeHandleResponse$json = {
  '1': 'ChangeHandleResponse',
  '2': [
    {
      '1': 'profile',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.identity.v1.Profile',
      '10': 'profile'
    },
  ],
};

/// Descriptor for `ChangeHandleResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List changeHandleResponseDescriptor = $convert.base64Decode(
    'ChRDaGFuZ2VIYW5kbGVSZXNwb25zZRI2Cgdwcm9maWxlGAEgASgLMhwuZHplcm90aC5pZGVudG'
    'l0eS52MS5Qcm9maWxlUgdwcm9maWxl');

@$core.Deprecated('Use deleteAccountRequestDescriptor instead')
const DeleteAccountRequest$json = {
  '1': 'DeleteAccountRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
  ],
};

/// Descriptor for `DeleteAccountRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List deleteAccountRequestDescriptor = $convert.base64Decode(
    'ChREZWxldGVBY2NvdW50UmVxdWVzdBInCg9pZGVtcG90ZW5jeV9rZXkYASABKAlSDmlkZW1wb3'
    'RlbmN5S2V5');

@$core.Deprecated('Use deleteAccountResponseDescriptor instead')
const DeleteAccountResponse$json = {
  '1': 'DeleteAccountResponse',
  '2': [
    {
      '1': 'deletion_requested_at',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '10': 'deletionRequestedAt'
    },
  ],
};

/// Descriptor for `DeleteAccountResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List deleteAccountResponseDescriptor = $convert.base64Decode(
    'ChVEZWxldGVBY2NvdW50UmVzcG9uc2USTgoVZGVsZXRpb25fcmVxdWVzdGVkX2F0GAEgASgLMh'
    'ouZ29vZ2xlLnByb3RvYnVmLlRpbWVzdGFtcFITZGVsZXRpb25SZXF1ZXN0ZWRBdA==');

@$core.Deprecated('Use requestAccountExportRequestDescriptor instead')
const RequestAccountExportRequest$json = {
  '1': 'RequestAccountExportRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
  ],
};

/// Descriptor for `RequestAccountExportRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List requestAccountExportRequestDescriptor =
    $convert.base64Decode(
        'ChtSZXF1ZXN0QWNjb3VudEV4cG9ydFJlcXVlc3QSJwoPaWRlbXBvdGVuY3lfa2V5GAEgASgJUg'
        '5pZGVtcG90ZW5jeUtleQ==');

@$core.Deprecated('Use requestAccountExportResponseDescriptor instead')
const RequestAccountExportResponse$json = {
  '1': 'RequestAccountExportResponse',
  '2': [
    {'1': 'export_id', '3': 1, '4': 1, '5': 9, '10': 'exportId'},
    {
      '1': 'status',
      '3': 2,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.identity.v1.ExportStatus',
      '10': 'status'
    },
  ],
};

/// Descriptor for `RequestAccountExportResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List requestAccountExportResponseDescriptor =
    $convert.base64Decode(
        'ChxSZXF1ZXN0QWNjb3VudEV4cG9ydFJlc3BvbnNlEhsKCWV4cG9ydF9pZBgBIAEoCVIIZXhwb3'
        'J0SWQSOQoGc3RhdHVzGAIgASgOMiEuZHplcm90aC5pZGVudGl0eS52MS5FeHBvcnRTdGF0dXNS'
        'BnN0YXR1cw==');

@$core.Deprecated('Use getAccountExportRequestDescriptor instead')
const GetAccountExportRequest$json = {
  '1': 'GetAccountExportRequest',
  '2': [
    {'1': 'export_id', '3': 1, '4': 1, '5': 9, '10': 'exportId'},
  ],
};

/// Descriptor for `GetAccountExportRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getAccountExportRequestDescriptor =
    $convert.base64Decode(
        'ChdHZXRBY2NvdW50RXhwb3J0UmVxdWVzdBIbCglleHBvcnRfaWQYASABKAlSCGV4cG9ydElk');

@$core.Deprecated('Use getAccountExportResponseDescriptor instead')
const GetAccountExportResponse$json = {
  '1': 'GetAccountExportResponse',
  '2': [
    {'1': 'export_id', '3': 1, '4': 1, '5': 9, '10': 'exportId'},
    {
      '1': 'status',
      '3': 2,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.identity.v1.ExportStatus',
      '10': 'status'
    },
    {'1': 'download_url', '3': 3, '4': 1, '5': 9, '10': 'downloadUrl'},
    {
      '1': 'download_url_expires_at',
      '3': 4,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '10': 'downloadUrlExpiresAt'
    },
    {
      '1': 'expires_at',
      '3': 5,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '10': 'expiresAt'
    },
  ],
};

/// Descriptor for `GetAccountExportResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getAccountExportResponseDescriptor = $convert.base64Decode(
    'ChhHZXRBY2NvdW50RXhwb3J0UmVzcG9uc2USGwoJZXhwb3J0X2lkGAEgASgJUghleHBvcnRJZB'
    'I5CgZzdGF0dXMYAiABKA4yIS5kemVyb3RoLmlkZW50aXR5LnYxLkV4cG9ydFN0YXR1c1IGc3Rh'
    'dHVzEiEKDGRvd25sb2FkX3VybBgDIAEoCVILZG93bmxvYWRVcmwSUQoXZG93bmxvYWRfdXJsX2'
    'V4cGlyZXNfYXQYBCABKAsyGi5nb29nbGUucHJvdG9idWYuVGltZXN0YW1wUhRkb3dubG9hZFVy'
    'bEV4cGlyZXNBdBI5CgpleHBpcmVzX2F0GAUgASgLMhouZ29vZ2xlLnByb3RvYnVmLlRpbWVzdG'
    'FtcFIJZXhwaXJlc0F0');

const $core.Map<$core.String, $core.dynamic> IdentityServiceBase$json = {
  '1': 'IdentityService',
  '2': [
    {
      '1': 'CreateProfile',
      '2': '.dzeroth.identity.v1.CreateProfileRequest',
      '3': '.dzeroth.identity.v1.CreateProfileResponse'
    },
    {
      '1': 'CheckHandleAvailability',
      '2': '.dzeroth.identity.v1.CheckHandleAvailabilityRequest',
      '3': '.dzeroth.identity.v1.CheckHandleAvailabilityResponse',
      '4': {'34': 1},
    },
    {
      '1': 'GetMe',
      '2': '.dzeroth.identity.v1.GetMeRequest',
      '3': '.dzeroth.identity.v1.GetMeResponse',
      '4': {'34': 1},
    },
    {
      '1': 'GetProfile',
      '2': '.dzeroth.identity.v1.GetProfileRequest',
      '3': '.dzeroth.identity.v1.GetProfileResponse',
      '4': {'34': 1},
    },
    {
      '1': 'UpdateProfile',
      '2': '.dzeroth.identity.v1.UpdateProfileRequest',
      '3': '.dzeroth.identity.v1.UpdateProfileResponse'
    },
    {
      '1': 'ChangeHandle',
      '2': '.dzeroth.identity.v1.ChangeHandleRequest',
      '3': '.dzeroth.identity.v1.ChangeHandleResponse'
    },
    {
      '1': 'DeleteAccount',
      '2': '.dzeroth.identity.v1.DeleteAccountRequest',
      '3': '.dzeroth.identity.v1.DeleteAccountResponse'
    },
    {
      '1': 'RequestAccountExport',
      '2': '.dzeroth.identity.v1.RequestAccountExportRequest',
      '3': '.dzeroth.identity.v1.RequestAccountExportResponse'
    },
    {
      '1': 'GetAccountExport',
      '2': '.dzeroth.identity.v1.GetAccountExportRequest',
      '3': '.dzeroth.identity.v1.GetAccountExportResponse',
      '4': {'34': 1},
    },
  ],
};

@$core.Deprecated('Use identityServiceDescriptor instead')
const $core.Map<$core.String, $core.Map<$core.String, $core.dynamic>>
    IdentityServiceBase$messageJson = {
  '.dzeroth.identity.v1.CreateProfileRequest': CreateProfileRequest$json,
  '.dzeroth.identity.v1.CreateProfileResponse': CreateProfileResponse$json,
  '.dzeroth.identity.v1.Profile': Profile$json,
  '.google.protobuf.Timestamp': $0.Timestamp$json,
  '.dzeroth.identity.v1.CheckHandleAvailabilityRequest':
      CheckHandleAvailabilityRequest$json,
  '.dzeroth.identity.v1.CheckHandleAvailabilityResponse':
      CheckHandleAvailabilityResponse$json,
  '.dzeroth.identity.v1.GetMeRequest': GetMeRequest$json,
  '.dzeroth.identity.v1.GetMeResponse': GetMeResponse$json,
  '.dzeroth.identity.v1.GetProfileRequest': GetProfileRequest$json,
  '.dzeroth.identity.v1.GetProfileResponse': GetProfileResponse$json,
  '.dzeroth.identity.v1.UpdateProfileRequest': UpdateProfileRequest$json,
  '.dzeroth.identity.v1.UpdateProfileResponse': UpdateProfileResponse$json,
  '.dzeroth.identity.v1.ChangeHandleRequest': ChangeHandleRequest$json,
  '.dzeroth.identity.v1.ChangeHandleResponse': ChangeHandleResponse$json,
  '.dzeroth.identity.v1.DeleteAccountRequest': DeleteAccountRequest$json,
  '.dzeroth.identity.v1.DeleteAccountResponse': DeleteAccountResponse$json,
  '.dzeroth.identity.v1.RequestAccountExportRequest':
      RequestAccountExportRequest$json,
  '.dzeroth.identity.v1.RequestAccountExportResponse':
      RequestAccountExportResponse$json,
  '.dzeroth.identity.v1.GetAccountExportRequest': GetAccountExportRequest$json,
  '.dzeroth.identity.v1.GetAccountExportResponse':
      GetAccountExportResponse$json,
};

/// Descriptor for `IdentityService`. Decode as a `google.protobuf.ServiceDescriptorProto`.
final $typed_data.Uint8List identityServiceDescriptor = $convert.base64Decode(
    'Cg9JZGVudGl0eVNlcnZpY2USZgoNQ3JlYXRlUHJvZmlsZRIpLmR6ZXJvdGguaWRlbnRpdHkudj'
    'EuQ3JlYXRlUHJvZmlsZVJlcXVlc3QaKi5kemVyb3RoLmlkZW50aXR5LnYxLkNyZWF0ZVByb2Zp'
    'bGVSZXNwb25zZRKJAQoXQ2hlY2tIYW5kbGVBdmFpbGFiaWxpdHkSMy5kemVyb3RoLmlkZW50aX'
    'R5LnYxLkNoZWNrSGFuZGxlQXZhaWxhYmlsaXR5UmVxdWVzdBo0LmR6ZXJvdGguaWRlbnRpdHku'
    'djEuQ2hlY2tIYW5kbGVBdmFpbGFiaWxpdHlSZXNwb25zZSIDkAIBElMKBUdldE1lEiEuZHplcm'
    '90aC5pZGVudGl0eS52MS5HZXRNZVJlcXVlc3QaIi5kemVyb3RoLmlkZW50aXR5LnYxLkdldE1l'
    'UmVzcG9uc2UiA5ACARJiCgpHZXRQcm9maWxlEiYuZHplcm90aC5pZGVudGl0eS52MS5HZXRQcm'
    '9maWxlUmVxdWVzdBonLmR6ZXJvdGguaWRlbnRpdHkudjEuR2V0UHJvZmlsZVJlc3BvbnNlIgOQ'
    'AgESZgoNVXBkYXRlUHJvZmlsZRIpLmR6ZXJvdGguaWRlbnRpdHkudjEuVXBkYXRlUHJvZmlsZV'
    'JlcXVlc3QaKi5kemVyb3RoLmlkZW50aXR5LnYxLlVwZGF0ZVByb2ZpbGVSZXNwb25zZRJjCgxD'
    'aGFuZ2VIYW5kbGUSKC5kemVyb3RoLmlkZW50aXR5LnYxLkNoYW5nZUhhbmRsZVJlcXVlc3QaKS'
    '5kemVyb3RoLmlkZW50aXR5LnYxLkNoYW5nZUhhbmRsZVJlc3BvbnNlEmYKDURlbGV0ZUFjY291'
    'bnQSKS5kemVyb3RoLmlkZW50aXR5LnYxLkRlbGV0ZUFjY291bnRSZXF1ZXN0GiouZHplcm90aC'
    '5pZGVudGl0eS52MS5EZWxldGVBY2NvdW50UmVzcG9uc2USewoUUmVxdWVzdEFjY291bnRFeHBv'
    'cnQSMC5kemVyb3RoLmlkZW50aXR5LnYxLlJlcXVlc3RBY2NvdW50RXhwb3J0UmVxdWVzdBoxLm'
    'R6ZXJvdGguaWRlbnRpdHkudjEuUmVxdWVzdEFjY291bnRFeHBvcnRSZXNwb25zZRJ0ChBHZXRB'
    'Y2NvdW50RXhwb3J0EiwuZHplcm90aC5pZGVudGl0eS52MS5HZXRBY2NvdW50RXhwb3J0UmVxdW'
    'VzdBotLmR6ZXJvdGguaWRlbnRpdHkudjEuR2V0QWNjb3VudEV4cG9ydFJlc3BvbnNlIgOQAgE=');
