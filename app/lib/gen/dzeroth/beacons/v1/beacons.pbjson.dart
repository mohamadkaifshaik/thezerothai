// This is a generated file - do not edit.
//
// Generated from dzeroth/beacons/v1/beacons.proto.

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

@$core.Deprecated('Use beaconActivityDescriptor instead')
const BeaconActivity$json = {
  '1': 'BeaconActivity',
  '2': [
    {'1': 'BEACON_ACTIVITY_UNSPECIFIED', '2': 0},
    {'1': 'BEACON_ACTIVITY_COFFEE', '2': 1},
    {'1': 'BEACON_ACTIVITY_MEAL', '2': 2},
    {'1': 'BEACON_ACTIVITY_STUDY', '2': 3},
    {'1': 'BEACON_ACTIVITY_SPORTS', '2': 4},
    {'1': 'BEACON_ACTIVITY_WALK', '2': 5},
    {'1': 'BEACON_ACTIVITY_SHOPPING', '2': 6},
    {'1': 'BEACON_ACTIVITY_OTHER', '2': 7},
  ],
};

/// Descriptor for `BeaconActivity`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List beaconActivityDescriptor = $convert.base64Decode(
    'Cg5CZWFjb25BY3Rpdml0eRIfChtCRUFDT05fQUNUSVZJVFlfVU5TUEVDSUZJRUQQABIaChZCRU'
    'FDT05fQUNUSVZJVFlfQ09GRkVFEAESGAoUQkVBQ09OX0FDVElWSVRZX01FQUwQAhIZChVCRUFD'
    'T05fQUNUSVZJVFlfU1RVRFkQAxIaChZCRUFDT05fQUNUSVZJVFlfU1BPUlRTEAQSGAoUQkVBQ0'
    '9OX0FDVElWSVRZX1dBTEsQBRIcChhCRUFDT05fQUNUSVZJVFlfU0hPUFBJTkcQBhIZChVCRUFD'
    'T05fQUNUSVZJVFlfT1RIRVIQBw==');

@$core.Deprecated('Use beaconStatusDescriptor instead')
const BeaconStatus$json = {
  '1': 'BeaconStatus',
  '2': [
    {'1': 'BEACON_STATUS_UNSPECIFIED', '2': 0},
    {'1': 'BEACON_STATUS_OPEN', '2': 1},
    {'1': 'BEACON_STATUS_FULL', '2': 2},
    {'1': 'BEACON_STATUS_CANCELLED', '2': 3},
    {'1': 'BEACON_STATUS_ENDED', '2': 4},
  ],
};

/// Descriptor for `BeaconStatus`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List beaconStatusDescriptor = $convert.base64Decode(
    'CgxCZWFjb25TdGF0dXMSHQoZQkVBQ09OX1NUQVRVU19VTlNQRUNJRklFRBAAEhYKEkJFQUNPTl'
    '9TVEFUVVNfT1BFThABEhYKEkJFQUNPTl9TVEFUVVNfRlVMTBACEhsKF0JFQUNPTl9TVEFUVVNf'
    'Q0FOQ0VMTEVEEAMSFwoTQkVBQ09OX1NUQVRVU19FTkRFRBAE');

@$core.Deprecated('Use beaconCostDescriptor instead')
const BeaconCost$json = {
  '1': 'BeaconCost',
  '2': [
    {'1': 'BEACON_COST_UNSPECIFIED', '2': 0},
    {'1': 'BEACON_COST_FREE', '2': 1},
    {'1': 'BEACON_COST_EVERYONE_PAYS_OWN', '2': 2},
    {'1': 'BEACON_COST_SPLIT_EVENLY', '2': 3},
  ],
};

/// Descriptor for `BeaconCost`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List beaconCostDescriptor = $convert.base64Decode(
    'CgpCZWFjb25Db3N0EhsKF0JFQUNPTl9DT1NUX1VOU1BFQ0lGSUVEEAASFAoQQkVBQ09OX0NPU1'
    'RfRlJFRRABEiEKHUJFQUNPTl9DT1NUX0VWRVJZT05FX1BBWVNfT1dOEAISHAoYQkVBQ09OX0NP'
    'U1RfU1BMSVRfRVZFTkxZEAM=');

@$core.Deprecated('Use chatPreferenceDescriptor instead')
const ChatPreference$json = {
  '1': 'ChatPreference',
  '2': [
    {'1': 'CHAT_PREFERENCE_UNSPECIFIED', '2': 0},
    {'1': 'CHAT_PREFERENCE_QUIET', '2': 1},
    {'1': 'CHAT_PREFERENCE_TASK_FOCUSED', '2': 2},
    {'1': 'CHAT_PREFERENCE_OPEN_TO_CHAT', '2': 3},
  ],
};

/// Descriptor for `ChatPreference`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List chatPreferenceDescriptor = $convert.base64Decode(
    'Cg5DaGF0UHJlZmVyZW5jZRIfChtDSEFUX1BSRUZFUkVOQ0VfVU5TUEVDSUZJRUQQABIZChVDSE'
    'FUX1BSRUZFUkVOQ0VfUVVJRVQQARIgChxDSEFUX1BSRUZFUkVOQ0VfVEFTS19GT0NVU0VEEAIS'
    'IAocQ0hBVF9QUkVGRVJFTkNFX09QRU5fVE9fQ0hBVBAD');

@$core.Deprecated('Use beaconEligibilityDescriptor instead')
const BeaconEligibility$json = {
  '1': 'BeaconEligibility',
  '2': [
    {'1': 'BEACON_ELIGIBILITY_UNSPECIFIED', '2': 0},
    {'1': 'BEACON_ELIGIBILITY_EVERYONE', '2': 1},
  ],
};

/// Descriptor for `BeaconEligibility`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List beaconEligibilityDescriptor = $convert.base64Decode(
    'ChFCZWFjb25FbGlnaWJpbGl0eRIiCh5CRUFDT05fRUxJR0lCSUxJVFlfVU5TUEVDSUZJRUQQAB'
    'IfChtCRUFDT05fRUxJR0lCSUxJVFlfRVZFUllPTkUQAQ==');

@$core.Deprecated('Use participantStateDescriptor instead')
const ParticipantState$json = {
  '1': 'ParticipantState',
  '2': [
    {'1': 'PARTICIPANT_STATE_UNSPECIFIED', '2': 0},
    {'1': 'PARTICIPANT_STATE_REQUESTED', '2': 1},
    {'1': 'PARTICIPANT_STATE_ACCEPTED', '2': 2},
    {'1': 'PARTICIPANT_STATE_DECLINED', '2': 3},
    {'1': 'PARTICIPANT_STATE_WITHDRAWN', '2': 4},
    {'1': 'PARTICIPANT_STATE_LEFT', '2': 5},
    {'1': 'PARTICIPANT_STATE_REMOVED', '2': 6},
  ],
};

/// Descriptor for `ParticipantState`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List participantStateDescriptor = $convert.base64Decode(
    'ChBQYXJ0aWNpcGFudFN0YXRlEiEKHVBBUlRJQ0lQQU5UX1NUQVRFX1VOU1BFQ0lGSUVEEAASHw'
    'obUEFSVElDSVBBTlRfU1RBVEVfUkVRVUVTVEVEEAESHgoaUEFSVElDSVBBTlRfU1RBVEVfQUND'
    'RVBURUQQAhIeChpQQVJUSUNJUEFOVF9TVEFURV9ERUNMSU5FRBADEh8KG1BBUlRJQ0lQQU5UX1'
    'NUQVRFX1dJVEhEUkFXThAEEhoKFlBBUlRJQ0lQQU5UX1NUQVRFX0xFRlQQBRIdChlQQVJUSUNJ'
    'UEFOVF9TVEFURV9SRU1PVkVEEAY=');

@$core.Deprecated('Use viewerRoleDescriptor instead')
const ViewerRole$json = {
  '1': 'ViewerRole',
  '2': [
    {'1': 'VIEWER_ROLE_UNSPECIFIED', '2': 0},
    {'1': 'VIEWER_ROLE_NONE', '2': 1},
    {'1': 'VIEWER_ROLE_ORGANISER', '2': 2},
    {'1': 'VIEWER_ROLE_PARTICIPANT', '2': 3},
  ],
};

/// Descriptor for `ViewerRole`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List viewerRoleDescriptor = $convert.base64Decode(
    'CgpWaWV3ZXJSb2xlEhsKF1ZJRVdFUl9ST0xFX1VOU1BFQ0lGSUVEEAASFAoQVklFV0VSX1JPTE'
    'VfTk9ORRABEhkKFVZJRVdFUl9ST0xFX09SR0FOSVNFUhACEhsKF1ZJRVdFUl9ST0xFX1BBUlRJ'
    'Q0lQQU5UEAM=');

@$core.Deprecated('Use joinResponseDescriptor instead')
const JoinResponse$json = {
  '1': 'JoinResponse',
  '2': [
    {'1': 'JOIN_RESPONSE_UNSPECIFIED', '2': 0},
    {'1': 'JOIN_RESPONSE_ACCEPT', '2': 1},
    {'1': 'JOIN_RESPONSE_DECLINE', '2': 2},
  ],
};

/// Descriptor for `JoinResponse`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List joinResponseDescriptor = $convert.base64Decode(
    'CgxKb2luUmVzcG9uc2USHQoZSk9JTl9SRVNQT05TRV9VTlNQRUNJRklFRBAAEhgKFEpPSU5fUk'
    'VTUE9OU0VfQUNDRVBUEAESGQoVSk9JTl9SRVNQT05TRV9ERUNMSU5FEAI=');

@$core.Deprecated('Use myBeaconsRoleDescriptor instead')
const MyBeaconsRole$json = {
  '1': 'MyBeaconsRole',
  '2': [
    {'1': 'MY_BEACONS_ROLE_UNSPECIFIED', '2': 0},
    {'1': 'MY_BEACONS_ROLE_ALL', '2': 1},
    {'1': 'MY_BEACONS_ROLE_ORGANISER', '2': 2},
    {'1': 'MY_BEACONS_ROLE_PARTICIPANT', '2': 3},
  ],
};

/// Descriptor for `MyBeaconsRole`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List myBeaconsRoleDescriptor = $convert.base64Decode(
    'Cg1NeUJlYWNvbnNSb2xlEh8KG01ZX0JFQUNPTlNfUk9MRV9VTlNQRUNJRklFRBAAEhcKE01ZX0'
    'JFQUNPTlNfUk9MRV9BTEwQARIdChlNWV9CRUFDT05TX1JPTEVfT1JHQU5JU0VSEAISHwobTVlf'
    'QkVBQ09OU19ST0xFX1BBUlRJQ0lQQU5UEAM=');

@$core.Deprecated('Use myBeaconsWindowDescriptor instead')
const MyBeaconsWindow$json = {
  '1': 'MyBeaconsWindow',
  '2': [
    {'1': 'MY_BEACONS_WINDOW_UNSPECIFIED', '2': 0},
    {'1': 'MY_BEACONS_WINDOW_UPCOMING', '2': 1},
    {'1': 'MY_BEACONS_WINDOW_PAST', '2': 2},
  ],
};

/// Descriptor for `MyBeaconsWindow`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List myBeaconsWindowDescriptor = $convert.base64Decode(
    'Cg9NeUJlYWNvbnNXaW5kb3cSIQodTVlfQkVBQ09OU19XSU5ET1dfVU5TUEVDSUZJRUQQABIeCh'
    'pNWV9CRUFDT05TX1dJTkRPV19VUENPTUlORxABEhoKFk1ZX0JFQUNPTlNfV0lORE9XX1BBU1QQ'
    'Ag==');

@$core.Deprecated('Use participantFilterDescriptor instead')
const ParticipantFilter$json = {
  '1': 'ParticipantFilter',
  '2': [
    {'1': 'PARTICIPANT_FILTER_UNSPECIFIED', '2': 0},
    {'1': 'PARTICIPANT_FILTER_ACCEPTED', '2': 1},
    {'1': 'PARTICIPANT_FILTER_REQUESTED', '2': 2},
  ],
};

/// Descriptor for `ParticipantFilter`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List participantFilterDescriptor = $convert.base64Decode(
    'ChFQYXJ0aWNpcGFudEZpbHRlchIiCh5QQVJUSUNJUEFOVF9GSUxURVJfVU5TUEVDSUZJRUQQAB'
    'IfChtQQVJUSUNJUEFOVF9GSUxURVJfQUNDRVBURUQQARIgChxQQVJUSUNJUEFOVF9GSUxURVJf'
    'UkVRVUVTVEVEEAI=');

@$core.Deprecated('Use beaconDescriptor instead')
const Beacon$json = {
  '1': 'Beacon',
  '2': [
    {'1': 'beacon_id', '3': 1, '4': 1, '5': 9, '10': 'beaconId'},
    {
      '1': 'organiser',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.common.v1.AuthorSnapshot',
      '10': 'organiser'
    },
    {'1': 'community_id', '3': 3, '4': 1, '5': 9, '10': 'communityId'},
    {
      '1': 'activity',
      '3': 4,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.beacons.v1.BeaconActivity',
      '10': 'activity'
    },
    {'1': 'title', '3': 5, '4': 1, '5': 9, '10': 'title'},
    {'1': 'details', '3': 6, '4': 1, '5': 9, '10': 'details'},
    {'1': 'venue', '3': 7, '4': 1, '5': 9, '10': 'venue'},
    {
      '1': 'start_at',
      '3': 8,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '10': 'startAt'
    },
    {'1': 'duration_minutes', '3': 9, '4': 1, '5': 5, '10': 'durationMinutes'},
    {'1': 'open_spots', '3': 10, '4': 1, '5': 5, '10': 'openSpots'},
    {'1': 'accepted_count', '3': 11, '4': 1, '5': 5, '10': 'acceptedCount'},
    {
      '1': 'cost',
      '3': 12,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.beacons.v1.BeaconCost',
      '10': 'cost'
    },
    {
      '1': 'chat_preference',
      '3': 13,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.beacons.v1.ChatPreference',
      '10': 'chatPreference'
    },
    {
      '1': 'eligibility',
      '3': 14,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.beacons.v1.BeaconEligibility',
      '10': 'eligibility'
    },
    {
      '1': 'status',
      '3': 15,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.beacons.v1.BeaconStatus',
      '10': 'status'
    },
    {'1': 'hidden', '3': 16, '4': 1, '5': 8, '10': 'hidden'},
    {
      '1': 'created_at',
      '3': 17,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '10': 'createdAt'
    },
    {
      '1': 'updated_at',
      '3': 18,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '10': 'updatedAt'
    },
  ],
};

/// Descriptor for `Beacon`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List beaconDescriptor = $convert.base64Decode(
    'CgZCZWFjb24SGwoJYmVhY29uX2lkGAEgASgJUghiZWFjb25JZBI/CglvcmdhbmlzZXIYAiABKA'
    'syIS5kemVyb3RoLmNvbW1vbi52MS5BdXRob3JTbmFwc2hvdFIJb3JnYW5pc2VyEiEKDGNvbW11'
    'bml0eV9pZBgDIAEoCVILY29tbXVuaXR5SWQSPgoIYWN0aXZpdHkYBCABKA4yIi5kemVyb3RoLm'
    'JlYWNvbnMudjEuQmVhY29uQWN0aXZpdHlSCGFjdGl2aXR5EhQKBXRpdGxlGAUgASgJUgV0aXRs'
    'ZRIYCgdkZXRhaWxzGAYgASgJUgdkZXRhaWxzEhQKBXZlbnVlGAcgASgJUgV2ZW51ZRI1CghzdG'
    'FydF9hdBgIIAEoCzIaLmdvb2dsZS5wcm90b2J1Zi5UaW1lc3RhbXBSB3N0YXJ0QXQSKQoQZHVy'
    'YXRpb25fbWludXRlcxgJIAEoBVIPZHVyYXRpb25NaW51dGVzEh0KCm9wZW5fc3BvdHMYCiABKA'
    'VSCW9wZW5TcG90cxIlCg5hY2NlcHRlZF9jb3VudBgLIAEoBVINYWNjZXB0ZWRDb3VudBIyCgRj'
    'b3N0GAwgASgOMh4uZHplcm90aC5iZWFjb25zLnYxLkJlYWNvbkNvc3RSBGNvc3QSSwoPY2hhdF'
    '9wcmVmZXJlbmNlGA0gASgOMiIuZHplcm90aC5iZWFjb25zLnYxLkNoYXRQcmVmZXJlbmNlUg5j'
    'aGF0UHJlZmVyZW5jZRJHCgtlbGlnaWJpbGl0eRgOIAEoDjIlLmR6ZXJvdGguYmVhY29ucy52MS'
    '5CZWFjb25FbGlnaWJpbGl0eVILZWxpZ2liaWxpdHkSOAoGc3RhdHVzGA8gASgOMiAuZHplcm90'
    'aC5iZWFjb25zLnYxLkJlYWNvblN0YXR1c1IGc3RhdHVzEhYKBmhpZGRlbhgQIAEoCFIGaGlkZG'
    'VuEjkKCmNyZWF0ZWRfYXQYESABKAsyGi5nb29nbGUucHJvdG9idWYuVGltZXN0YW1wUgljcmVh'
    'dGVkQXQSOQoKdXBkYXRlZF9hdBgSIAEoCzIaLmdvb2dsZS5wcm90b2J1Zi5UaW1lc3RhbXBSCX'
    'VwZGF0ZWRBdA==');

@$core.Deprecated('Use viewerStateDescriptor instead')
const ViewerState$json = {
  '1': 'ViewerState',
  '2': [
    {
      '1': 'role',
      '3': 1,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.beacons.v1.ViewerRole',
      '10': 'role'
    },
    {
      '1': 'participant_state',
      '3': 2,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.beacons.v1.ParticipantState',
      '10': 'participantState'
    },
    {'1': 'can_request', '3': 3, '4': 1, '5': 8, '10': 'canRequest'},
    {'1': 'can_withdraw', '3': 4, '4': 1, '5': 8, '10': 'canWithdraw'},
    {'1': 'can_leave', '3': 5, '4': 1, '5': 8, '10': 'canLeave'},
    {'1': 'can_manage', '3': 6, '4': 1, '5': 8, '10': 'canManage'},
    {
      '1': 'quick_join_allowed',
      '3': 7,
      '4': 1,
      '5': 8,
      '10': 'quickJoinAllowed'
    },
  ],
};

/// Descriptor for `ViewerState`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List viewerStateDescriptor = $convert.base64Decode(
    'CgtWaWV3ZXJTdGF0ZRIyCgRyb2xlGAEgASgOMh4uZHplcm90aC5iZWFjb25zLnYxLlZpZXdlcl'
    'JvbGVSBHJvbGUSUQoRcGFydGljaXBhbnRfc3RhdGUYAiABKA4yJC5kemVyb3RoLmJlYWNvbnMu'
    'djEuUGFydGljaXBhbnRTdGF0ZVIQcGFydGljaXBhbnRTdGF0ZRIfCgtjYW5fcmVxdWVzdBgDIA'
    'EoCFIKY2FuUmVxdWVzdBIhCgxjYW5fd2l0aGRyYXcYBCABKAhSC2NhbldpdGhkcmF3EhsKCWNh'
    'bl9sZWF2ZRgFIAEoCFIIY2FuTGVhdmUSHQoKY2FuX21hbmFnZRgGIAEoCFIJY2FuTWFuYWdlEi'
    'wKEnF1aWNrX2pvaW5fYWxsb3dlZBgHIAEoCFIQcXVpY2tKb2luQWxsb3dlZA==');

@$core.Deprecated('Use beaconViewDescriptor instead')
const BeaconView$json = {
  '1': 'BeaconView',
  '2': [
    {
      '1': 'beacon',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.beacons.v1.Beacon',
      '10': 'beacon'
    },
    {
      '1': 'viewer',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.beacons.v1.ViewerState',
      '10': 'viewer'
    },
  ],
};

/// Descriptor for `BeaconView`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List beaconViewDescriptor = $convert.base64Decode(
    'CgpCZWFjb25WaWV3EjIKBmJlYWNvbhgBIAEoCzIaLmR6ZXJvdGguYmVhY29ucy52MS5CZWFjb2'
    '5SBmJlYWNvbhI3CgZ2aWV3ZXIYAiABKAsyHy5kemVyb3RoLmJlYWNvbnMudjEuVmlld2VyU3Rh'
    'dGVSBnZpZXdlcg==');

@$core.Deprecated('Use participantDescriptor instead')
const Participant$json = {
  '1': 'Participant',
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
      '1': 'state',
      '3': 2,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.beacons.v1.ParticipantState',
      '10': 'state'
    },
    {'1': 'note', '3': 3, '4': 1, '5': 9, '10': 'note'},
    {
      '1': 'since',
      '3': 4,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '10': 'since'
    },
  ],
};

/// Descriptor for `Participant`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List participantDescriptor = $convert.base64Decode(
    'CgtQYXJ0aWNpcGFudBI1CgR1c2VyGAEgASgLMiEuZHplcm90aC5jb21tb24udjEuQXV0aG9yU2'
    '5hcHNob3RSBHVzZXISOgoFc3RhdGUYAiABKA4yJC5kemVyb3RoLmJlYWNvbnMudjEuUGFydGlj'
    'aXBhbnRTdGF0ZVIFc3RhdGUSEgoEbm90ZRgDIAEoCVIEbm90ZRIwCgVzaW5jZRgEIAEoCzIaLm'
    'dvb2dsZS5wcm90b2J1Zi5UaW1lc3RhbXBSBXNpbmNl');

@$core.Deprecated('Use createBeaconRequestDescriptor instead')
const CreateBeaconRequest$json = {
  '1': 'CreateBeaconRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'community_id', '3': 2, '4': 1, '5': 9, '9': 0, '10': 'communityId'},
    {'1': 'public', '3': 3, '4': 1, '5': 8, '9': 0, '10': 'public'},
    {
      '1': 'activity',
      '3': 4,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.beacons.v1.BeaconActivity',
      '10': 'activity'
    },
    {'1': 'title', '3': 5, '4': 1, '5': 9, '10': 'title'},
    {'1': 'details', '3': 6, '4': 1, '5': 9, '10': 'details'},
    {'1': 'venue', '3': 7, '4': 1, '5': 9, '10': 'venue'},
    {
      '1': 'start_at',
      '3': 8,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '10': 'startAt'
    },
    {'1': 'duration_minutes', '3': 9, '4': 1, '5': 5, '10': 'durationMinutes'},
    {'1': 'open_spots', '3': 10, '4': 1, '5': 5, '10': 'openSpots'},
    {
      '1': 'cost',
      '3': 11,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.beacons.v1.BeaconCost',
      '10': 'cost'
    },
    {
      '1': 'chat_preference',
      '3': 12,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.beacons.v1.ChatPreference',
      '10': 'chatPreference'
    },
  ],
  '8': [
    {'1': 'audience'},
  ],
};

/// Descriptor for `CreateBeaconRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List createBeaconRequestDescriptor = $convert.base64Decode(
    'ChNDcmVhdGVCZWFjb25SZXF1ZXN0EicKD2lkZW1wb3RlbmN5X2tleRgBIAEoCVIOaWRlbXBvdG'
    'VuY3lLZXkSIwoMY29tbXVuaXR5X2lkGAIgASgJSABSC2NvbW11bml0eUlkEhgKBnB1YmxpYxgD'
    'IAEoCEgAUgZwdWJsaWMSPgoIYWN0aXZpdHkYBCABKA4yIi5kemVyb3RoLmJlYWNvbnMudjEuQm'
    'VhY29uQWN0aXZpdHlSCGFjdGl2aXR5EhQKBXRpdGxlGAUgASgJUgV0aXRsZRIYCgdkZXRhaWxz'
    'GAYgASgJUgdkZXRhaWxzEhQKBXZlbnVlGAcgASgJUgV2ZW51ZRI1CghzdGFydF9hdBgIIAEoCz'
    'IaLmdvb2dsZS5wcm90b2J1Zi5UaW1lc3RhbXBSB3N0YXJ0QXQSKQoQZHVyYXRpb25fbWludXRl'
    'cxgJIAEoBVIPZHVyYXRpb25NaW51dGVzEh0KCm9wZW5fc3BvdHMYCiABKAVSCW9wZW5TcG90cx'
    'IyCgRjb3N0GAsgASgOMh4uZHplcm90aC5iZWFjb25zLnYxLkJlYWNvbkNvc3RSBGNvc3QSSwoP'
    'Y2hhdF9wcmVmZXJlbmNlGAwgASgOMiIuZHplcm90aC5iZWFjb25zLnYxLkNoYXRQcmVmZXJlbm'
    'NlUg5jaGF0UHJlZmVyZW5jZUIKCghhdWRpZW5jZQ==');

@$core.Deprecated('Use createBeaconResponseDescriptor instead')
const CreateBeaconResponse$json = {
  '1': 'CreateBeaconResponse',
  '2': [
    {
      '1': 'view',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.beacons.v1.BeaconView',
      '10': 'view'
    },
  ],
};

/// Descriptor for `CreateBeaconResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List createBeaconResponseDescriptor = $convert.base64Decode(
    'ChRDcmVhdGVCZWFjb25SZXNwb25zZRIyCgR2aWV3GAEgASgLMh4uZHplcm90aC5iZWFjb25zLn'
    'YxLkJlYWNvblZpZXdSBHZpZXc=');

@$core.Deprecated('Use updateBeaconRequestDescriptor instead')
const UpdateBeaconRequest$json = {
  '1': 'UpdateBeaconRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'beacon_id', '3': 2, '4': 1, '5': 9, '10': 'beaconId'},
    {'1': 'title', '3': 3, '4': 1, '5': 9, '9': 0, '10': 'title', '17': true},
    {
      '1': 'details',
      '3': 4,
      '4': 1,
      '5': 9,
      '9': 1,
      '10': 'details',
      '17': true
    },
    {'1': 'venue', '3': 5, '4': 1, '5': 9, '9': 2, '10': 'venue', '17': true},
    {
      '1': 'open_spots',
      '3': 6,
      '4': 1,
      '5': 5,
      '9': 3,
      '10': 'openSpots',
      '17': true
    },
    {
      '1': 'start_at',
      '3': 7,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '10': 'startAt'
    },
    {
      '1': 'duration_minutes',
      '3': 8,
      '4': 1,
      '5': 5,
      '9': 4,
      '10': 'durationMinutes',
      '17': true
    },
    {
      '1': 'cost',
      '3': 9,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.beacons.v1.BeaconCost',
      '9': 5,
      '10': 'cost',
      '17': true
    },
  ],
  '8': [
    {'1': '_title'},
    {'1': '_details'},
    {'1': '_venue'},
    {'1': '_open_spots'},
    {'1': '_duration_minutes'},
    {'1': '_cost'},
  ],
};

/// Descriptor for `UpdateBeaconRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List updateBeaconRequestDescriptor = $convert.base64Decode(
    'ChNVcGRhdGVCZWFjb25SZXF1ZXN0EicKD2lkZW1wb3RlbmN5X2tleRgBIAEoCVIOaWRlbXBvdG'
    'VuY3lLZXkSGwoJYmVhY29uX2lkGAIgASgJUghiZWFjb25JZBIZCgV0aXRsZRgDIAEoCUgAUgV0'
    'aXRsZYgBARIdCgdkZXRhaWxzGAQgASgJSAFSB2RldGFpbHOIAQESGQoFdmVudWUYBSABKAlIAl'
    'IFdmVudWWIAQESIgoKb3Blbl9zcG90cxgGIAEoBUgDUglvcGVuU3BvdHOIAQESNQoIc3RhcnRf'
    'YXQYByABKAsyGi5nb29nbGUucHJvdG9idWYuVGltZXN0YW1wUgdzdGFydEF0Ei4KEGR1cmF0aW'
    '9uX21pbnV0ZXMYCCABKAVIBFIPZHVyYXRpb25NaW51dGVziAEBEjcKBGNvc3QYCSABKA4yHi5k'
    'emVyb3RoLmJlYWNvbnMudjEuQmVhY29uQ29zdEgFUgRjb3N0iAEBQggKBl90aXRsZUIKCghfZG'
    'V0YWlsc0IICgZfdmVudWVCDQoLX29wZW5fc3BvdHNCEwoRX2R1cmF0aW9uX21pbnV0ZXNCBwoF'
    'X2Nvc3Q=');

@$core.Deprecated('Use updateBeaconResponseDescriptor instead')
const UpdateBeaconResponse$json = {
  '1': 'UpdateBeaconResponse',
  '2': [
    {
      '1': 'view',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.beacons.v1.BeaconView',
      '10': 'view'
    },
  ],
};

/// Descriptor for `UpdateBeaconResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List updateBeaconResponseDescriptor = $convert.base64Decode(
    'ChRVcGRhdGVCZWFjb25SZXNwb25zZRIyCgR2aWV3GAEgASgLMh4uZHplcm90aC5iZWFjb25zLn'
    'YxLkJlYWNvblZpZXdSBHZpZXc=');

@$core.Deprecated('Use cancelBeaconRequestDescriptor instead')
const CancelBeaconRequest$json = {
  '1': 'CancelBeaconRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'beacon_id', '3': 2, '4': 1, '5': 9, '10': 'beaconId'},
  ],
};

/// Descriptor for `CancelBeaconRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List cancelBeaconRequestDescriptor = $convert.base64Decode(
    'ChNDYW5jZWxCZWFjb25SZXF1ZXN0EicKD2lkZW1wb3RlbmN5X2tleRgBIAEoCVIOaWRlbXBvdG'
    'VuY3lLZXkSGwoJYmVhY29uX2lkGAIgASgJUghiZWFjb25JZA==');

@$core.Deprecated('Use cancelBeaconResponseDescriptor instead')
const CancelBeaconResponse$json = {
  '1': 'CancelBeaconResponse',
};

/// Descriptor for `CancelBeaconResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List cancelBeaconResponseDescriptor =
    $convert.base64Decode('ChRDYW5jZWxCZWFjb25SZXNwb25zZQ==');

@$core.Deprecated('Use getBeaconRequestDescriptor instead')
const GetBeaconRequest$json = {
  '1': 'GetBeaconRequest',
  '2': [
    {'1': 'beacon_id', '3': 1, '4': 1, '5': 9, '10': 'beaconId'},
  ],
};

/// Descriptor for `GetBeaconRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getBeaconRequestDescriptor = $convert.base64Decode(
    'ChBHZXRCZWFjb25SZXF1ZXN0EhsKCWJlYWNvbl9pZBgBIAEoCVIIYmVhY29uSWQ=');

@$core.Deprecated('Use getBeaconResponseDescriptor instead')
const GetBeaconResponse$json = {
  '1': 'GetBeaconResponse',
  '2': [
    {
      '1': 'view',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.beacons.v1.BeaconView',
      '10': 'view'
    },
  ],
};

/// Descriptor for `GetBeaconResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List getBeaconResponseDescriptor = $convert.base64Decode(
    'ChFHZXRCZWFjb25SZXNwb25zZRIyCgR2aWV3GAEgASgLMh4uZHplcm90aC5iZWFjb25zLnYxLk'
    'JlYWNvblZpZXdSBHZpZXc=');

@$core.Deprecated('Use listBeaconsRequestDescriptor instead')
const ListBeaconsRequest$json = {
  '1': 'ListBeaconsRequest',
  '2': [
    {'1': 'community_id', '3': 1, '4': 1, '5': 9, '9': 0, '10': 'communityId'},
    {'1': 'public', '3': 2, '4': 1, '5': 8, '9': 0, '10': 'public'},
    {
      '1': 'from',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Timestamp',
      '10': 'from'
    },
    {'1': 'limit', '3': 4, '4': 1, '5': 5, '10': 'limit'},
    {'1': 'page_token', '3': 5, '4': 1, '5': 9, '10': 'pageToken'},
    {
      '1': 'activity',
      '3': 6,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.beacons.v1.BeaconActivity',
      '10': 'activity'
    },
  ],
  '8': [
    {'1': 'audience'},
  ],
};

/// Descriptor for `ListBeaconsRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listBeaconsRequestDescriptor = $convert.base64Decode(
    'ChJMaXN0QmVhY29uc1JlcXVlc3QSIwoMY29tbXVuaXR5X2lkGAEgASgJSABSC2NvbW11bml0eU'
    'lkEhgKBnB1YmxpYxgCIAEoCEgAUgZwdWJsaWMSLgoEZnJvbRgDIAEoCzIaLmdvb2dsZS5wcm90'
    'b2J1Zi5UaW1lc3RhbXBSBGZyb20SFAoFbGltaXQYBCABKAVSBWxpbWl0Eh0KCnBhZ2VfdG9rZW'
    '4YBSABKAlSCXBhZ2VUb2tlbhI+CghhY3Rpdml0eRgGIAEoDjIiLmR6ZXJvdGguYmVhY29ucy52'
    'MS5CZWFjb25BY3Rpdml0eVIIYWN0aXZpdHlCCgoIYXVkaWVuY2U=');

@$core.Deprecated('Use listBeaconsResponseDescriptor instead')
const ListBeaconsResponse$json = {
  '1': 'ListBeaconsResponse',
  '2': [
    {
      '1': 'views',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.beacons.v1.BeaconView',
      '10': 'views'
    },
    {'1': 'next_page_token', '3': 2, '4': 1, '5': 9, '10': 'nextPageToken'},
  ],
};

/// Descriptor for `ListBeaconsResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listBeaconsResponseDescriptor = $convert.base64Decode(
    'ChNMaXN0QmVhY29uc1Jlc3BvbnNlEjQKBXZpZXdzGAEgAygLMh4uZHplcm90aC5iZWFjb25zLn'
    'YxLkJlYWNvblZpZXdSBXZpZXdzEiYKD25leHRfcGFnZV90b2tlbhgCIAEoCVINbmV4dFBhZ2VU'
    'b2tlbg==');

@$core.Deprecated('Use listMyBeaconsRequestDescriptor instead')
const ListMyBeaconsRequest$json = {
  '1': 'ListMyBeaconsRequest',
  '2': [
    {
      '1': 'role',
      '3': 1,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.beacons.v1.MyBeaconsRole',
      '10': 'role'
    },
    {
      '1': 'window',
      '3': 2,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.beacons.v1.MyBeaconsWindow',
      '10': 'window'
    },
    {'1': 'limit', '3': 3, '4': 1, '5': 5, '10': 'limit'},
    {'1': 'page_token', '3': 4, '4': 1, '5': 9, '10': 'pageToken'},
  ],
};

/// Descriptor for `ListMyBeaconsRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listMyBeaconsRequestDescriptor = $convert.base64Decode(
    'ChRMaXN0TXlCZWFjb25zUmVxdWVzdBI1CgRyb2xlGAEgASgOMiEuZHplcm90aC5iZWFjb25zLn'
    'YxLk15QmVhY29uc1JvbGVSBHJvbGUSOwoGd2luZG93GAIgASgOMiMuZHplcm90aC5iZWFjb25z'
    'LnYxLk15QmVhY29uc1dpbmRvd1IGd2luZG93EhQKBWxpbWl0GAMgASgFUgVsaW1pdBIdCgpwYW'
    'dlX3Rva2VuGAQgASgJUglwYWdlVG9rZW4=');

@$core.Deprecated('Use listMyBeaconsResponseDescriptor instead')
const ListMyBeaconsResponse$json = {
  '1': 'ListMyBeaconsResponse',
  '2': [
    {
      '1': 'views',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.beacons.v1.BeaconView',
      '10': 'views'
    },
    {'1': 'next_page_token', '3': 2, '4': 1, '5': 9, '10': 'nextPageToken'},
  ],
};

/// Descriptor for `ListMyBeaconsResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listMyBeaconsResponseDescriptor = $convert.base64Decode(
    'ChVMaXN0TXlCZWFjb25zUmVzcG9uc2USNAoFdmlld3MYASADKAsyHi5kemVyb3RoLmJlYWNvbn'
    'MudjEuQmVhY29uVmlld1IFdmlld3MSJgoPbmV4dF9wYWdlX3Rva2VuGAIgASgJUg1uZXh0UGFn'
    'ZVRva2Vu');

@$core.Deprecated('Use requestToJoinRequestDescriptor instead')
const RequestToJoinRequest$json = {
  '1': 'RequestToJoinRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'beacon_id', '3': 2, '4': 1, '5': 9, '10': 'beaconId'},
    {'1': 'note', '3': 3, '4': 1, '5': 9, '10': 'note'},
  ],
};

/// Descriptor for `RequestToJoinRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List requestToJoinRequestDescriptor = $convert.base64Decode(
    'ChRSZXF1ZXN0VG9Kb2luUmVxdWVzdBInCg9pZGVtcG90ZW5jeV9rZXkYASABKAlSDmlkZW1wb3'
    'RlbmN5S2V5EhsKCWJlYWNvbl9pZBgCIAEoCVIIYmVhY29uSWQSEgoEbm90ZRgDIAEoCVIEbm90'
    'ZQ==');

@$core.Deprecated('Use requestToJoinResponseDescriptor instead')
const RequestToJoinResponse$json = {
  '1': 'RequestToJoinResponse',
  '2': [
    {
      '1': 'viewer',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.beacons.v1.ViewerState',
      '10': 'viewer'
    },
  ],
};

/// Descriptor for `RequestToJoinResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List requestToJoinResponseDescriptor = $convert.base64Decode(
    'ChVSZXF1ZXN0VG9Kb2luUmVzcG9uc2USNwoGdmlld2VyGAEgASgLMh8uZHplcm90aC5iZWFjb2'
    '5zLnYxLlZpZXdlclN0YXRlUgZ2aWV3ZXI=');

@$core.Deprecated('Use withdrawJoinRequestRequestDescriptor instead')
const WithdrawJoinRequestRequest$json = {
  '1': 'WithdrawJoinRequestRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'beacon_id', '3': 2, '4': 1, '5': 9, '10': 'beaconId'},
  ],
};

/// Descriptor for `WithdrawJoinRequestRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List withdrawJoinRequestRequestDescriptor =
    $convert.base64Decode(
        'ChpXaXRoZHJhd0pvaW5SZXF1ZXN0UmVxdWVzdBInCg9pZGVtcG90ZW5jeV9rZXkYASABKAlSDm'
        'lkZW1wb3RlbmN5S2V5EhsKCWJlYWNvbl9pZBgCIAEoCVIIYmVhY29uSWQ=');

@$core.Deprecated('Use withdrawJoinRequestResponseDescriptor instead')
const WithdrawJoinRequestResponse$json = {
  '1': 'WithdrawJoinRequestResponse',
};

/// Descriptor for `WithdrawJoinRequestResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List withdrawJoinRequestResponseDescriptor =
    $convert.base64Decode('ChtXaXRoZHJhd0pvaW5SZXF1ZXN0UmVzcG9uc2U=');

@$core.Deprecated('Use respondToJoinRequestRequestDescriptor instead')
const RespondToJoinRequestRequest$json = {
  '1': 'RespondToJoinRequestRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'beacon_id', '3': 2, '4': 1, '5': 9, '10': 'beaconId'},
    {'1': 'user_id', '3': 3, '4': 1, '5': 9, '10': 'userId'},
    {
      '1': 'response',
      '3': 4,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.beacons.v1.JoinResponse',
      '10': 'response'
    },
  ],
};

/// Descriptor for `RespondToJoinRequestRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List respondToJoinRequestRequestDescriptor = $convert.base64Decode(
    'ChtSZXNwb25kVG9Kb2luUmVxdWVzdFJlcXVlc3QSJwoPaWRlbXBvdGVuY3lfa2V5GAEgASgJUg'
    '5pZGVtcG90ZW5jeUtleRIbCgliZWFjb25faWQYAiABKAlSCGJlYWNvbklkEhcKB3VzZXJfaWQY'
    'AyABKAlSBnVzZXJJZBI8CghyZXNwb25zZRgEIAEoDjIgLmR6ZXJvdGguYmVhY29ucy52MS5Kb2'
    'luUmVzcG9uc2VSCHJlc3BvbnNl');

@$core.Deprecated('Use respondToJoinRequestResponseDescriptor instead')
const RespondToJoinRequestResponse$json = {
  '1': 'RespondToJoinRequestResponse',
  '2': [
    {
      '1': 'view',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.beacons.v1.BeaconView',
      '10': 'view'
    },
  ],
};

/// Descriptor for `RespondToJoinRequestResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List respondToJoinRequestResponseDescriptor =
    $convert.base64Decode(
        'ChxSZXNwb25kVG9Kb2luUmVxdWVzdFJlc3BvbnNlEjIKBHZpZXcYASABKAsyHi5kemVyb3RoLm'
        'JlYWNvbnMudjEuQmVhY29uVmlld1IEdmlldw==');

@$core.Deprecated('Use leaveBeaconRequestDescriptor instead')
const LeaveBeaconRequest$json = {
  '1': 'LeaveBeaconRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'beacon_id', '3': 2, '4': 1, '5': 9, '10': 'beaconId'},
  ],
};

/// Descriptor for `LeaveBeaconRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List leaveBeaconRequestDescriptor = $convert.base64Decode(
    'ChJMZWF2ZUJlYWNvblJlcXVlc3QSJwoPaWRlbXBvdGVuY3lfa2V5GAEgASgJUg5pZGVtcG90ZW'
    '5jeUtleRIbCgliZWFjb25faWQYAiABKAlSCGJlYWNvbklk');

@$core.Deprecated('Use leaveBeaconResponseDescriptor instead')
const LeaveBeaconResponse$json = {
  '1': 'LeaveBeaconResponse',
};

/// Descriptor for `LeaveBeaconResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List leaveBeaconResponseDescriptor =
    $convert.base64Decode('ChNMZWF2ZUJlYWNvblJlc3BvbnNl');

@$core.Deprecated('Use removeParticipantRequestDescriptor instead')
const RemoveParticipantRequest$json = {
  '1': 'RemoveParticipantRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {'1': 'beacon_id', '3': 2, '4': 1, '5': 9, '10': 'beaconId'},
    {'1': 'user_id', '3': 3, '4': 1, '5': 9, '10': 'userId'},
  ],
};

/// Descriptor for `RemoveParticipantRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List removeParticipantRequestDescriptor = $convert.base64Decode(
    'ChhSZW1vdmVQYXJ0aWNpcGFudFJlcXVlc3QSJwoPaWRlbXBvdGVuY3lfa2V5GAEgASgJUg5pZG'
    'VtcG90ZW5jeUtleRIbCgliZWFjb25faWQYAiABKAlSCGJlYWNvbklkEhcKB3VzZXJfaWQYAyAB'
    'KAlSBnVzZXJJZA==');

@$core.Deprecated('Use removeParticipantResponseDescriptor instead')
const RemoveParticipantResponse$json = {
  '1': 'RemoveParticipantResponse',
  '2': [
    {
      '1': 'view',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.dzeroth.beacons.v1.BeaconView',
      '10': 'view'
    },
  ],
};

/// Descriptor for `RemoveParticipantResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List removeParticipantResponseDescriptor =
    $convert.base64Decode(
        'ChlSZW1vdmVQYXJ0aWNpcGFudFJlc3BvbnNlEjIKBHZpZXcYASABKAsyHi5kemVyb3RoLmJlYW'
        'NvbnMudjEuQmVhY29uVmlld1IEdmlldw==');

@$core.Deprecated('Use listParticipantsRequestDescriptor instead')
const ListParticipantsRequest$json = {
  '1': 'ListParticipantsRequest',
  '2': [
    {'1': 'beacon_id', '3': 1, '4': 1, '5': 9, '10': 'beaconId'},
    {
      '1': 'filter',
      '3': 2,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.beacons.v1.ParticipantFilter',
      '10': 'filter'
    },
    {'1': 'limit', '3': 3, '4': 1, '5': 5, '10': 'limit'},
    {'1': 'page_token', '3': 4, '4': 1, '5': 9, '10': 'pageToken'},
  ],
};

/// Descriptor for `ListParticipantsRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listParticipantsRequestDescriptor = $convert.base64Decode(
    'ChdMaXN0UGFydGljaXBhbnRzUmVxdWVzdBIbCgliZWFjb25faWQYASABKAlSCGJlYWNvbklkEj'
    '0KBmZpbHRlchgCIAEoDjIlLmR6ZXJvdGguYmVhY29ucy52MS5QYXJ0aWNpcGFudEZpbHRlclIG'
    'ZmlsdGVyEhQKBWxpbWl0GAMgASgFUgVsaW1pdBIdCgpwYWdlX3Rva2VuGAQgASgJUglwYWdlVG'
    '9rZW4=');

@$core.Deprecated('Use listParticipantsResponseDescriptor instead')
const ListParticipantsResponse$json = {
  '1': 'ListParticipantsResponse',
  '2': [
    {
      '1': 'participants',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.beacons.v1.Participant',
      '10': 'participants'
    },
    {'1': 'next_page_token', '3': 2, '4': 1, '5': 9, '10': 'nextPageToken'},
  ],
};

/// Descriptor for `ListParticipantsResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listParticipantsResponseDescriptor = $convert.base64Decode(
    'ChhMaXN0UGFydGljaXBhbnRzUmVzcG9uc2USQwoMcGFydGljaXBhbnRzGAEgAygLMh8uZHplcm'
    '90aC5iZWFjb25zLnYxLlBhcnRpY2lwYW50UgxwYXJ0aWNpcGFudHMSJgoPbmV4dF9wYWdlX3Rv'
    'a2VuGAIgASgJUg1uZXh0UGFnZVRva2Vu');

@$core.Deprecated('Use listSharedBeaconsRequestDescriptor instead')
const ListSharedBeaconsRequest$json = {
  '1': 'ListSharedBeaconsRequest',
  '2': [
    {'1': 'peer_user_id', '3': 1, '4': 1, '5': 9, '10': 'peerUserId'},
    {'1': 'limit', '3': 2, '4': 1, '5': 5, '10': 'limit'},
    {'1': 'page_token', '3': 3, '4': 1, '5': 9, '10': 'pageToken'},
  ],
};

/// Descriptor for `ListSharedBeaconsRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listSharedBeaconsRequestDescriptor = $convert.base64Decode(
    'ChhMaXN0U2hhcmVkQmVhY29uc1JlcXVlc3QSIAoMcGVlcl91c2VyX2lkGAEgASgJUgpwZWVyVX'
    'NlcklkEhQKBWxpbWl0GAIgASgFUgVsaW1pdBIdCgpwYWdlX3Rva2VuGAMgASgJUglwYWdlVG9r'
    'ZW4=');

@$core.Deprecated('Use listSharedBeaconsResponseDescriptor instead')
const ListSharedBeaconsResponse$json = {
  '1': 'ListSharedBeaconsResponse',
  '2': [
    {
      '1': 'views',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.dzeroth.beacons.v1.BeaconView',
      '10': 'views'
    },
    {'1': 'next_page_token', '3': 2, '4': 1, '5': 9, '10': 'nextPageToken'},
  ],
};

/// Descriptor for `ListSharedBeaconsResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listSharedBeaconsResponseDescriptor = $convert.base64Decode(
    'ChlMaXN0U2hhcmVkQmVhY29uc1Jlc3BvbnNlEjQKBXZpZXdzGAEgAygLMh4uZHplcm90aC5iZW'
    'Fjb25zLnYxLkJlYWNvblZpZXdSBXZpZXdzEiYKD25leHRfcGFnZV90b2tlbhgCIAEoCVINbmV4'
    'dFBhZ2VUb2tlbg==');

const $core.Map<$core.String, $core.dynamic> BeaconServiceBase$json = {
  '1': 'BeaconService',
  '2': [
    {
      '1': 'CreateBeacon',
      '2': '.dzeroth.beacons.v1.CreateBeaconRequest',
      '3': '.dzeroth.beacons.v1.CreateBeaconResponse'
    },
    {
      '1': 'UpdateBeacon',
      '2': '.dzeroth.beacons.v1.UpdateBeaconRequest',
      '3': '.dzeroth.beacons.v1.UpdateBeaconResponse'
    },
    {
      '1': 'CancelBeacon',
      '2': '.dzeroth.beacons.v1.CancelBeaconRequest',
      '3': '.dzeroth.beacons.v1.CancelBeaconResponse'
    },
    {
      '1': 'GetBeacon',
      '2': '.dzeroth.beacons.v1.GetBeaconRequest',
      '3': '.dzeroth.beacons.v1.GetBeaconResponse',
      '4': {'34': 1},
    },
    {
      '1': 'ListBeacons',
      '2': '.dzeroth.beacons.v1.ListBeaconsRequest',
      '3': '.dzeroth.beacons.v1.ListBeaconsResponse',
      '4': {'34': 1},
    },
    {
      '1': 'ListMyBeacons',
      '2': '.dzeroth.beacons.v1.ListMyBeaconsRequest',
      '3': '.dzeroth.beacons.v1.ListMyBeaconsResponse',
      '4': {'34': 1},
    },
    {
      '1': 'RequestToJoin',
      '2': '.dzeroth.beacons.v1.RequestToJoinRequest',
      '3': '.dzeroth.beacons.v1.RequestToJoinResponse'
    },
    {
      '1': 'WithdrawJoinRequest',
      '2': '.dzeroth.beacons.v1.WithdrawJoinRequestRequest',
      '3': '.dzeroth.beacons.v1.WithdrawJoinRequestResponse'
    },
    {
      '1': 'RespondToJoinRequest',
      '2': '.dzeroth.beacons.v1.RespondToJoinRequestRequest',
      '3': '.dzeroth.beacons.v1.RespondToJoinRequestResponse'
    },
    {
      '1': 'LeaveBeacon',
      '2': '.dzeroth.beacons.v1.LeaveBeaconRequest',
      '3': '.dzeroth.beacons.v1.LeaveBeaconResponse'
    },
    {
      '1': 'RemoveParticipant',
      '2': '.dzeroth.beacons.v1.RemoveParticipantRequest',
      '3': '.dzeroth.beacons.v1.RemoveParticipantResponse'
    },
    {
      '1': 'ListParticipants',
      '2': '.dzeroth.beacons.v1.ListParticipantsRequest',
      '3': '.dzeroth.beacons.v1.ListParticipantsResponse',
      '4': {'34': 1},
    },
    {
      '1': 'ListSharedBeacons',
      '2': '.dzeroth.beacons.v1.ListSharedBeaconsRequest',
      '3': '.dzeroth.beacons.v1.ListSharedBeaconsResponse',
      '4': {'34': 1},
    },
  ],
};

@$core.Deprecated('Use beaconServiceDescriptor instead')
const $core.Map<$core.String, $core.Map<$core.String, $core.dynamic>>
    BeaconServiceBase$messageJson = {
  '.dzeroth.beacons.v1.CreateBeaconRequest': CreateBeaconRequest$json,
  '.google.protobuf.Timestamp': $1.Timestamp$json,
  '.dzeroth.beacons.v1.CreateBeaconResponse': CreateBeaconResponse$json,
  '.dzeroth.beacons.v1.BeaconView': BeaconView$json,
  '.dzeroth.beacons.v1.Beacon': Beacon$json,
  '.dzeroth.common.v1.AuthorSnapshot': $0.AuthorSnapshot$json,
  '.dzeroth.beacons.v1.ViewerState': ViewerState$json,
  '.dzeroth.beacons.v1.UpdateBeaconRequest': UpdateBeaconRequest$json,
  '.dzeroth.beacons.v1.UpdateBeaconResponse': UpdateBeaconResponse$json,
  '.dzeroth.beacons.v1.CancelBeaconRequest': CancelBeaconRequest$json,
  '.dzeroth.beacons.v1.CancelBeaconResponse': CancelBeaconResponse$json,
  '.dzeroth.beacons.v1.GetBeaconRequest': GetBeaconRequest$json,
  '.dzeroth.beacons.v1.GetBeaconResponse': GetBeaconResponse$json,
  '.dzeroth.beacons.v1.ListBeaconsRequest': ListBeaconsRequest$json,
  '.dzeroth.beacons.v1.ListBeaconsResponse': ListBeaconsResponse$json,
  '.dzeroth.beacons.v1.ListMyBeaconsRequest': ListMyBeaconsRequest$json,
  '.dzeroth.beacons.v1.ListMyBeaconsResponse': ListMyBeaconsResponse$json,
  '.dzeroth.beacons.v1.RequestToJoinRequest': RequestToJoinRequest$json,
  '.dzeroth.beacons.v1.RequestToJoinResponse': RequestToJoinResponse$json,
  '.dzeroth.beacons.v1.WithdrawJoinRequestRequest':
      WithdrawJoinRequestRequest$json,
  '.dzeroth.beacons.v1.WithdrawJoinRequestResponse':
      WithdrawJoinRequestResponse$json,
  '.dzeroth.beacons.v1.RespondToJoinRequestRequest':
      RespondToJoinRequestRequest$json,
  '.dzeroth.beacons.v1.RespondToJoinRequestResponse':
      RespondToJoinRequestResponse$json,
  '.dzeroth.beacons.v1.LeaveBeaconRequest': LeaveBeaconRequest$json,
  '.dzeroth.beacons.v1.LeaveBeaconResponse': LeaveBeaconResponse$json,
  '.dzeroth.beacons.v1.RemoveParticipantRequest': RemoveParticipantRequest$json,
  '.dzeroth.beacons.v1.RemoveParticipantResponse':
      RemoveParticipantResponse$json,
  '.dzeroth.beacons.v1.ListParticipantsRequest': ListParticipantsRequest$json,
  '.dzeroth.beacons.v1.ListParticipantsResponse': ListParticipantsResponse$json,
  '.dzeroth.beacons.v1.Participant': Participant$json,
  '.dzeroth.beacons.v1.ListSharedBeaconsRequest': ListSharedBeaconsRequest$json,
  '.dzeroth.beacons.v1.ListSharedBeaconsResponse':
      ListSharedBeaconsResponse$json,
};

/// Descriptor for `BeaconService`. Decode as a `google.protobuf.ServiceDescriptorProto`.
final $typed_data.Uint8List beaconServiceDescriptor = $convert.base64Decode(
    'Cg1CZWFjb25TZXJ2aWNlEmEKDENyZWF0ZUJlYWNvbhInLmR6ZXJvdGguYmVhY29ucy52MS5Dcm'
    'VhdGVCZWFjb25SZXF1ZXN0GiguZHplcm90aC5iZWFjb25zLnYxLkNyZWF0ZUJlYWNvblJlc3Bv'
    'bnNlEmEKDFVwZGF0ZUJlYWNvbhInLmR6ZXJvdGguYmVhY29ucy52MS5VcGRhdGVCZWFjb25SZX'
    'F1ZXN0GiguZHplcm90aC5iZWFjb25zLnYxLlVwZGF0ZUJlYWNvblJlc3BvbnNlEmEKDENhbmNl'
    'bEJlYWNvbhInLmR6ZXJvdGguYmVhY29ucy52MS5DYW5jZWxCZWFjb25SZXF1ZXN0GiguZHplcm'
    '90aC5iZWFjb25zLnYxLkNhbmNlbEJlYWNvblJlc3BvbnNlEl0KCUdldEJlYWNvbhIkLmR6ZXJv'
    'dGguYmVhY29ucy52MS5HZXRCZWFjb25SZXF1ZXN0GiUuZHplcm90aC5iZWFjb25zLnYxLkdldE'
    'JlYWNvblJlc3BvbnNlIgOQAgESYwoLTGlzdEJlYWNvbnMSJi5kemVyb3RoLmJlYWNvbnMudjEu'
    'TGlzdEJlYWNvbnNSZXF1ZXN0GicuZHplcm90aC5iZWFjb25zLnYxLkxpc3RCZWFjb25zUmVzcG'
    '9uc2UiA5ACARJpCg1MaXN0TXlCZWFjb25zEiguZHplcm90aC5iZWFjb25zLnYxLkxpc3RNeUJl'
    'YWNvbnNSZXF1ZXN0GikuZHplcm90aC5iZWFjb25zLnYxLkxpc3RNeUJlYWNvbnNSZXNwb25zZS'
    'IDkAIBEmQKDVJlcXVlc3RUb0pvaW4SKC5kemVyb3RoLmJlYWNvbnMudjEuUmVxdWVzdFRvSm9p'
    'blJlcXVlc3QaKS5kemVyb3RoLmJlYWNvbnMudjEuUmVxdWVzdFRvSm9pblJlc3BvbnNlEnYKE1'
    'dpdGhkcmF3Sm9pblJlcXVlc3QSLi5kemVyb3RoLmJlYWNvbnMudjEuV2l0aGRyYXdKb2luUmVx'
    'dWVzdFJlcXVlc3QaLy5kemVyb3RoLmJlYWNvbnMudjEuV2l0aGRyYXdKb2luUmVxdWVzdFJlc3'
    'BvbnNlEnkKFFJlc3BvbmRUb0pvaW5SZXF1ZXN0Ei8uZHplcm90aC5iZWFjb25zLnYxLlJlc3Bv'
    'bmRUb0pvaW5SZXF1ZXN0UmVxdWVzdBowLmR6ZXJvdGguYmVhY29ucy52MS5SZXNwb25kVG9Kb2'
    'luUmVxdWVzdFJlc3BvbnNlEl4KC0xlYXZlQmVhY29uEiYuZHplcm90aC5iZWFjb25zLnYxLkxl'
    'YXZlQmVhY29uUmVxdWVzdBonLmR6ZXJvdGguYmVhY29ucy52MS5MZWF2ZUJlYWNvblJlc3Bvbn'
    'NlEnAKEVJlbW92ZVBhcnRpY2lwYW50EiwuZHplcm90aC5iZWFjb25zLnYxLlJlbW92ZVBhcnRp'
    'Y2lwYW50UmVxdWVzdBotLmR6ZXJvdGguYmVhY29ucy52MS5SZW1vdmVQYXJ0aWNpcGFudFJlc3'
    'BvbnNlEnIKEExpc3RQYXJ0aWNpcGFudHMSKy5kemVyb3RoLmJlYWNvbnMudjEuTGlzdFBhcnRp'
    'Y2lwYW50c1JlcXVlc3QaLC5kemVyb3RoLmJlYWNvbnMudjEuTGlzdFBhcnRpY2lwYW50c1Jlc3'
    'BvbnNlIgOQAgESdQoRTGlzdFNoYXJlZEJlYWNvbnMSLC5kemVyb3RoLmJlYWNvbnMudjEuTGlz'
    'dFNoYXJlZEJlYWNvbnNSZXF1ZXN0Gi0uZHplcm90aC5iZWFjb25zLnYxLkxpc3RTaGFyZWRCZW'
    'Fjb25zUmVzcG9uc2UiA5ACAQ==');
