// This is a generated file - do not edit.
//
// Generated from dzeroth/media/v1/media.proto.

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

import '../../common/v1/common.pbjson.dart' as $1;

@$core.Deprecated('Use mediaPurposeDescriptor instead')
const MediaPurpose$json = {
  '1': 'MediaPurpose',
  '2': [
    {'1': 'MEDIA_PURPOSE_UNSPECIFIED', '2': 0},
    {'1': 'MEDIA_PURPOSE_POST', '2': 1},
    {'1': 'MEDIA_PURPOSE_AVATAR', '2': 2},
  ],
};

/// Descriptor for `MediaPurpose`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List mediaPurposeDescriptor = $convert.base64Decode(
    'CgxNZWRpYVB1cnBvc2USHQoZTUVESUFfUFVSUE9TRV9VTlNQRUNJRklFRBAAEhYKEk1FRElBX1'
    'BVUlBPU0VfUE9TVBABEhgKFE1FRElBX1BVUlBPU0VfQVZBVEFSEAI=');

@$core.Deprecated('Use mediaStatusDescriptor instead')
const MediaStatus$json = {
  '1': 'MediaStatus',
  '2': [
    {'1': 'MEDIA_STATUS_UNSPECIFIED', '2': 0},
    {'1': 'MEDIA_STATUS_PENDING', '2': 1},
    {'1': 'MEDIA_STATUS_READY', '2': 2},
    {'1': 'MEDIA_STATUS_READY_UNSCREENED', '2': 3},
    {'1': 'MEDIA_STATUS_REJECTED', '2': 4},
  ],
};

/// Descriptor for `MediaStatus`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List mediaStatusDescriptor = $convert.base64Decode(
    'CgtNZWRpYVN0YXR1cxIcChhNRURJQV9TVEFUVVNfVU5TUEVDSUZJRUQQABIYChRNRURJQV9TVE'
    'FUVVNfUEVORElORxABEhYKEk1FRElBX1NUQVRVU19SRUFEWRACEiEKHU1FRElBX1NUQVRVU19S'
    'RUFEWV9VTlNDUkVFTkVEEAMSGQoVTUVESUFfU1RBVFVTX1JFSkVDVEVEEAQ=');

@$core.Deprecated('Use uploadItemDescriptor instead')
const UploadItem$json = {
  '1': 'UploadItem',
  '2': [
    {'1': 'content_type', '3': 1, '4': 1, '5': 9, '10': 'contentType'},
    {'1': 'full_size_bytes', '3': 2, '4': 1, '5': 3, '10': 'fullSizeBytes'},
    {'1': 'thumb_size_bytes', '3': 3, '4': 1, '5': 3, '10': 'thumbSizeBytes'},
    {'1': 'width', '3': 4, '4': 1, '5': 5, '10': 'width'},
    {'1': 'height', '3': 5, '4': 1, '5': 5, '10': 'height'},
    {'1': 'full_md5', '3': 6, '4': 1, '5': 9, '10': 'fullMd5'},
    {'1': 'thumb_md5', '3': 7, '4': 1, '5': 9, '10': 'thumbMd5'},
  ],
};

/// Descriptor for `UploadItem`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List uploadItemDescriptor = $convert.base64Decode(
    'CgpVcGxvYWRJdGVtEiEKDGNvbnRlbnRfdHlwZRgBIAEoCVILY29udGVudFR5cGUSJgoPZnVsbF'
    '9zaXplX2J5dGVzGAIgASgDUg1mdWxsU2l6ZUJ5dGVzEigKEHRodW1iX3NpemVfYnl0ZXMYAyAB'
    'KANSDnRodW1iU2l6ZUJ5dGVzEhQKBXdpZHRoGAQgASgFUgV3aWR0aBIWCgZoZWlnaHQYBSABKA'
    'VSBmhlaWdodBIZCghmdWxsX21kNRgGIAEoCVIHZnVsbE1kNRIbCgl0aHVtYl9tZDUYByABKAlS'
    'CHRodW1iTWQ1');

@$core.Deprecated('Use signedUploadDescriptor instead')
const SignedUpload$json = {
  '1': 'SignedUpload',
  '2': [
    {'1': 'url', '3': 1, '4': 1, '5': 9, '10': 'url'},
    {'1': 'method', '3': 2, '4': 1, '5': 9, '10': 'method'},
    {
      '1': 'headers',
      '3': 3,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.media.v1.SignedUpload.HeadersEntry',
      '10': 'headers'
    },
    {
      '1': 'expires_at',
      '3': 4,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '10': 'expiresAt'
    },
  ],
  '3': [SignedUpload_HeadersEntry$json],
};

@$core.Deprecated('Use signedUploadDescriptor instead')
const SignedUpload_HeadersEntry$json = {
  '1': 'HeadersEntry',
  '2': [
    {'1': 'key', '3': 1, '4': 1, '5': 9, '10': 'key'},
    {'1': 'value', '3': 2, '4': 1, '5': 9, '10': 'value'},
  ],
  '7': {'7': true},
};

/// Descriptor for `SignedUpload`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List signedUploadDescriptor = $convert.base64Decode(
    'CgxTaWduZWRVcGxvYWQSEAoDdXJsGAEgASgJUgN1cmwSFgoGbWV0aG9kGAIgASgJUgZtZXRob2'
    'QSRQoHaGVhZGVycxgDIAMoCzIrLmR6ZXJvdGgubWVkaWEudjEuU2lnbmVkVXBsb2FkLkhlYWRl'
    'cnNFbnRyeVIHaGVhZGVycxI5CgpleHBpcmVzX2F0GAQgASgLMhouZ29vZ2xlLnByb3RvYnVmLl'
    'RpbWVzdGFtcFIJZXhwaXJlc0F0GjoKDEhlYWRlcnNFbnRyeRIQCgNrZXkYASABKAlSA2tleRIU'
    'CgV2YWx1ZRgCIAEoCVIFdmFsdWU6AjgB');

@$core.Deprecated('Use uploadTargetDescriptor instead')
const UploadTarget$json = {
  '1': 'UploadTarget',
  '2': [
    {'1': 'media_id', '3': 1, '4': 1, '5': 9, '10': 'mediaId'},
    {
      '1': 'full',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.media.v1.SignedUpload',
      '10': 'full'
    },
    {
      '1': 'thumb',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.media.v1.SignedUpload',
      '10': 'thumb'
    },
  ],
};

/// Descriptor for `UploadTarget`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List uploadTargetDescriptor = $convert.base64Decode(
    'CgxVcGxvYWRUYXJnZXQSGQoIbWVkaWFfaWQYASABKAlSB21lZGlhSWQSMgoEZnVsbBgCIAEoCz'
    'IeLmR6ZXJvdGgubWVkaWEudjEuU2lnbmVkVXBsb2FkUgRmdWxsEjQKBXRodW1iGAMgASgLMh4u'
    'ZHplcm90aC5tZWRpYS52MS5TaWduZWRVcGxvYWRSBXRodW1i');

@$core.Deprecated('Use createUploadRequestDescriptor instead')
const CreateUploadRequest$json = {
  '1': 'CreateUploadRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {
      '1': 'purpose',
      '3': 2,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.media.v1.MediaPurpose',
      '10': 'purpose'
    },
    {
      '1': 'items',
      '3': 3,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.media.v1.UploadItem',
      '10': 'items'
    },
  ],
};

/// Descriptor for `CreateUploadRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List createUploadRequestDescriptor = $convert.base64Decode(
    'ChNDcmVhdGVVcGxvYWRSZXF1ZXN0EicKD2lkZW1wb3RlbmN5X2tleRgBIAEoCVIOaWRlbXBvdG'
    'VuY3lLZXkSOAoHcHVycG9zZRgCIAEoDjIeLmR6ZXJvdGgubWVkaWEudjEuTWVkaWFQdXJwb3Nl'
    'UgdwdXJwb3NlEjIKBWl0ZW1zGAMgAygLMhwuZHplcm90aC5tZWRpYS52MS5VcGxvYWRJdGVtUg'
    'VpdGVtcw==');

@$core.Deprecated('Use createUploadResponseDescriptor instead')
const CreateUploadResponse$json = {
  '1': 'CreateUploadResponse',
  '2': [
    {
      '1': 'targets',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.media.v1.UploadTarget',
      '10': 'targets'
    },
  ],
};

/// Descriptor for `CreateUploadResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List createUploadResponseDescriptor = $convert.base64Decode(
    'ChRDcmVhdGVVcGxvYWRSZXNwb25zZRI4Cgd0YXJnZXRzGAEgAygLMh4uZHplcm90aC5tZWRpYS'
    '52MS5VcGxvYWRUYXJnZXRSB3RhcmdldHM=');

@$core.Deprecated('Use finalizeItemDescriptor instead')
const FinalizeItem$json = {
  '1': 'FinalizeItem',
  '2': [
    {'1': 'media_id', '3': 1, '4': 1, '5': 9, '10': 'mediaId'},
    {'1': 'blurhash', '3': 2, '4': 1, '5': 9, '10': 'blurhash'},
  ],
};

/// Descriptor for `FinalizeItem`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List finalizeItemDescriptor = $convert.base64Decode(
    'CgxGaW5hbGl6ZUl0ZW0SGQoIbWVkaWFfaWQYASABKAlSB21lZGlhSWQSGgoIYmx1cmhhc2gYAi'
    'ABKAlSCGJsdXJoYXNo');

@$core.Deprecated('Use finalizeUploadRequestDescriptor instead')
const FinalizeUploadRequest$json = {
  '1': 'FinalizeUploadRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {
      '1': 'items',
      '3': 2,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.media.v1.FinalizeItem',
      '10': 'items'
    },
  ],
};

/// Descriptor for `FinalizeUploadRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List finalizeUploadRequestDescriptor = $convert.base64Decode(
    'ChVGaW5hbGl6ZVVwbG9hZFJlcXVlc3QSJwoPaWRlbXBvdGVuY3lfa2V5GAEgASgJUg5pZGVtcG'
    '90ZW5jeUtleRI0CgVpdGVtcxgCIAMoCzIeLmR6ZXJvdGgubWVkaWEudjEuRmluYWxpemVJdGVt'
    'UgVpdGVtcw==');

@$core.Deprecated('Use mediaResultDescriptor instead')
const MediaResult$json = {
  '1': 'MediaResult',
  '2': [
    {'1': 'media_id', '3': 1, '4': 1, '5': 9, '10': 'mediaId'},
    {
      '1': 'status',
      '3': 2,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.media.v1.MediaStatus',
      '10': 'status'
    },
    {
      '1': 'media',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.common.v1.MediaRef',
      '10': 'media'
    },
    {'1': 'rejection_reason', '3': 4, '4': 1, '5': 9, '10': 'rejectionReason'},
  ],
};

/// Descriptor for `MediaResult`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List mediaResultDescriptor = $convert.base64Decode(
    'CgtNZWRpYVJlc3VsdBIZCghtZWRpYV9pZBgBIAEoCVIHbWVkaWFJZBI1CgZzdGF0dXMYAiABKA'
    '4yHS5kemVyb3RoLm1lZGlhLnYxLk1lZGlhU3RhdHVzUgZzdGF0dXMSMQoFbWVkaWEYAyABKAsy'
    'Gy5kemVyb3RoLmNvbW1vbi52MS5NZWRpYVJlZlIFbWVkaWESKQoQcmVqZWN0aW9uX3JlYXNvbh'
    'gEIAEoCVIPcmVqZWN0aW9uUmVhc29u');

@$core.Deprecated('Use finalizeUploadResponseDescriptor instead')
const FinalizeUploadResponse$json = {
  '1': 'FinalizeUploadResponse',
  '2': [
    {
      '1': 'results',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.media.v1.MediaResult',
      '10': 'results'
    },
  ],
};

/// Descriptor for `FinalizeUploadResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List finalizeUploadResponseDescriptor =
    $convert.base64Decode(
        'ChZGaW5hbGl6ZVVwbG9hZFJlc3BvbnNlEjcKB3Jlc3VsdHMYASADKAsyHS5kemVyb3RoLm1lZG'
        'lhLnYxLk1lZGlhUmVzdWx0UgdyZXN1bHRz');

const $core.Map<$core.String, $core.dynamic> MediaServiceBase$json = {
  '1': 'MediaService',
  '2': [
    {
      '1': 'CreateUpload',
      '2': '.dzeroth.media.v1.CreateUploadRequest',
      '3': '.dzeroth.media.v1.CreateUploadResponse'
    },
    {
      '1': 'FinalizeUpload',
      '2': '.dzeroth.media.v1.FinalizeUploadRequest',
      '3': '.dzeroth.media.v1.FinalizeUploadResponse'
    },
  ],
};

@$core.Deprecated('Use mediaServiceDescriptor instead')
const $core.Map<$core.String, $core.Map<$core.String, $core.dynamic>>
    MediaServiceBase$messageJson = {
  '.dzeroth.media.v1.CreateUploadRequest': CreateUploadRequest$json,
  '.dzeroth.media.v1.UploadItem': UploadItem$json,
  '.dzeroth.media.v1.CreateUploadResponse': CreateUploadResponse$json,
  '.dzeroth.media.v1.UploadTarget': UploadTarget$json,
  '.dzeroth.media.v1.SignedUpload': SignedUpload$json,
  '.dzeroth.media.v1.SignedUpload.HeadersEntry': SignedUpload_HeadersEntry$json,
  '.google.protobuf.Timestamp': $0.Timestamp$json,
  '.dzeroth.media.v1.FinalizeUploadRequest': FinalizeUploadRequest$json,
  '.dzeroth.media.v1.FinalizeItem': FinalizeItem$json,
  '.dzeroth.media.v1.FinalizeUploadResponse': FinalizeUploadResponse$json,
  '.dzeroth.media.v1.MediaResult': MediaResult$json,
  '.dzeroth.common.v1.MediaRef': $1.MediaRef$json,
};

/// Descriptor for `MediaService`. Decode as a `google.protobuf.ServiceDescriptorProto`.
final $typed_data.Uint8List mediaServiceDescriptor = $convert.base64Decode(
    'CgxNZWRpYVNlcnZpY2USXQoMQ3JlYXRlVXBsb2FkEiUuZHplcm90aC5tZWRpYS52MS5DcmVhdG'
    'VVcGxvYWRSZXF1ZXN0GiYuZHplcm90aC5tZWRpYS52MS5DcmVhdGVVcGxvYWRSZXNwb25zZRJj'
    'Cg5GaW5hbGl6ZVVwbG9hZBInLmR6ZXJvdGgubWVkaWEudjEuRmluYWxpemVVcGxvYWRSZXF1ZX'
    'N0GiguZHplcm90aC5tZWRpYS52MS5GaW5hbGl6ZVVwbG9hZFJlc3BvbnNl');
