// This is a generated file - do not edit.
//
// Generated from dzeroth/location/v1/location.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

class AreaKind extends $pb.ProtobufEnum {
  static const AreaKind AREA_KIND_UNSPECIFIED =
      AreaKind._(0, _omitEnumNames ? '' : 'AREA_KIND_UNSPECIFIED');

  /// A neighbourhood inside a city.
  static const AreaKind AREA_KIND_AREA =
      AreaKind._(1, _omitEnumNames ? '' : 'AREA_KIND_AREA');

  /// A whole city.
  static const AreaKind AREA_KIND_CITY =
      AreaKind._(2, _omitEnumNames ? '' : 'AREA_KIND_CITY');

  static const $core.List<AreaKind> values = <AreaKind>[
    AREA_KIND_UNSPECIFIED,
    AREA_KIND_AREA,
    AREA_KIND_CITY,
  ];

  static final $core.List<AreaKind?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 2);
  static AreaKind? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const AreaKind._(super.value, super.name);
}

class LocationPurpose extends $pb.ProtobufEnum {
  static const LocationPurpose LOCATION_PURPOSE_UNSPECIFIED = LocationPurpose._(
      0, _omitEnumNames ? '' : 'LOCATION_PURPOSE_UNSPECIFIED');

  /// See public plans in my chosen area (Explore Nearby).
  static const LocationPurpose LOCATION_PURPOSE_PLANS_NEARBY =
      LocationPurpose._(
          1, _omitEnumNames ? '' : 'LOCATION_PURPOSE_PLANS_NEARBY');

  static const $core.List<LocationPurpose> values = <LocationPurpose>[
    LOCATION_PURPOSE_UNSPECIFIED,
    LOCATION_PURPOSE_PLANS_NEARBY,
  ];

  static final $core.List<LocationPurpose?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 1);
  static LocationPurpose? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const LocationPurpose._(super.value, super.name);
}

class LocationConsentAction extends $pb.ProtobufEnum {
  static const LocationConsentAction LOCATION_CONSENT_ACTION_UNSPECIFIED =
      LocationConsentAction._(
          0, _omitEnumNames ? '' : 'LOCATION_CONSENT_ACTION_UNSPECIFIED');
  static const LocationConsentAction LOCATION_CONSENT_ACTION_GRANTED =
      LocationConsentAction._(
          1, _omitEnumNames ? '' : 'LOCATION_CONSENT_ACTION_GRANTED');
  static const LocationConsentAction LOCATION_CONSENT_ACTION_WITHDRAWN =
      LocationConsentAction._(
          2, _omitEnumNames ? '' : 'LOCATION_CONSENT_ACTION_WITHDRAWN');

  static const $core.List<LocationConsentAction> values =
      <LocationConsentAction>[
    LOCATION_CONSENT_ACTION_UNSPECIFIED,
    LOCATION_CONSENT_ACTION_GRANTED,
    LOCATION_CONSENT_ACTION_WITHDRAWN,
  ];

  static final $core.List<LocationConsentAction?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 2);
  static LocationConsentAction? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const LocationConsentAction._(super.value, super.name);
}

const $core.bool _omitEnumNames =
    $core.bool.fromEnvironment('protobuf.omit_enum_names');
