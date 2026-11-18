// This is a generated file - do not edit.
//
// Generated from dzeroth/keys/v1/keys.proto.

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

@$core.Deprecated('Use keyDeviceDescriptor instead')
const KeyDevice$json = {
  '1': 'KeyDevice',
  '2': [
    {'1': 'device_id', '3': 1, '4': 1, '5': 9, '10': 'deviceId'},
    {
      '1': 'signature_public_key',
      '3': 2,
      '4': 1,
      '5': 12,
      '10': 'signaturePublicKey'
    },
    {
      '1': 'created_at',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '10': 'createdAt'
    },
    {
      '1': 'last_seen_at',
      '3': 4,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '10': 'lastSeenAt'
    },
    {'1': 'key_package_count', '3': 5, '4': 1, '5': 5, '10': 'keyPackageCount'},
    {'1': 'has_last_resort', '3': 6, '4': 1, '5': 8, '10': 'hasLastResort'},
  ],
};

/// Descriptor for `KeyDevice`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List keyDeviceDescriptor = $convert.base64Decode(
    'CglLZXlEZXZpY2USGwoJZGV2aWNlX2lkGAEgASgJUghkZXZpY2VJZBIwChRzaWduYXR1cmVfcH'
    'VibGljX2tleRgCIAEoDFISc2lnbmF0dXJlUHVibGljS2V5EjkKCmNyZWF0ZWRfYXQYAyABKAsy'
    'Gi5nb29nbGUucHJvdG9idWYuVGltZXN0YW1wUgljcmVhdGVkQXQSPAoMbGFzdF9zZWVuX2F0GA'
    'QgASgLMhouZ29vZ2xlLnByb3RvYnVmLlRpbWVzdGFtcFIKbGFzdFNlZW5BdBIqChFrZXlfcGFj'
    'a2FnZV9jb3VudBgFIAEoBVIPa2V5UGFja2FnZUNvdW50EiYKD2hhc19sYXN0X3Jlc29ydBgGIA'
    'EoCFINaGFzTGFzdFJlc29ydA==');

@$core.Deprecated('Use registerKeyDeviceRequestDescriptor instead')
const RegisterKeyDeviceRequest$json = {
  '1': 'RegisterKeyDeviceRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'device_id', '3': 2, '4': 1, '5': 9, '10': 'deviceId'},
    {
      '1': 'signature_public_key',
      '3': 3,
      '4': 1,
      '5': 12,
      '10': 'signaturePublicKey'
    },
  ],
};

/// Descriptor for `RegisterKeyDeviceRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List registerKeyDeviceRequestDescriptor = $convert.base64Decode(
    'ChhSZWdpc3RlcktleURldmljZVJlcXVlc3QSJwoPaWRlbXBvdGVuY3lfa2V5GAEgASgJUg5pZG'
    'VtcG90ZW5jeUtleRIbCglkZXZpY2VfaWQYAiABKAlSCGRldmljZUlkEjAKFHNpZ25hdHVyZV9w'
    'dWJsaWNfa2V5GAMgASgMUhJzaWduYXR1cmVQdWJsaWNLZXk=');

@$core.Deprecated('Use registerKeyDeviceResponseDescriptor instead')
const RegisterKeyDeviceResponse$json = {
  '1': 'RegisterKeyDeviceResponse',
  '2': [
    {
      '1': 'device',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.keys.v1.KeyDevice',
      '10': 'device'
    },
  ],
};

/// Descriptor for `RegisterKeyDeviceResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List registerKeyDeviceResponseDescriptor =
    $convert.base64Decode(
        'ChlSZWdpc3RlcktleURldmljZVJlc3BvbnNlEjIKBmRldmljZRgBIAEoCzIaLmR6ZXJvdGgua2'
        'V5cy52MS5LZXlEZXZpY2VSBmRldmljZQ==');

@$core.Deprecated('Use listMyKeyDevicesRequestDescriptor instead')
const ListMyKeyDevicesRequest$json = {
  '1': 'ListMyKeyDevicesRequest',
};

/// Descriptor for `ListMyKeyDevicesRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listMyKeyDevicesRequestDescriptor =
    $convert.base64Decode('ChdMaXN0TXlLZXlEZXZpY2VzUmVxdWVzdA==');

@$core.Deprecated('Use listMyKeyDevicesResponseDescriptor instead')
const ListMyKeyDevicesResponse$json = {
  '1': 'ListMyKeyDevicesResponse',
  '2': [
    {
      '1': 'devices',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.keys.v1.KeyDevice',
      '10': 'devices'
    },
  ],
};

/// Descriptor for `ListMyKeyDevicesResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listMyKeyDevicesResponseDescriptor =
    $convert.base64Decode(
        'ChhMaXN0TXlLZXlEZXZpY2VzUmVzcG9uc2USNAoHZGV2aWNlcxgBIAMoCzIaLmR6ZXJvdGgua2'
        'V5cy52MS5LZXlEZXZpY2VSB2RldmljZXM=');

@$core.Deprecated('Use removeKeyDeviceRequestDescriptor instead')
const RemoveKeyDeviceRequest$json = {
  '1': 'RemoveKeyDeviceRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'device_id', '3': 2, '4': 1, '5': 9, '10': 'deviceId'},
  ],
};

/// Descriptor for `RemoveKeyDeviceRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List removeKeyDeviceRequestDescriptor =
    $convert.base64Decode(
        'ChZSZW1vdmVLZXlEZXZpY2VSZXF1ZXN0EicKD2lkZW1wb3RlbmN5X2tleRgBIAEoCVIOaWRlbX'
        'BvdGVuY3lLZXkSGwoJZGV2aWNlX2lkGAIgASgJUghkZXZpY2VJZA==');

@$core.Deprecated('Use removeKeyDeviceResponseDescriptor instead')
const RemoveKeyDeviceResponse$json = {
  '1': 'RemoveKeyDeviceResponse',
};

/// Descriptor for `RemoveKeyDeviceResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List removeKeyDeviceResponseDescriptor =
    $convert.base64Decode('ChdSZW1vdmVLZXlEZXZpY2VSZXNwb25zZQ==');

@$core.Deprecated('Use uploadKeyPackagesRequestDescriptor instead')
const UploadKeyPackagesRequest$json = {
  '1': 'UploadKeyPackagesRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'device_id', '3': 2, '4': 1, '5': 9, '10': 'deviceId'},
    {'1': 'key_packages', '3': 3, '4': 3, '5': 12, '10': 'keyPackages'},
    {
      '1': 'last_resort_key_package',
      '3': 4,
      '4': 1,
      '5': 12,
      '10': 'lastResortKeyPackage'
    },
  ],
};

/// Descriptor for `UploadKeyPackagesRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List uploadKeyPackagesRequestDescriptor = $convert.base64Decode(
    'ChhVcGxvYWRLZXlQYWNrYWdlc1JlcXVlc3QSJwoPaWRlbXBvdGVuY3lfa2V5GAEgASgJUg5pZG'
    'VtcG90ZW5jeUtleRIbCglkZXZpY2VfaWQYAiABKAlSCGRldmljZUlkEiEKDGtleV9wYWNrYWdl'
    'cxgDIAMoDFILa2V5UGFja2FnZXMSNQoXbGFzdF9yZXNvcnRfa2V5X3BhY2thZ2UYBCABKAxSFG'
    'xhc3RSZXNvcnRLZXlQYWNrYWdl');

@$core.Deprecated('Use uploadKeyPackagesResponseDescriptor instead')
const UploadKeyPackagesResponse$json = {
  '1': 'UploadKeyPackagesResponse',
  '2': [
    {'1': 'key_package_count', '3': 1, '4': 1, '5': 5, '10': 'keyPackageCount'},
    {'1': 'has_last_resort', '3': 2, '4': 1, '5': 8, '10': 'hasLastResort'},
  ],
};

/// Descriptor for `UploadKeyPackagesResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List uploadKeyPackagesResponseDescriptor = $convert.base64Decode(
    'ChlVcGxvYWRLZXlQYWNrYWdlc1Jlc3BvbnNlEioKEWtleV9wYWNrYWdlX2NvdW50GAEgASgFUg'
    '9rZXlQYWNrYWdlQ291bnQSJgoPaGFzX2xhc3RfcmVzb3J0GAIgASgIUg1oYXNMYXN0UmVzb3J0');

@$core.Deprecated('Use getKeyDevicesRequestDescriptor instead')
const GetKeyDevicesRequest$json = {
  '1': 'GetKeyDevicesRequest',
  '2': [
    {'1': 'user_ids', '3': 1, '4': 3, '5': 9, '10': 'userIds'},
  ],
};

/// Descriptor for `GetKeyDevicesRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getKeyDevicesRequestDescriptor =
    $convert.base64Decode(
        'ChRHZXRLZXlEZXZpY2VzUmVxdWVzdBIZCgh1c2VyX2lkcxgBIAMoCVIHdXNlcklkcw==');

@$core.Deprecated('Use userKeyDevicesDescriptor instead')
const UserKeyDevices$json = {
  '1': 'UserKeyDevices',
  '2': [
    {'1': 'user_id', '3': 1, '4': 1, '5': 9, '10': 'userId'},
    {
      '1': 'devices',
      '3': 2,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.keys.v1.KeyDevice',
      '10': 'devices'
    },
  ],
};

/// Descriptor for `UserKeyDevices`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List userKeyDevicesDescriptor = $convert.base64Decode(
    'Cg5Vc2VyS2V5RGV2aWNlcxIXCgd1c2VyX2lkGAEgASgJUgZ1c2VySWQSNAoHZGV2aWNlcxgCIA'
    'MoCzIaLmR6ZXJvdGgua2V5cy52MS5LZXlEZXZpY2VSB2RldmljZXM=');

@$core.Deprecated('Use getKeyDevicesResponseDescriptor instead')
const GetKeyDevicesResponse$json = {
  '1': 'GetKeyDevicesResponse',
  '2': [
    {
      '1': 'users',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.keys.v1.UserKeyDevices',
      '10': 'users'
    },
  ],
};

/// Descriptor for `GetKeyDevicesResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getKeyDevicesResponseDescriptor = $convert.base64Decode(
    'ChVHZXRLZXlEZXZpY2VzUmVzcG9uc2USNQoFdXNlcnMYASADKAsyHy5kemVyb3RoLmtleXMudj'
    'EuVXNlcktleURldmljZXNSBXVzZXJz');

@$core.Deprecated('Use claimKeyPackagesRequestDescriptor instead')
const ClaimKeyPackagesRequest$json = {
  '1': 'ClaimKeyPackagesRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'user_id', '3': 2, '4': 1, '5': 9, '10': 'userId'},
    {'1': 'exclude_device_id', '3': 3, '4': 1, '5': 9, '10': 'excludeDeviceId'},
  ],
};

/// Descriptor for `ClaimKeyPackagesRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List claimKeyPackagesRequestDescriptor = $convert.base64Decode(
    'ChdDbGFpbUtleVBhY2thZ2VzUmVxdWVzdBInCg9pZGVtcG90ZW5jeV9rZXkYASABKAlSDmlkZW'
    '1wb3RlbmN5S2V5EhcKB3VzZXJfaWQYAiABKAlSBnVzZXJJZBIqChFleGNsdWRlX2RldmljZV9p'
    'ZBgDIAEoCVIPZXhjbHVkZURldmljZUlk');

@$core.Deprecated('Use claimedKeyPackageDescriptor instead')
const ClaimedKeyPackage$json = {
  '1': 'ClaimedKeyPackage',
  '2': [
    {'1': 'device_id', '3': 1, '4': 1, '5': 9, '10': 'deviceId'},
    {
      '1': 'signature_public_key',
      '3': 2,
      '4': 1,
      '5': 12,
      '10': 'signaturePublicKey'
    },
    {'1': 'key_package', '3': 3, '4': 1, '5': 12, '10': 'keyPackage'},
    {'1': 'has_key_package', '3': 4, '4': 1, '5': 8, '10': 'hasKeyPackage'},
    {'1': 'last_resort', '3': 5, '4': 1, '5': 8, '10': 'lastResort'},
  ],
};

/// Descriptor for `ClaimedKeyPackage`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List claimedKeyPackageDescriptor = $convert.base64Decode(
    'ChFDbGFpbWVkS2V5UGFja2FnZRIbCglkZXZpY2VfaWQYASABKAlSCGRldmljZUlkEjAKFHNpZ2'
    '5hdHVyZV9wdWJsaWNfa2V5GAIgASgMUhJzaWduYXR1cmVQdWJsaWNLZXkSHwoLa2V5X3BhY2th'
    'Z2UYAyABKAxSCmtleVBhY2thZ2USJgoPaGFzX2tleV9wYWNrYWdlGAQgASgIUg1oYXNLZXlQYW'
    'NrYWdlEh8KC2xhc3RfcmVzb3J0GAUgASgIUgpsYXN0UmVzb3J0');

@$core.Deprecated('Use claimKeyPackagesResponseDescriptor instead')
const ClaimKeyPackagesResponse$json = {
  '1': 'ClaimKeyPackagesResponse',
  '2': [
    {
      '1': 'key_packages',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.keys.v1.ClaimedKeyPackage',
      '10': 'keyPackages'
    },
  ],
};

/// Descriptor for `ClaimKeyPackagesResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List claimKeyPackagesResponseDescriptor =
    $convert.base64Decode(
        'ChhDbGFpbUtleVBhY2thZ2VzUmVzcG9uc2USRQoMa2V5X3BhY2thZ2VzGAEgAygLMiIuZHplcm'
        '90aC5rZXlzLnYxLkNsYWltZWRLZXlQYWNrYWdlUgtrZXlQYWNrYWdlcw==');

const $core.Map<$core.String, $core.dynamic> KeyServiceBase$json = {
  '1': 'KeyService',
  '2': [
    {
      '1': 'RegisterKeyDevice',
      '2': '.dzeroth.keys.v1.RegisterKeyDeviceRequest',
      '3': '.dzeroth.keys.v1.RegisterKeyDeviceResponse'
    },
    {
      '1': 'ListMyKeyDevices',
      '2': '.dzeroth.keys.v1.ListMyKeyDevicesRequest',
      '3': '.dzeroth.keys.v1.ListMyKeyDevicesResponse',
      '4': {'34': 1},
    },
    {
      '1': 'RemoveKeyDevice',
      '2': '.dzeroth.keys.v1.RemoveKeyDeviceRequest',
      '3': '.dzeroth.keys.v1.RemoveKeyDeviceResponse'
    },
    {
      '1': 'UploadKeyPackages',
      '2': '.dzeroth.keys.v1.UploadKeyPackagesRequest',
      '3': '.dzeroth.keys.v1.UploadKeyPackagesResponse'
    },
    {
      '1': 'GetKeyDevices',
      '2': '.dzeroth.keys.v1.GetKeyDevicesRequest',
      '3': '.dzeroth.keys.v1.GetKeyDevicesResponse',
      '4': {'34': 1},
    },
    {
      '1': 'ClaimKeyPackages',
      '2': '.dzeroth.keys.v1.ClaimKeyPackagesRequest',
      '3': '.dzeroth.keys.v1.ClaimKeyPackagesResponse'
    },
  ],
};

@$core.Deprecated('Use keyServiceDescriptor instead')
const $core.Map<$core.String, $core.Map<$core.String, $core.dynamic>>
    KeyServiceBase$messageJson = {
  '.dzeroth.keys.v1.RegisterKeyDeviceRequest': RegisterKeyDeviceRequest$json,
  '.dzeroth.keys.v1.RegisterKeyDeviceResponse': RegisterKeyDeviceResponse$json,
  '.dzeroth.keys.v1.KeyDevice': KeyDevice$json,
  '.google.protobuf.Timestamp': $0.Timestamp$json,
  '.dzeroth.keys.v1.ListMyKeyDevicesRequest': ListMyKeyDevicesRequest$json,
  '.dzeroth.keys.v1.ListMyKeyDevicesResponse': ListMyKeyDevicesResponse$json,
  '.dzeroth.keys.v1.RemoveKeyDeviceRequest': RemoveKeyDeviceRequest$json,
  '.dzeroth.keys.v1.RemoveKeyDeviceResponse': RemoveKeyDeviceResponse$json,
  '.dzeroth.keys.v1.UploadKeyPackagesRequest': UploadKeyPackagesRequest$json,
  '.dzeroth.keys.v1.UploadKeyPackagesResponse': UploadKeyPackagesResponse$json,
  '.dzeroth.keys.v1.GetKeyDevicesRequest': GetKeyDevicesRequest$json,
  '.dzeroth.keys.v1.GetKeyDevicesResponse': GetKeyDevicesResponse$json,
  '.dzeroth.keys.v1.UserKeyDevices': UserKeyDevices$json,
  '.dzeroth.keys.v1.ClaimKeyPackagesRequest': ClaimKeyPackagesRequest$json,
  '.dzeroth.keys.v1.ClaimKeyPackagesResponse': ClaimKeyPackagesResponse$json,
  '.dzeroth.keys.v1.ClaimedKeyPackage': ClaimedKeyPackage$json,
};

/// Descriptor for `KeyService`. Decode as a `google.protobuf.ServiceDescriptorProto`.
final $typed_data.Uint8List keyServiceDescriptor = $convert.base64Decode(
    'CgpLZXlTZXJ2aWNlEmoKEVJlZ2lzdGVyS2V5RGV2aWNlEikuZHplcm90aC5rZXlzLnYxLlJlZ2'
    'lzdGVyS2V5RGV2aWNlUmVxdWVzdBoqLmR6ZXJvdGgua2V5cy52MS5SZWdpc3RlcktleURldmlj'
    'ZVJlc3BvbnNlEmwKEExpc3RNeUtleURldmljZXMSKC5kemVyb3RoLmtleXMudjEuTGlzdE15S2'
    'V5RGV2aWNlc1JlcXVlc3QaKS5kemVyb3RoLmtleXMudjEuTGlzdE15S2V5RGV2aWNlc1Jlc3Bv'
    'bnNlIgOQAgESZAoPUmVtb3ZlS2V5RGV2aWNlEicuZHplcm90aC5rZXlzLnYxLlJlbW92ZUtleU'
    'RldmljZVJlcXVlc3QaKC5kemVyb3RoLmtleXMudjEuUmVtb3ZlS2V5RGV2aWNlUmVzcG9uc2US'
    'agoRVXBsb2FkS2V5UGFja2FnZXMSKS5kemVyb3RoLmtleXMudjEuVXBsb2FkS2V5UGFja2FnZX'
    'NSZXF1ZXN0GiouZHplcm90aC5rZXlzLnYxLlVwbG9hZEtleVBhY2thZ2VzUmVzcG9uc2USYwoN'
    'R2V0S2V5RGV2aWNlcxIlLmR6ZXJvdGgua2V5cy52MS5HZXRLZXlEZXZpY2VzUmVxdWVzdBomLm'
    'R6ZXJvdGgua2V5cy52MS5HZXRLZXlEZXZpY2VzUmVzcG9uc2UiA5ACARJnChBDbGFpbUtleVBh'
    'Y2thZ2VzEiguZHplcm90aC5rZXlzLnYxLkNsYWltS2V5UGFja2FnZXNSZXF1ZXN0GikuZHplcm'
    '90aC5rZXlzLnYxLkNsYWltS2V5UGFja2FnZXNSZXNwb25zZQ==');
