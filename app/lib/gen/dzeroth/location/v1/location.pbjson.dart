// This is a generated file - do not edit.
//
// Generated from dzeroth/location/v1/location.proto.

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

@$core.Deprecated('Use areaKindDescriptor instead')
const AreaKind$json = {
  '1': 'AreaKind',
  '2': [
    {'1': 'AREA_KIND_UNSPECIFIED', '2': 0},
    {'1': 'AREA_KIND_AREA', '2': 1},
    {'1': 'AREA_KIND_CITY', '2': 2},
  ],
};

/// Descriptor for `AreaKind`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List areaKindDescriptor = $convert.base64Decode(
    'CghBcmVhS2luZBIZChVBUkVBX0tJTkRfVU5TUEVDSUZJRUQQABISCg5BUkVBX0tJTkRfQVJFQR'
    'ABEhIKDkFSRUFfS0lORF9DSVRZEAI=');

@$core.Deprecated('Use locationPurposeDescriptor instead')
const LocationPurpose$json = {
  '1': 'LocationPurpose',
  '2': [
    {'1': 'LOCATION_PURPOSE_UNSPECIFIED', '2': 0},
    {'1': 'LOCATION_PURPOSE_PLANS_NEARBY', '2': 1},
  ],
};

/// Descriptor for `LocationPurpose`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List locationPurposeDescriptor = $convert.base64Decode(
    'Cg9Mb2NhdGlvblB1cnBvc2USIAocTE9DQVRJT05fUFVSUE9TRV9VTlNQRUNJRklFRBAAEiEKHU'
    'xPQ0FUSU9OX1BVUlBPU0VfUExBTlNfTkVBUkJZEAE=');

@$core.Deprecated('Use locationConsentActionDescriptor instead')
const LocationConsentAction$json = {
  '1': 'LocationConsentAction',
  '2': [
    {'1': 'LOCATION_CONSENT_ACTION_UNSPECIFIED', '2': 0},
    {'1': 'LOCATION_CONSENT_ACTION_GRANTED', '2': 1},
    {'1': 'LOCATION_CONSENT_ACTION_WITHDRAWN', '2': 2},
  ],
};

/// Descriptor for `LocationConsentAction`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List locationConsentActionDescriptor = $convert.base64Decode(
    'ChVMb2NhdGlvbkNvbnNlbnRBY3Rpb24SJwojTE9DQVRJT05fQ09OU0VOVF9BQ1RJT05fVU5TUE'
    'VDSUZJRUQQABIjCh9MT0NBVElPTl9DT05TRU5UX0FDVElPTl9HUkFOVEVEEAESJQohTE9DQVRJ'
    'T05fQ09OU0VOVF9BQ1RJT05fV0lUSERSQVdOEAI=');

@$core.Deprecated('Use areaDescriptor instead')
const Area$json = {
  '1': 'Area',
  '2': [
    {'1': 'area_id', '3': 1, '4': 1, '5': 9, '10': 'areaId'},
    {'1': 'name', '3': 2, '4': 1, '5': 9, '10': 'name'},
    {
      '1': 'kind',
      '3': 3,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.location.v1.AreaKind',
      '10': 'kind'
    },
    {'1': 'city_id', '3': 4, '4': 1, '5': 9, '10': 'cityId'},
    {'1': 'city_name', '3': 5, '4': 1, '5': 9, '10': 'cityName'},
    {'1': 'aliases', '3': 6, '4': 3, '5': 9, '10': 'aliases'},
    {'1': 'neighbour_ids', '3': 7, '4': 3, '5': 9, '10': 'neighbourIds'},
    {'1': 'retired', '3': 8, '4': 1, '5': 8, '10': 'retired'},
  ],
};

/// Descriptor for `Area`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List areaDescriptor = $convert.base64Decode(
    'CgRBcmVhEhcKB2FyZWFfaWQYASABKAlSBmFyZWFJZBISCgRuYW1lGAIgASgJUgRuYW1lEjEKBG'
    'tpbmQYAyABKA4yHS5kemVyb3RoLmxvY2F0aW9uLnYxLkFyZWFLaW5kUgRraW5kEhcKB2NpdHlf'
    'aWQYBCABKAlSBmNpdHlJZBIbCgljaXR5X25hbWUYBSABKAlSCGNpdHlOYW1lEhgKB2FsaWFzZX'
    'MYBiADKAlSB2FsaWFzZXMSIwoNbmVpZ2hib3VyX2lkcxgHIAMoCVIMbmVpZ2hib3VySWRzEhgK'
    'B3JldGlyZWQYCCABKAhSB3JldGlyZWQ=');

@$core.Deprecated('Use areaSummaryDescriptor instead')
const AreaSummary$json = {
  '1': 'AreaSummary',
  '2': [
    {'1': 'area_id', '3': 1, '4': 1, '5': 9, '10': 'areaId'},
    {'1': 'name', '3': 2, '4': 1, '5': 9, '10': 'name'},
    {
      '1': 'kind',
      '3': 3,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.location.v1.AreaKind',
      '10': 'kind'
    },
    {'1': 'city_id', '3': 4, '4': 1, '5': 9, '10': 'cityId'},
    {'1': 'city_name', '3': 5, '4': 1, '5': 9, '10': 'cityName'},
  ],
};

/// Descriptor for `AreaSummary`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List areaSummaryDescriptor = $convert.base64Decode(
    'CgtBcmVhU3VtbWFyeRIXCgdhcmVhX2lkGAEgASgJUgZhcmVhSWQSEgoEbmFtZRgCIAEoCVIEbm'
    'FtZRIxCgRraW5kGAMgASgOMh0uZHplcm90aC5sb2NhdGlvbi52MS5BcmVhS2luZFIEa2luZBIX'
    'CgdjaXR5X2lkGAQgASgJUgZjaXR5SWQSGwoJY2l0eV9uYW1lGAUgASgJUghjaXR5TmFtZQ==');

@$core.Deprecated('Use consentStateDescriptor instead')
const ConsentState$json = {
  '1': 'ConsentState',
  '2': [
    {
      '1': 'action',
      '3': 1,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.location.v1.LocationConsentAction',
      '10': 'action'
    },
    {
      '1': 'purpose',
      '3': 2,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.location.v1.LocationPurpose',
      '10': 'purpose'
    },
    {'1': 'copy_version', '3': 3, '4': 1, '5': 5, '10': 'copyVersion'},
    {
      '1': 'at',
      '3': 4,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '10': 'at'
    },
    {
      '1': 'adult_confirmed_at',
      '3': 5,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '10': 'adultConfirmedAt'
    },
  ],
};

/// Descriptor for `ConsentState`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List consentStateDescriptor = $convert.base64Decode(
    'CgxDb25zZW50U3RhdGUSQgoGYWN0aW9uGAEgASgOMiouZHplcm90aC5sb2NhdGlvbi52MS5Mb2'
    'NhdGlvbkNvbnNlbnRBY3Rpb25SBmFjdGlvbhI+CgdwdXJwb3NlGAIgASgOMiQuZHplcm90aC5s'
    'b2NhdGlvbi52MS5Mb2NhdGlvblB1cnBvc2VSB3B1cnBvc2USIQoMY29weV92ZXJzaW9uGAMgAS'
    'gFUgtjb3B5VmVyc2lvbhIqCgJhdBgEIAEoCzIaLmdvb2dsZS5wcm90b2J1Zi5UaW1lc3RhbXBS'
    'AmF0EkgKEmFkdWx0X2NvbmZpcm1lZF9hdBgFIAEoCzIaLmdvb2dsZS5wcm90b2J1Zi5UaW1lc3'
    'RhbXBSEGFkdWx0Q29uZmlybWVkQXQ=');

@$core.Deprecated('Use consentGrantDescriptor instead')
const ConsentGrant$json = {
  '1': 'ConsentGrant',
  '2': [
    {'1': 'copy_version', '3': 1, '4': 1, '5': 5, '10': 'copyVersion'},
    {'1': 'adult_confirmed', '3': 2, '4': 1, '5': 8, '10': 'adultConfirmed'},
  ],
};

/// Descriptor for `ConsentGrant`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List consentGrantDescriptor = $convert.base64Decode(
    'CgxDb25zZW50R3JhbnQSIQoMY29weV92ZXJzaW9uGAEgASgFUgtjb3B5VmVyc2lvbhInCg9hZH'
    'VsdF9jb25maXJtZWQYAiABKAhSDmFkdWx0Q29uZmlybWVk');

@$core.Deprecated('Use locationSettingsDescriptor instead')
const LocationSettings$json = {
  '1': 'LocationSettings',
  '2': [
    {
      '1': 'area',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.location.v1.AreaSummary',
      '10': 'area'
    },
    {
      '1': 'consent',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.location.v1.ConsentState',
      '10': 'consent'
    },
    {
      '1': 'required_copy_version',
      '3': 3,
      '4': 1,
      '5': 5,
      '10': 'requiredCopyVersion'
    },
    {
      '1': 'current_copy_version',
      '3': 4,
      '4': 1,
      '5': 5,
      '10': 'currentCopyVersion'
    },
  ],
};

/// Descriptor for `LocationSettings`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List locationSettingsDescriptor = $convert.base64Decode(
    'ChBMb2NhdGlvblNldHRpbmdzEjQKBGFyZWEYASABKAsyIC5kemVyb3RoLmxvY2F0aW9uLnYxLk'
    'FyZWFTdW1tYXJ5UgRhcmVhEjsKB2NvbnNlbnQYAiABKAsyIS5kemVyb3RoLmxvY2F0aW9uLnYx'
    'LkNvbnNlbnRTdGF0ZVIHY29uc2VudBIyChVyZXF1aXJlZF9jb3B5X3ZlcnNpb24YAyABKAVSE3'
    'JlcXVpcmVkQ29weVZlcnNpb24SMAoUY3VycmVudF9jb3B5X3ZlcnNpb24YBCABKAVSEmN1cnJl'
    'bnRDb3B5VmVyc2lvbg==');

@$core.Deprecated('Use getLocationSettingsRequestDescriptor instead')
const GetLocationSettingsRequest$json = {
  '1': 'GetLocationSettingsRequest',
};

/// Descriptor for `GetLocationSettingsRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getLocationSettingsRequestDescriptor =
    $convert.base64Decode('ChpHZXRMb2NhdGlvblNldHRpbmdzUmVxdWVzdA==');

@$core.Deprecated('Use getLocationSettingsResponseDescriptor instead')
const GetLocationSettingsResponse$json = {
  '1': 'GetLocationSettingsResponse',
  '2': [
    {
      '1': 'settings',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.location.v1.LocationSettings',
      '10': 'settings'
    },
  ],
};

/// Descriptor for `GetLocationSettingsResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getLocationSettingsResponseDescriptor =
    $convert.base64Decode(
        'ChtHZXRMb2NhdGlvblNldHRpbmdzUmVzcG9uc2USQQoIc2V0dGluZ3MYASABKAsyJS5kemVyb3'
        'RoLmxvY2F0aW9uLnYxLkxvY2F0aW9uU2V0dGluZ3NSCHNldHRpbmdz');

@$core.Deprecated('Use setAreaRequestDescriptor instead')
const SetAreaRequest$json = {
  '1': 'SetAreaRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'area_id', '3': 2, '4': 1, '5': 9, '10': 'areaId'},
    {
      '1': 'consent',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.location.v1.ConsentGrant',
      '10': 'consent'
    },
  ],
};

/// Descriptor for `SetAreaRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List setAreaRequestDescriptor = $convert.base64Decode(
    'Cg5TZXRBcmVhUmVxdWVzdBInCg9pZGVtcG90ZW5jeV9rZXkYASABKAlSDmlkZW1wb3RlbmN5S2'
    'V5EhcKB2FyZWFfaWQYAiABKAlSBmFyZWFJZBI7Cgdjb25zZW50GAMgASgLMiEuZHplcm90aC5s'
    'b2NhdGlvbi52MS5Db25zZW50R3JhbnRSB2NvbnNlbnQ=');

@$core.Deprecated('Use setAreaResponseDescriptor instead')
const SetAreaResponse$json = {
  '1': 'SetAreaResponse',
  '2': [
    {
      '1': 'settings',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.location.v1.LocationSettings',
      '10': 'settings'
    },
  ],
};

/// Descriptor for `SetAreaResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List setAreaResponseDescriptor = $convert.base64Decode(
    'Cg9TZXRBcmVhUmVzcG9uc2USQQoIc2V0dGluZ3MYASABKAsyJS5kemVyb3RoLmxvY2F0aW9uLn'
    'YxLkxvY2F0aW9uU2V0dGluZ3NSCHNldHRpbmdz');

@$core.Deprecated('Use clearAreaRequestDescriptor instead')
const ClearAreaRequest$json = {
  '1': 'ClearAreaRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
  ],
};

/// Descriptor for `ClearAreaRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List clearAreaRequestDescriptor = $convert.base64Decode(
    'ChBDbGVhckFyZWFSZXF1ZXN0EicKD2lkZW1wb3RlbmN5X2tleRgBIAEoCVIOaWRlbXBvdGVuY3'
    'lLZXk=');

@$core.Deprecated('Use clearAreaResponseDescriptor instead')
const ClearAreaResponse$json = {
  '1': 'ClearAreaResponse',
  '2': [
    {
      '1': 'settings',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.location.v1.LocationSettings',
      '10': 'settings'
    },
  ],
};

/// Descriptor for `ClearAreaResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List clearAreaResponseDescriptor = $convert.base64Decode(
    'ChFDbGVhckFyZWFSZXNwb25zZRJBCghzZXR0aW5ncxgBIAEoCzIlLmR6ZXJvdGgubG9jYXRpb2'
    '4udjEuTG9jYXRpb25TZXR0aW5nc1IIc2V0dGluZ3M=');

@$core.Deprecated('Use listAreasRequestDescriptor instead')
const ListAreasRequest$json = {
  '1': 'ListAreasRequest',
  '2': [
    {'1': 'limit', '3': 1, '4': 1, '5': 5, '10': 'limit'},
    {'1': 'page_token', '3': 2, '4': 1, '5': 9, '10': 'pageToken'},
    {'1': 'known_version', '3': 3, '4': 1, '5': 3, '10': 'knownVersion'},
  ],
};

/// Descriptor for `ListAreasRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listAreasRequestDescriptor = $convert.base64Decode(
    'ChBMaXN0QXJlYXNSZXF1ZXN0EhQKBWxpbWl0GAEgASgFUgVsaW1pdBIdCgpwYWdlX3Rva2VuGA'
    'IgASgJUglwYWdlVG9rZW4SIwoNa25vd25fdmVyc2lvbhgDIAEoA1IMa25vd25WZXJzaW9u');

@$core.Deprecated('Use listAreasResponseDescriptor instead')
const ListAreasResponse$json = {
  '1': 'ListAreasResponse',
  '2': [
    {
      '1': 'areas',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.location.v1.Area',
      '10': 'areas'
    },
    {'1': 'next_page_token', '3': 2, '4': 1, '5': 9, '10': 'nextPageToken'},
    {'1': 'version', '3': 3, '4': 1, '5': 3, '10': 'version'},
    {'1': 'not_modified', '3': 4, '4': 1, '5': 8, '10': 'notModified'},
  ],
};

/// Descriptor for `ListAreasResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listAreasResponseDescriptor = $convert.base64Decode(
    'ChFMaXN0QXJlYXNSZXNwb25zZRIvCgVhcmVhcxgBIAMoCzIZLmR6ZXJvdGgubG9jYXRpb24udj'
    'EuQXJlYVIFYXJlYXMSJgoPbmV4dF9wYWdlX3Rva2VuGAIgASgJUg1uZXh0UGFnZVRva2VuEhgK'
    'B3ZlcnNpb24YAyABKANSB3ZlcnNpb24SIQoMbm90X21vZGlmaWVkGAQgASgIUgtub3RNb2RpZm'
    'llZA==');

const $core.Map<$core.String, $core.dynamic> LocationServiceBase$json = {
  '1': 'LocationService',
  '2': [
    {
      '1': 'GetLocationSettings',
      '2': '.dzeroth.location.v1.GetLocationSettingsRequest',
      '3': '.dzeroth.location.v1.GetLocationSettingsResponse',
      '4': {'34': 1},
    },
    {
      '1': 'SetArea',
      '2': '.dzeroth.location.v1.SetAreaRequest',
      '3': '.dzeroth.location.v1.SetAreaResponse'
    },
    {
      '1': 'ClearArea',
      '2': '.dzeroth.location.v1.ClearAreaRequest',
      '3': '.dzeroth.location.v1.ClearAreaResponse'
    },
    {
      '1': 'ListAreas',
      '2': '.dzeroth.location.v1.ListAreasRequest',
      '3': '.dzeroth.location.v1.ListAreasResponse',
      '4': {'34': 1},
    },
  ],
};

@$core.Deprecated('Use locationServiceDescriptor instead')
const $core.Map<$core.String, $core.Map<$core.String, $core.dynamic>>
    LocationServiceBase$messageJson = {
  '.dzeroth.location.v1.GetLocationSettingsRequest':
      GetLocationSettingsRequest$json,
  '.dzeroth.location.v1.GetLocationSettingsResponse':
      GetLocationSettingsResponse$json,
  '.dzeroth.location.v1.LocationSettings': LocationSettings$json,
  '.dzeroth.location.v1.AreaSummary': AreaSummary$json,
  '.dzeroth.location.v1.ConsentState': ConsentState$json,
  '.google.protobuf.Timestamp': $0.Timestamp$json,
  '.dzeroth.location.v1.SetAreaRequest': SetAreaRequest$json,
  '.dzeroth.location.v1.ConsentGrant': ConsentGrant$json,
  '.dzeroth.location.v1.SetAreaResponse': SetAreaResponse$json,
  '.dzeroth.location.v1.ClearAreaRequest': ClearAreaRequest$json,
  '.dzeroth.location.v1.ClearAreaResponse': ClearAreaResponse$json,
  '.dzeroth.location.v1.ListAreasRequest': ListAreasRequest$json,
  '.dzeroth.location.v1.ListAreasResponse': ListAreasResponse$json,
  '.dzeroth.location.v1.Area': Area$json,
};

/// Descriptor for `LocationService`. Decode as a `google.protobuf.ServiceDescriptorProto`.
final $typed_data.Uint8List locationServiceDescriptor = $convert.base64Decode(
    'Cg9Mb2NhdGlvblNlcnZpY2USfQoTR2V0TG9jYXRpb25TZXR0aW5ncxIvLmR6ZXJvdGgubG9jYX'
    'Rpb24udjEuR2V0TG9jYXRpb25TZXR0aW5nc1JlcXVlc3QaMC5kemVyb3RoLmxvY2F0aW9uLnYx'
    'LkdldExvY2F0aW9uU2V0dGluZ3NSZXNwb25zZSIDkAIBElQKB1NldEFyZWESIy5kemVyb3RoLm'
    'xvY2F0aW9uLnYxLlNldEFyZWFSZXF1ZXN0GiQuZHplcm90aC5sb2NhdGlvbi52MS5TZXRBcmVh'
    'UmVzcG9uc2USWgoJQ2xlYXJBcmVhEiUuZHplcm90aC5sb2NhdGlvbi52MS5DbGVhckFyZWFSZX'
    'F1ZXN0GiYuZHplcm90aC5sb2NhdGlvbi52MS5DbGVhckFyZWFSZXNwb25zZRJfCglMaXN0QXJl'
    'YXMSJS5kemVyb3RoLmxvY2F0aW9uLnYxLkxpc3RBcmVhc1JlcXVlc3QaJi5kemVyb3RoLmxvY2'
    'F0aW9uLnYxLkxpc3RBcmVhc1Jlc3BvbnNlIgOQAgE=');
