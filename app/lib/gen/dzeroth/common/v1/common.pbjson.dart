// This is a generated file - do not edit.
//
// Generated from dzeroth/common/v1/common.proto.

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

@$core.Deprecated('Use errorReasonDescriptor instead')
const ErrorReason$json = {
  '1': 'ErrorReason',
  '2': [
    {'1': 'ERROR_REASON_UNSPECIFIED', '2': 0},
    {'1': 'ERROR_REASON_VALIDATION', '2': 1},
    {'1': 'ERROR_REASON_RATE_LIMITED', '2': 2},
    {'1': 'ERROR_REASON_QUOTA_EXCEEDED', '2': 3},
    {'1': 'ERROR_REASON_DEGRADED_MODE', '2': 4},
    {'1': 'ERROR_REASON_APP_CHECK_REQUIRED', '2': 5},
    {'1': 'ERROR_REASON_PROFILE_REQUIRED', '2': 6},
    {'1': 'ERROR_REASON_EMAIL_NOT_VERIFIED', '2': 7},
    {'1': 'ERROR_REASON_HANDLE_TAKEN', '2': 8},
    {'1': 'ERROR_REASON_LIMIT_REACHED', '2': 9},
    {'1': 'ERROR_REASON_MEDIA_NOT_READY', '2': 10},
    {'1': 'ERROR_REASON_IDEMPOTENCY_KEY_REUSED', '2': 11},
    {'1': 'ERROR_REASON_ACCOUNT_RESTRICTED', '2': 12},
    {'1': 'ERROR_REASON_TARGET_BLOCKED', '2': 13},
    {'1': 'ERROR_REASON_FEATURE_DISABLED', '2': 14},
  ],
};

/// Descriptor for `ErrorReason`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List errorReasonDescriptor = $convert.base64Decode(
    'CgtFcnJvclJlYXNvbhIcChhFUlJPUl9SRUFTT05fVU5TUEVDSUZJRUQQABIbChdFUlJPUl9SRU'
    'FTT05fVkFMSURBVElPThABEh0KGUVSUk9SX1JFQVNPTl9SQVRFX0xJTUlURUQQAhIfChtFUlJP'
    'Ul9SRUFTT05fUVVPVEFfRVhDRUVERUQQAxIeChpFUlJPUl9SRUFTT05fREVHUkFERURfTU9ERR'
    'AEEiMKH0VSUk9SX1JFQVNPTl9BUFBfQ0hFQ0tfUkVRVUlSRUQQBRIhCh1FUlJPUl9SRUFTT05f'
    'UFJPRklMRV9SRVFVSVJFRBAGEiMKH0VSUk9SX1JFQVNPTl9FTUFJTF9OT1RfVkVSSUZJRUQQBx'
    'IdChlFUlJPUl9SRUFTT05fSEFORExFX1RBS0VOEAgSHgoaRVJST1JfUkVBU09OX0xJTUlUX1JF'
    'QUNIRUQQCRIgChxFUlJPUl9SRUFTT05fTUVESUFfTk9UX1JFQURZEAoSJwojRVJST1JfUkVBU0'
    '9OX0lERU1QT1RFTkNZX0tFWV9SRVVTRUQQCxIjCh9FUlJPUl9SRUFTT05fQUNDT1VOVF9SRVNU'
    'UklDVEVEEAwSHwobRVJST1JfUkVBU09OX1RBUkdFVF9CTE9DS0VEEA0SIQodRVJST1JfUkVBU0'
    '9OX0ZFQVRVUkVfRElTQUJMRUQQDg==');

@$core.Deprecated('Use authorSnapshotDescriptor instead')
const AuthorSnapshot$json = {
  '1': 'AuthorSnapshot',
  '2': [
    {'1': 'user_id', '3': 1, '4': 1, '5': 9, '10': 'userId'},
    {'1': 'handle', '3': 2, '4': 1, '5': 9, '10': 'handle'},
    {'1': 'display_name', '3': 3, '4': 1, '5': 9, '10': 'displayName'},
    {'1': 'avatar_url', '3': 4, '4': 1, '5': 9, '10': 'avatarUrl'},
    {'1': 'verified', '3': 5, '4': 1, '5': 8, '10': 'verified'},
  ],
};

/// Descriptor for `AuthorSnapshot`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List authorSnapshotDescriptor = $convert.base64Decode(
    'Cg5BdXRob3JTbmFwc2hvdBIXCgd1c2VyX2lkGAEgASgJUgZ1c2VySWQSFgoGaGFuZGxlGAIgAS'
    'gJUgZoYW5kbGUSIQoMZGlzcGxheV9uYW1lGAMgASgJUgtkaXNwbGF5TmFtZRIdCgphdmF0YXJf'
    'dXJsGAQgASgJUglhdmF0YXJVcmwSGgoIdmVyaWZpZWQYBSABKAhSCHZlcmlmaWVk');

@$core.Deprecated('Use mediaRefDescriptor instead')
const MediaRef$json = {
  '1': 'MediaRef',
  '2': [
    {'1': 'media_id', '3': 1, '4': 1, '5': 9, '10': 'mediaId'},
    {'1': 'url', '3': 2, '4': 1, '5': 9, '10': 'url'},
    {'1': 'thumb_url', '3': 3, '4': 1, '5': 9, '10': 'thumbUrl'},
    {'1': 'width', '3': 4, '4': 1, '5': 5, '10': 'width'},
    {'1': 'height', '3': 5, '4': 1, '5': 5, '10': 'height'},
    {'1': 'blurhash', '3': 6, '4': 1, '5': 9, '10': 'blurhash'},
    {'1': 'alt_text', '3': 7, '4': 1, '5': 9, '10': 'altText'},
  ],
};

/// Descriptor for `MediaRef`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List mediaRefDescriptor = $convert.base64Decode(
    'CghNZWRpYVJlZhIZCghtZWRpYV9pZBgBIAEoCVIHbWVkaWFJZBIQCgN1cmwYAiABKAlSA3VybB'
    'IbCgl0aHVtYl91cmwYAyABKAlSCHRodW1iVXJsEhQKBXdpZHRoGAQgASgFUgV3aWR0aBIWCgZo'
    'ZWlnaHQYBSABKAVSBmhlaWdodBIaCghibHVyaGFzaBgGIAEoCVIIYmx1cmhhc2gSGQoIYWx0X3'
    'RleHQYByABKAlSB2FsdFRleHQ=');

@$core.Deprecated('Use errorDetailDescriptor instead')
const ErrorDetail$json = {
  '1': 'ErrorDetail',
  '2': [
    {
      '1': 'reason',
      '3': 1,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.common.v1.ErrorReason',
      '10': 'reason'
    },
    {'1': 'message', '3': 2, '4': 1, '5': 9, '10': 'message'},
    {
      '1': 'retry_after',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Duration',
      '10': 'retryAfter'
    },
    {
      '1': 'metadata',
      '3': 4,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.common.v1.ErrorDetail.MetadataEntry',
      '10': 'metadata'
    },
  ],
  '3': [ErrorDetail_MetadataEntry$json],
};

@$core.Deprecated('Use errorDetailDescriptor instead')
const ErrorDetail_MetadataEntry$json = {
  '1': 'MetadataEntry',
  '2': [
    {'1': 'key', '3': 1, '4': 1, '5': 9, '10': 'key'},
    {'1': 'value', '3': 2, '4': 1, '5': 9, '10': 'value'},
  ],
  '7': {'7': true},
};

/// Descriptor for `ErrorDetail`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List errorDetailDescriptor = $convert.base64Decode(
    'CgtFcnJvckRldGFpbBI2CgZyZWFzb24YASABKA4yHi5kemVyb3RoLmNvbW1vbi52MS5FcnJvcl'
    'JlYXNvblIGcmVhc29uEhgKB21lc3NhZ2UYAiABKAlSB21lc3NhZ2USOgoLcmV0cnlfYWZ0ZXIY'
    'AyABKAsyGS5nb29nbGUucHJvdG9idWYuRHVyYXRpb25SCnJldHJ5QWZ0ZXISSAoIbWV0YWRhdG'
    'EYBCADKAsyLC5kemVyb3RoLmNvbW1vbi52MS5FcnJvckRldGFpbC5NZXRhZGF0YUVudHJ5Ught'
    'ZXRhZGF0YRo7Cg1NZXRhZGF0YUVudHJ5EhAKA2tleRgBIAEoCVIDa2V5EhQKBXZhbHVlGAIgAS'
    'gJUgV2YWx1ZToCOAE=');
