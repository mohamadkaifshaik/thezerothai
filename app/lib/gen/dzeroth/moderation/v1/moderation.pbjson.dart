// This is a generated file - do not edit.
//
// Generated from dzeroth/moderation/v1/moderation.proto.

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

@$core.Deprecated('Use reportTargetTypeDescriptor instead')
const ReportTargetType$json = {
  '1': 'ReportTargetType',
  '2': [
    {'1': 'REPORT_TARGET_TYPE_UNSPECIFIED', '2': 0},
    {'1': 'REPORT_TARGET_TYPE_POST', '2': 1},
    {'1': 'REPORT_TARGET_TYPE_ACCOUNT', '2': 2},
  ],
};

/// Descriptor for `ReportTargetType`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List reportTargetTypeDescriptor = $convert.base64Decode(
    'ChBSZXBvcnRUYXJnZXRUeXBlEiIKHlJFUE9SVF9UQVJHRVRfVFlQRV9VTlNQRUNJRklFRBAAEh'
    'sKF1JFUE9SVF9UQVJHRVRfVFlQRV9QT1NUEAESHgoaUkVQT1JUX1RBUkdFVF9UWVBFX0FDQ09V'
    'TlQQAg==');

@$core.Deprecated('Use reportReasonDescriptor instead')
const ReportReason$json = {
  '1': 'ReportReason',
  '2': [
    {'1': 'REPORT_REASON_UNSPECIFIED', '2': 0},
    {'1': 'REPORT_REASON_SPAM', '2': 1},
    {'1': 'REPORT_REASON_HARASSMENT', '2': 2},
    {'1': 'REPORT_REASON_HATE', '2': 3},
    {'1': 'REPORT_REASON_VIOLENCE', '2': 4},
    {'1': 'REPORT_REASON_SEXUAL', '2': 5},
    {'1': 'REPORT_REASON_SELF_HARM', '2': 6},
    {'1': 'REPORT_REASON_ILLEGAL', '2': 7},
    {'1': 'REPORT_REASON_IMPERSONATION', '2': 8},
    {'1': 'REPORT_REASON_OTHER', '2': 9},
  ],
};

/// Descriptor for `ReportReason`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List reportReasonDescriptor = $convert.base64Decode(
    'CgxSZXBvcnRSZWFzb24SHQoZUkVQT1JUX1JFQVNPTl9VTlNQRUNJRklFRBAAEhYKElJFUE9SVF'
    '9SRUFTT05fU1BBTRABEhwKGFJFUE9SVF9SRUFTT05fSEFSQVNTTUVOVBACEhYKElJFUE9SVF9S'
    'RUFTT05fSEFURRADEhoKFlJFUE9SVF9SRUFTT05fVklPTEVOQ0UQBBIYChRSRVBPUlRfUkVBU0'
    '9OX1NFWFVBTBAFEhsKF1JFUE9SVF9SRUFTT05fU0VMRl9IQVJNEAYSGQoVUkVQT1JUX1JFQVNP'
    'Tl9JTExFR0FMEAcSHwobUkVQT1JUX1JFQVNPTl9JTVBFUlNPTkFUSU9OEAgSFwoTUkVQT1JUX1'
    'JFQVNPTl9PVEhFUhAJ');

@$core.Deprecated('Use reportContentRequestDescriptor instead')
const ReportContentRequest$json = {
  '1': 'ReportContentRequest',
  '2': [
    {'1': 'idempotency_key', '3': 1, '4': 1, '5': 9, '10': 'idempotencyKey'},
    {
      '1': 'target_type',
      '3': 2,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.moderation.v1.ReportTargetType',
      '10': 'targetType'
    },
    {'1': 'target_id', '3': 3, '4': 1, '5': 9, '10': 'targetId'},
    {
      '1': 'reason',
      '3': 4,
      '4': 1,
      '5': 14,
      '6': '.dzeroth.moderation.v1.ReportReason',
      '10': 'reason'
    },
    {'1': 'note', '3': 5, '4': 1, '5': 9, '10': 'note'},
  ],
};

/// Descriptor for `ReportContentRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List reportContentRequestDescriptor = $convert.base64Decode(
    'ChRSZXBvcnRDb250ZW50UmVxdWVzdBInCg9pZGVtcG90ZW5jeV9rZXkYASABKAlSDmlkZW1wb3'
    'RlbmN5S2V5EkgKC3RhcmdldF90eXBlGAIgASgOMicuZHplcm90aC5tb2RlcmF0aW9uLnYxLlJl'
    'cG9ydFRhcmdldFR5cGVSCnRhcmdldFR5cGUSGwoJdGFyZ2V0X2lkGAMgASgJUgh0YXJnZXRJZB'
    'I7CgZyZWFzb24YBCABKA4yIy5kemVyb3RoLm1vZGVyYXRpb24udjEuUmVwb3J0UmVhc29uUgZy'
    'ZWFzb24SEgoEbm90ZRgFIAEoCVIEbm90ZQ==');

@$core.Deprecated('Use reportContentResponseDescriptor instead')
const ReportContentResponse$json = {
  '1': 'ReportContentResponse',
  '2': [
    {'1': 'report_id', '3': 1, '4': 1, '5': 9, '10': 'reportId'},
    {'1': 'already_reported', '3': 2, '4': 1, '5': 8, '10': 'alreadyReported'},
  ],
};

/// Descriptor for `ReportContentResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List reportContentResponseDescriptor = $convert.base64Decode(
    'ChVSZXBvcnRDb250ZW50UmVzcG9uc2USGwoJcmVwb3J0X2lkGAEgASgJUghyZXBvcnRJZBIpCh'
    'BhbHJlYWR5X3JlcG9ydGVkGAIgASgIUg9hbHJlYWR5UmVwb3J0ZWQ=');

const $core.Map<$core.String, $core.dynamic> ModerationServiceBase$json = {
  '1': 'ModerationService',
  '2': [
    {
      '1': 'ReportContent',
      '2': '.dzeroth.moderation.v1.ReportContentRequest',
      '3': '.dzeroth.moderation.v1.ReportContentResponse'
    },
  ],
};

@$core.Deprecated('Use moderationServiceDescriptor instead')
const $core.Map<$core.String, $core.Map<$core.String, $core.dynamic>>
    ModerationServiceBase$messageJson = {
  '.dzeroth.moderation.v1.ReportContentRequest': ReportContentRequest$json,
  '.dzeroth.moderation.v1.ReportContentResponse': ReportContentResponse$json,
};

/// Descriptor for `ModerationService`. Decode as a `google.protobuf.ServiceDescriptorProto`.
final $typed_data.Uint8List moderationServiceDescriptor = $convert.base64Decode(
    'ChFNb2RlcmF0aW9uU2VydmljZRJqCg1SZXBvcnRDb250ZW50EisuZHplcm90aC5tb2RlcmF0aW'
    '9uLnYxLlJlcG9ydENvbnRlbnRSZXF1ZXN0GiwuZHplcm90aC5tb2RlcmF0aW9uLnYxLlJlcG9y'
    'dENvbnRlbnRSZXNwb25zZQ==');
