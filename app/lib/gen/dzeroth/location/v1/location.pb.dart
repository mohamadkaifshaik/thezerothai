// This is a generated file - do not edit.
//
// Generated from dzeroth/location/v1/location.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:async' as $async;
import 'dart:core' as $core;

import 'package:fixnum/fixnum.dart' as $fixnum;
import 'package:protobuf/protobuf.dart' as $pb;
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart'
    as $0;

import 'location.pbenum.dart';

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

export 'location.pbenum.dart';

/// One catalogue entry. Names are display text (1-40 code points); ids are permanent.
class Area extends $pb.GeneratedMessage {
  factory Area({
    $core.String? areaId,
    $core.String? name,
    AreaKind? kind,
    $core.String? cityId,
    $core.String? cityName,
    $core.Iterable<$core.String>? aliases,
    $core.Iterable<$core.String>? neighbourIds,
    $core.bool? retired,
  }) {
    final result = Area._();
    if (areaId != null) result.areaId = areaId;
    if (name != null) result.name = name;
    if (kind != null) result.kind = kind;
    if (cityId != null) result.cityId = cityId;
    if (cityName != null) result.cityName = cityName;
    if (aliases != null) result.aliases.addAll(aliases);
    if (neighbourIds != null) result.neighbourIds.addAll(neighbourIds);
    if (retired != null) result.retired = retired;
    return result;
  }

  Area._();

  factory Area.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Area()..mergeFromBuffer(data, registry);
  factory Area.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Area()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Area',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.location.v1'),
      createEmptyInstance: Area.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'areaId')
    ..aOS(2, _omitFieldNames ? '' : 'name')
    ..aE<AreaKind>(3, _omitFieldNames ? '' : 'kind',
        enumValues: AreaKind.values)
    ..aOS(4, _omitFieldNames ? '' : 'cityId')
    ..aOS(5, _omitFieldNames ? '' : 'cityName')
    ..pPS(6, _omitFieldNames ? '' : 'aliases')
    ..pPS(7, _omitFieldNames ? '' : 'neighbourIds')
    ..aOB(8, _omitFieldNames ? '' : 'retired')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Area clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Area copyWith(void Function(Area) updates) =>
      super.copyWith((message) => updates(message as Area)) as Area;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Area() / Area.new instead')
  static Area create() => Area._();
  static $pb.GeneratedMessage $_createMessage() => Area._();
  @$core.override
  Area createEmptyInstance() => Area._();
  @$core.pragma('dart2js:noInline')
  static Area getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Area>(Area.$_createMessage);
  static Area? _defaultInstance;

  /// e.g. "in.blr.indiranagar" or "in.blr".
  @$pb.TagNumber(1)
  $core.String get areaId => $_getSZ(0);
  @$pb.TagNumber(1)
  set areaId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasAreaId() => $_has(0);
  @$pb.TagNumber(1)
  void clearAreaId() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get name => $_getSZ(1);
  @$pb.TagNumber(2)
  set name($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasName() => $_has(1);
  @$pb.TagNumber(2)
  void clearName() => $_clearField(2);

  @$pb.TagNumber(3)
  AreaKind get kind => $_getN(2);
  @$pb.TagNumber(3)
  set kind(AreaKind value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasKind() => $_has(2);
  @$pb.TagNumber(3)
  void clearKind() => $_clearField(3);

  /// The city's area_id; equals area_id for a CITY.
  @$pb.TagNumber(4)
  $core.String get cityId => $_getSZ(3);
  @$pb.TagNumber(4)
  set cityId($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasCityId() => $_has(3);
  @$pb.TagNumber(4)
  void clearCityId() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.String get cityName => $_getSZ(4);
  @$pb.TagNumber(5)
  set cityName($core.String value) => $_setString(4, value);
  @$pb.TagNumber(5)
  $core.bool hasCityName() => $_has(4);
  @$pb.TagNumber(5)
  void clearCityName() => $_clearField(5);

  /// Extra search terms (other spellings, old names). Search runs on the device.
  @$pb.TagNumber(6)
  $pb.PbList<$core.String> get aliases => $_getList(5);

  /// Curated neighbouring AREA ids (at most 8, symmetric). Empty for a CITY.
  @$pb.TagNumber(7)
  $pb.PbList<$core.String> get neighbourIds => $_getList(6);

  /// Not pickable any more; still resolves labels.
  @$pb.TagNumber(8)
  $core.bool get retired => $_getBF(7);
  @$pb.TagNumber(8)
  set retired($core.bool value) => $_setBool(7, value);
  @$pb.TagNumber(8)
  $core.bool hasRetired() => $_has(7);
  @$pb.TagNumber(8)
  void clearRetired() => $_clearField(8);
}

/// The small form other packages embed (beacons). Unset message = no area.
class AreaSummary extends $pb.GeneratedMessage {
  factory AreaSummary({
    $core.String? areaId,
    $core.String? name,
    AreaKind? kind,
    $core.String? cityId,
    $core.String? cityName,
  }) {
    final result = AreaSummary._();
    if (areaId != null) result.areaId = areaId;
    if (name != null) result.name = name;
    if (kind != null) result.kind = kind;
    if (cityId != null) result.cityId = cityId;
    if (cityName != null) result.cityName = cityName;
    return result;
  }

  AreaSummary._();

  factory AreaSummary.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      AreaSummary()..mergeFromBuffer(data, registry);
  factory AreaSummary.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      AreaSummary()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'AreaSummary',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.location.v1'),
      createEmptyInstance: AreaSummary.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'areaId')
    ..aOS(2, _omitFieldNames ? '' : 'name')
    ..aE<AreaKind>(3, _omitFieldNames ? '' : 'kind',
        enumValues: AreaKind.values)
    ..aOS(4, _omitFieldNames ? '' : 'cityId')
    ..aOS(5, _omitFieldNames ? '' : 'cityName')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AreaSummary clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AreaSummary copyWith(void Function(AreaSummary) updates) =>
      super.copyWith((message) => updates(message as AreaSummary))
          as AreaSummary;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use AreaSummary() / AreaSummary.new instead')
  static AreaSummary create() => AreaSummary._();
  static $pb.GeneratedMessage $_createMessage() => AreaSummary._();
  @$core.override
  AreaSummary createEmptyInstance() => AreaSummary._();
  @$core.pragma('dart2js:noInline')
  static AreaSummary getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<AreaSummary>(
          AreaSummary.$_createMessage);
  static AreaSummary? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get areaId => $_getSZ(0);
  @$pb.TagNumber(1)
  set areaId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasAreaId() => $_has(0);
  @$pb.TagNumber(1)
  void clearAreaId() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get name => $_getSZ(1);
  @$pb.TagNumber(2)
  set name($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasName() => $_has(1);
  @$pb.TagNumber(2)
  void clearName() => $_clearField(2);

  @$pb.TagNumber(3)
  AreaKind get kind => $_getN(2);
  @$pb.TagNumber(3)
  set kind(AreaKind value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasKind() => $_has(2);
  @$pb.TagNumber(3)
  void clearKind() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.String get cityId => $_getSZ(3);
  @$pb.TagNumber(4)
  set cityId($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasCityId() => $_has(3);
  @$pb.TagNumber(4)
  void clearCityId() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.String get cityName => $_getSZ(4);
  @$pb.TagNumber(5)
  set cityName($core.String value) => $_setString(4, value);
  @$pb.TagNumber(5)
  $core.bool hasCityName() => $_has(4);
  @$pb.TagNumber(5)
  void clearCityName() => $_clearField(5);
}

class ConsentState extends $pb.GeneratedMessage {
  factory ConsentState({
    LocationConsentAction? action,
    LocationPurpose? purpose,
    $core.int? copyVersion,
    $0.Timestamp? at,
    $0.Timestamp? adultConfirmedAt,
  }) {
    final result = ConsentState._();
    if (action != null) result.action = action;
    if (purpose != null) result.purpose = purpose;
    if (copyVersion != null) result.copyVersion = copyVersion;
    if (at != null) result.at = at;
    if (adultConfirmedAt != null) result.adultConfirmedAt = adultConfirmedAt;
    return result;
  }

  ConsentState._();

  factory ConsentState.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ConsentState()..mergeFromBuffer(data, registry);
  factory ConsentState.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ConsentState()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ConsentState',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.location.v1'),
      createEmptyInstance: ConsentState.$_createMessage)
    ..aE<LocationConsentAction>(1, _omitFieldNames ? '' : 'action',
        enumValues: LocationConsentAction.values)
    ..aE<LocationPurpose>(2, _omitFieldNames ? '' : 'purpose',
        enumValues: LocationPurpose.values)
    ..aI(3, _omitFieldNames ? '' : 'copyVersion')
    ..aOM<$0.Timestamp>(4, _omitFieldNames ? '' : 'at',
        subBuilder: $0.Timestamp.$_createMessage)
    ..aOM<$0.Timestamp>(5, _omitFieldNames ? '' : 'adultConfirmedAt',
        subBuilder: $0.Timestamp.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ConsentState clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ConsentState copyWith(void Function(ConsentState) updates) =>
      super.copyWith((message) => updates(message as ConsentState))
          as ConsentState;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use ConsentState() / ConsentState.new instead')
  static ConsentState create() => ConsentState._();
  static $pb.GeneratedMessage $_createMessage() => ConsentState._();
  @$core.override
  ConsentState createEmptyInstance() => ConsentState._();
  @$core.pragma('dart2js:noInline')
  static ConsentState getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<ConsentState>(
          ConsentState.$_createMessage);
  static ConsentState? _defaultInstance;

  /// Latest record's action; UNSPECIFIED when the user never consented.
  @$pb.TagNumber(1)
  LocationConsentAction get action => $_getN(0);
  @$pb.TagNumber(1)
  set action(LocationConsentAction value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasAction() => $_has(0);
  @$pb.TagNumber(1)
  void clearAction() => $_clearField(1);

  @$pb.TagNumber(2)
  LocationPurpose get purpose => $_getN(1);
  @$pb.TagNumber(2)
  set purpose(LocationPurpose value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasPurpose() => $_has(1);
  @$pb.TagNumber(2)
  void clearPurpose() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.int get copyVersion => $_getIZ(2);
  @$pb.TagNumber(3)
  set copyVersion($core.int value) => $_setSignedInt32(2, value);
  @$pb.TagNumber(3)
  $core.bool hasCopyVersion() => $_has(2);
  @$pb.TagNumber(3)
  void clearCopyVersion() => $_clearField(3);

  @$pb.TagNumber(4)
  $0.Timestamp get at => $_getN(3);
  @$pb.TagNumber(4)
  set at($0.Timestamp value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasAt() => $_has(3);
  @$pb.TagNumber(4)
  void clearAt() => $_clearField(4);
  @$pb.TagNumber(4)
  $0.Timestamp ensureAt() => $_ensure(3);

  /// When "18+ confirmed" was recorded with the grant (C4 interim self-declared gate). Unset if never.
  @$pb.TagNumber(5)
  $0.Timestamp get adultConfirmedAt => $_getN(4);
  @$pb.TagNumber(5)
  set adultConfirmedAt($0.Timestamp value) => $_setField(5, value);
  @$pb.TagNumber(5)
  $core.bool hasAdultConfirmedAt() => $_has(4);
  @$pb.TagNumber(5)
  void clearAdultConfirmedAt() => $_clearField(5);
  @$pb.TagNumber(5)
  $0.Timestamp ensureAdultConfirmedAt() => $_ensure(4);
}

/// What the client sends with the first SetArea (and again after a copy version bump).
class ConsentGrant extends $pb.GeneratedMessage {
  factory ConsentGrant({
    $core.int? copyVersion,
    $core.bool? adultConfirmed,
  }) {
    final result = ConsentGrant._();
    if (copyVersion != null) result.copyVersion = copyVersion;
    if (adultConfirmed != null) result.adultConfirmed = adultConfirmed;
    return result;
  }

  ConsentGrant._();

  factory ConsentGrant.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ConsentGrant()..mergeFromBuffer(data, registry);
  factory ConsentGrant.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ConsentGrant()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ConsentGrant',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.location.v1'),
      createEmptyInstance: ConsentGrant.$_createMessage)
    ..aI(1, _omitFieldNames ? '' : 'copyVersion')
    ..aOB(2, _omitFieldNames ? '' : 'adultConfirmed')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ConsentGrant clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ConsentGrant copyWith(void Function(ConsentGrant) updates) =>
      super.copyWith((message) => updates(message as ConsentGrant))
          as ConsentGrant;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use ConsentGrant() / ConsentGrant.new instead')
  static ConsentGrant create() => ConsentGrant._();
  static $pb.GeneratedMessage $_createMessage() => ConsentGrant._();
  @$core.override
  ConsentGrant createEmptyInstance() => ConsentGrant._();
  @$core.pragma('dart2js:noInline')
  static ConsentGrant getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<ConsentGrant>(
          ConsentGrant.$_createMessage);
  static ConsentGrant? _defaultInstance;

  /// The rationale copy the user saw; >= the server minimum (LOCATION_CONSENT_MIN_COPY_VERSION, 1).
  @$pb.TagNumber(1)
  $core.int get copyVersion => $_getIZ(0);
  @$pb.TagNumber(1)
  set copyVersion($core.int value) => $_setSignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasCopyVersion() => $_has(0);
  @$pb.TagNumber(1)
  void clearCopyVersion() => $_clearField(1);

  /// The user ticked "I am 18 or older". Must be true.
  @$pb.TagNumber(2)
  $core.bool get adultConfirmed => $_getBF(1);
  @$pb.TagNumber(2)
  set adultConfirmed($core.bool value) => $_setBool(1, value);
  @$pb.TagNumber(2)
  $core.bool hasAdultConfirmed() => $_has(1);
  @$pb.TagNumber(2)
  void clearAdultConfirmed() => $_clearField(2);
}

class LocationSettings extends $pb.GeneratedMessage {
  factory LocationSettings({
    AreaSummary? area,
    ConsentState? consent,
    $core.int? requiredCopyVersion,
  }) {
    final result = LocationSettings._();
    if (area != null) result.area = area;
    if (consent != null) result.consent = consent;
    if (requiredCopyVersion != null)
      result.requiredCopyVersion = requiredCopyVersion;
    return result;
  }

  LocationSettings._();

  factory LocationSettings.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      LocationSettings()..mergeFromBuffer(data, registry);
  factory LocationSettings.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      LocationSettings()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'LocationSettings',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.location.v1'),
      createEmptyInstance: LocationSettings.$_createMessage)
    ..aOM<AreaSummary>(1, _omitFieldNames ? '' : 'area',
        subBuilder: AreaSummary.$_createMessage)
    ..aOM<ConsentState>(2, _omitFieldNames ? '' : 'consent',
        subBuilder: ConsentState.$_createMessage)
    ..aI(3, _omitFieldNames ? '' : 'requiredCopyVersion')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  LocationSettings clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  LocationSettings copyWith(void Function(LocationSettings) updates) =>
      super.copyWith((message) => updates(message as LocationSettings))
          as LocationSettings;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use LocationSettings() / LocationSettings.new instead')
  static LocationSettings create() => LocationSettings._();
  static $pb.GeneratedMessage $_createMessage() => LocationSettings._();
  @$core.override
  LocationSettings createEmptyInstance() => LocationSettings._();
  @$core.pragma('dart2js:noInline')
  static LocationSettings getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<LocationSettings>(
          LocationSettings.$_createMessage);
  static LocationSettings? _defaultInstance;

  /// Unset when no area is set.
  @$pb.TagNumber(1)
  AreaSummary get area => $_getN(0);
  @$pb.TagNumber(1)
  set area(AreaSummary value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasArea() => $_has(0);
  @$pb.TagNumber(1)
  void clearArea() => $_clearField(1);
  @$pb.TagNumber(1)
  AreaSummary ensureArea() => $_ensure(0);

  @$pb.TagNumber(2)
  ConsentState get consent => $_getN(1);
  @$pb.TagNumber(2)
  set consent(ConsentState value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasConsent() => $_has(1);
  @$pb.TagNumber(2)
  void clearConsent() => $_clearField(2);
  @$pb.TagNumber(2)
  ConsentState ensureConsent() => $_ensure(1);

  /// The minimum copy version the server accepts; the client re-shows the rationale when consent.copy_version is lower.
  @$pb.TagNumber(3)
  $core.int get requiredCopyVersion => $_getIZ(2);
  @$pb.TagNumber(3)
  set requiredCopyVersion($core.int value) => $_setSignedInt32(2, value);
  @$pb.TagNumber(3)
  $core.bool hasRequiredCopyVersion() => $_has(2);
  @$pb.TagNumber(3)
  void clearRequiredCopyVersion() => $_clearField(3);
}

class GetLocationSettingsRequest extends $pb.GeneratedMessage {
  factory GetLocationSettingsRequest() => GetLocationSettingsRequest._();

  GetLocationSettingsRequest._();

  factory GetLocationSettingsRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetLocationSettingsRequest()..mergeFromBuffer(data, registry);
  factory GetLocationSettingsRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetLocationSettingsRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetLocationSettingsRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.location.v1'),
      createEmptyInstance: GetLocationSettingsRequest.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetLocationSettingsRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetLocationSettingsRequest copyWith(
          void Function(GetLocationSettingsRequest) updates) =>
      super.copyWith(
              (message) => updates(message as GetLocationSettingsRequest))
          as GetLocationSettingsRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use GetLocationSettingsRequest() / GetLocationSettingsRequest.new instead')
  static GetLocationSettingsRequest create() => GetLocationSettingsRequest._();
  static $pb.GeneratedMessage $_createMessage() =>
      GetLocationSettingsRequest._();
  @$core.override
  GetLocationSettingsRequest createEmptyInstance() =>
      GetLocationSettingsRequest._();
  @$core.pragma('dart2js:noInline')
  static GetLocationSettingsRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<GetLocationSettingsRequest>(
          GetLocationSettingsRequest.$_createMessage);
  static GetLocationSettingsRequest? _defaultInstance;
}

class GetLocationSettingsResponse extends $pb.GeneratedMessage {
  factory GetLocationSettingsResponse({
    LocationSettings? settings,
  }) {
    final result = GetLocationSettingsResponse._();
    if (settings != null) result.settings = settings;
    return result;
  }

  GetLocationSettingsResponse._();

  factory GetLocationSettingsResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetLocationSettingsResponse()..mergeFromBuffer(data, registry);
  factory GetLocationSettingsResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetLocationSettingsResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetLocationSettingsResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.location.v1'),
      createEmptyInstance: GetLocationSettingsResponse.$_createMessage)
    ..aOM<LocationSettings>(1, _omitFieldNames ? '' : 'settings',
        subBuilder: LocationSettings.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetLocationSettingsResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetLocationSettingsResponse copyWith(
          void Function(GetLocationSettingsResponse) updates) =>
      super.copyWith(
              (message) => updates(message as GetLocationSettingsResponse))
          as GetLocationSettingsResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use GetLocationSettingsResponse() / GetLocationSettingsResponse.new instead')
  static GetLocationSettingsResponse create() =>
      GetLocationSettingsResponse._();
  static $pb.GeneratedMessage $_createMessage() =>
      GetLocationSettingsResponse._();
  @$core.override
  GetLocationSettingsResponse createEmptyInstance() =>
      GetLocationSettingsResponse._();
  @$core.pragma('dart2js:noInline')
  static GetLocationSettingsResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<GetLocationSettingsResponse>(
          GetLocationSettingsResponse.$_createMessage);
  static GetLocationSettingsResponse? _defaultInstance;

  @$pb.TagNumber(1)
  LocationSettings get settings => $_getN(0);
  @$pb.TagNumber(1)
  set settings(LocationSettings value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasSettings() => $_has(0);
  @$pb.TagNumber(1)
  void clearSettings() => $_clearField(1);
  @$pb.TagNumber(1)
  LocationSettings ensureSettings() => $_ensure(0);
}

class SetAreaRequest extends $pb.GeneratedMessage {
  factory SetAreaRequest({
    $core.String? idempotencyKey,
    $core.String? areaId,
    ConsentGrant? consent,
  }) {
    final result = SetAreaRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (areaId != null) result.areaId = areaId;
    if (consent != null) result.consent = consent;
    return result;
  }

  SetAreaRequest._();

  factory SetAreaRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SetAreaRequest()..mergeFromBuffer(data, registry);
  factory SetAreaRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SetAreaRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'SetAreaRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.location.v1'),
      createEmptyInstance: SetAreaRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'areaId')
    ..aOM<ConsentGrant>(3, _omitFieldNames ? '' : 'consent',
        subBuilder: ConsentGrant.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SetAreaRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SetAreaRequest copyWith(void Function(SetAreaRequest) updates) =>
      super.copyWith((message) => updates(message as SetAreaRequest))
          as SetAreaRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use SetAreaRequest() / SetAreaRequest.new instead')
  static SetAreaRequest create() => SetAreaRequest._();
  static $pb.GeneratedMessage $_createMessage() => SetAreaRequest._();
  @$core.override
  SetAreaRequest createEmptyInstance() => SetAreaRequest._();
  @$core.pragma('dart2js:noInline')
  static SetAreaRequest getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<SetAreaRequest>(
          SetAreaRequest.$_createMessage);
  static SetAreaRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get areaId => $_getSZ(1);
  @$pb.TagNumber(2)
  set areaId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasAreaId() => $_has(1);
  @$pb.TagNumber(2)
  void clearAreaId() => $_clearField(2);

  /// Required when the caller has no valid consent (see SetArea); ignored otherwise.
  @$pb.TagNumber(3)
  ConsentGrant get consent => $_getN(2);
  @$pb.TagNumber(3)
  set consent(ConsentGrant value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasConsent() => $_has(2);
  @$pb.TagNumber(3)
  void clearConsent() => $_clearField(3);
  @$pb.TagNumber(3)
  ConsentGrant ensureConsent() => $_ensure(2);
}

class SetAreaResponse extends $pb.GeneratedMessage {
  factory SetAreaResponse({
    LocationSettings? settings,
  }) {
    final result = SetAreaResponse._();
    if (settings != null) result.settings = settings;
    return result;
  }

  SetAreaResponse._();

  factory SetAreaResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SetAreaResponse()..mergeFromBuffer(data, registry);
  factory SetAreaResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SetAreaResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'SetAreaResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.location.v1'),
      createEmptyInstance: SetAreaResponse.$_createMessage)
    ..aOM<LocationSettings>(1, _omitFieldNames ? '' : 'settings',
        subBuilder: LocationSettings.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SetAreaResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SetAreaResponse copyWith(void Function(SetAreaResponse) updates) =>
      super.copyWith((message) => updates(message as SetAreaResponse))
          as SetAreaResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use SetAreaResponse() / SetAreaResponse.new instead')
  static SetAreaResponse create() => SetAreaResponse._();
  static $pb.GeneratedMessage $_createMessage() => SetAreaResponse._();
  @$core.override
  SetAreaResponse createEmptyInstance() => SetAreaResponse._();
  @$core.pragma('dart2js:noInline')
  static SetAreaResponse getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<SetAreaResponse>(
          SetAreaResponse.$_createMessage);
  static SetAreaResponse? _defaultInstance;

  @$pb.TagNumber(1)
  LocationSettings get settings => $_getN(0);
  @$pb.TagNumber(1)
  set settings(LocationSettings value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasSettings() => $_has(0);
  @$pb.TagNumber(1)
  void clearSettings() => $_clearField(1);
  @$pb.TagNumber(1)
  LocationSettings ensureSettings() => $_ensure(0);
}

class ClearAreaRequest extends $pb.GeneratedMessage {
  factory ClearAreaRequest({
    $core.String? idempotencyKey,
  }) {
    final result = ClearAreaRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    return result;
  }

  ClearAreaRequest._();

  factory ClearAreaRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ClearAreaRequest()..mergeFromBuffer(data, registry);
  factory ClearAreaRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ClearAreaRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ClearAreaRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.location.v1'),
      createEmptyInstance: ClearAreaRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ClearAreaRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ClearAreaRequest copyWith(void Function(ClearAreaRequest) updates) =>
      super.copyWith((message) => updates(message as ClearAreaRequest))
          as ClearAreaRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use ClearAreaRequest() / ClearAreaRequest.new instead')
  static ClearAreaRequest create() => ClearAreaRequest._();
  static $pb.GeneratedMessage $_createMessage() => ClearAreaRequest._();
  @$core.override
  ClearAreaRequest createEmptyInstance() => ClearAreaRequest._();
  @$core.pragma('dart2js:noInline')
  static ClearAreaRequest getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<ClearAreaRequest>(
          ClearAreaRequest.$_createMessage);
  static ClearAreaRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);
}

class ClearAreaResponse extends $pb.GeneratedMessage {
  factory ClearAreaResponse({
    LocationSettings? settings,
  }) {
    final result = ClearAreaResponse._();
    if (settings != null) result.settings = settings;
    return result;
  }

  ClearAreaResponse._();

  factory ClearAreaResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ClearAreaResponse()..mergeFromBuffer(data, registry);
  factory ClearAreaResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ClearAreaResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ClearAreaResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.location.v1'),
      createEmptyInstance: ClearAreaResponse.$_createMessage)
    ..aOM<LocationSettings>(1, _omitFieldNames ? '' : 'settings',
        subBuilder: LocationSettings.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ClearAreaResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ClearAreaResponse copyWith(void Function(ClearAreaResponse) updates) =>
      super.copyWith((message) => updates(message as ClearAreaResponse))
          as ClearAreaResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use ClearAreaResponse() / ClearAreaResponse.new instead')
  static ClearAreaResponse create() => ClearAreaResponse._();
  static $pb.GeneratedMessage $_createMessage() => ClearAreaResponse._();
  @$core.override
  ClearAreaResponse createEmptyInstance() => ClearAreaResponse._();
  @$core.pragma('dart2js:noInline')
  static ClearAreaResponse getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<ClearAreaResponse>(
          ClearAreaResponse.$_createMessage);
  static ClearAreaResponse? _defaultInstance;

  @$pb.TagNumber(1)
  LocationSettings get settings => $_getN(0);
  @$pb.TagNumber(1)
  set settings(LocationSettings value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasSettings() => $_has(0);
  @$pb.TagNumber(1)
  void clearSettings() => $_clearField(1);
  @$pb.TagNumber(1)
  LocationSettings ensureSettings() => $_ensure(0);
}

class ListAreasRequest extends $pb.GeneratedMessage {
  factory ListAreasRequest({
    $core.int? limit,
    $core.String? pageToken,
    $fixnum.Int64? knownVersion,
  }) {
    final result = ListAreasRequest._();
    if (limit != null) result.limit = limit;
    if (pageToken != null) result.pageToken = pageToken;
    if (knownVersion != null) result.knownVersion = knownVersion;
    return result;
  }

  ListAreasRequest._();

  factory ListAreasRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListAreasRequest()..mergeFromBuffer(data, registry);
  factory ListAreasRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListAreasRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListAreasRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.location.v1'),
      createEmptyInstance: ListAreasRequest.$_createMessage)
    ..aI(1, _omitFieldNames ? '' : 'limit')
    ..aOS(2, _omitFieldNames ? '' : 'pageToken')
    ..aInt64(3, _omitFieldNames ? '' : 'knownVersion')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListAreasRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListAreasRequest copyWith(void Function(ListAreasRequest) updates) =>
      super.copyWith((message) => updates(message as ListAreasRequest))
          as ListAreasRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use ListAreasRequest() / ListAreasRequest.new instead')
  static ListAreasRequest create() => ListAreasRequest._();
  static $pb.GeneratedMessage $_createMessage() => ListAreasRequest._();
  @$core.override
  ListAreasRequest createEmptyInstance() => ListAreasRequest._();
  @$core.pragma('dart2js:noInline')
  static ListAreasRequest getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<ListAreasRequest>(
          ListAreasRequest.$_createMessage);
  static ListAreasRequest? _defaultInstance;

  /// Clamped: 0 = 200, above 500 = 500.
  @$pb.TagNumber(1)
  $core.int get limit => $_getIZ(0);
  @$pb.TagNumber(1)
  set limit($core.int value) => $_setSignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasLimit() => $_has(0);
  @$pb.TagNumber(1)
  void clearLimit() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get pageToken => $_getSZ(1);
  @$pb.TagNumber(2)
  set pageToken($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasPageToken() => $_has(1);
  @$pb.TagNumber(2)
  void clearPageToken() => $_clearField(2);

  /// The version the client holds; 0 = none.
  @$pb.TagNumber(3)
  $fixnum.Int64 get knownVersion => $_getI64(2);
  @$pb.TagNumber(3)
  set knownVersion($fixnum.Int64 value) => $_setInt64(2, value);
  @$pb.TagNumber(3)
  $core.bool hasKnownVersion() => $_has(2);
  @$pb.TagNumber(3)
  void clearKnownVersion() => $_clearField(3);
}

class ListAreasResponse extends $pb.GeneratedMessage {
  factory ListAreasResponse({
    $core.Iterable<Area>? areas,
    $core.String? nextPageToken,
    $fixnum.Int64? version,
    $core.bool? notModified,
  }) {
    final result = ListAreasResponse._();
    if (areas != null) result.areas.addAll(areas);
    if (nextPageToken != null) result.nextPageToken = nextPageToken;
    if (version != null) result.version = version;
    if (notModified != null) result.notModified = notModified;
    return result;
  }

  ListAreasResponse._();

  factory ListAreasResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListAreasResponse()..mergeFromBuffer(data, registry);
  factory ListAreasResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListAreasResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListAreasResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.location.v1'),
      createEmptyInstance: ListAreasResponse.$_createMessage)
    ..pPM<Area>(1, _omitFieldNames ? '' : 'areas',
        subBuilder: Area.$_createMessage)
    ..aOS(2, _omitFieldNames ? '' : 'nextPageToken')
    ..aInt64(3, _omitFieldNames ? '' : 'version')
    ..aOB(4, _omitFieldNames ? '' : 'notModified')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListAreasResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListAreasResponse copyWith(void Function(ListAreasResponse) updates) =>
      super.copyWith((message) => updates(message as ListAreasResponse))
          as ListAreasResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use ListAreasResponse() / ListAreasResponse.new instead')
  static ListAreasResponse create() => ListAreasResponse._();
  static $pb.GeneratedMessage $_createMessage() => ListAreasResponse._();
  @$core.override
  ListAreasResponse createEmptyInstance() => ListAreasResponse._();
  @$core.pragma('dart2js:noInline')
  static ListAreasResponse getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<ListAreasResponse>(
          ListAreasResponse.$_createMessage);
  static ListAreasResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<Area> get areas => $_getList(0);

  @$pb.TagNumber(2)
  $core.String get nextPageToken => $_getSZ(1);
  @$pb.TagNumber(2)
  set nextPageToken($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasNextPageToken() => $_has(1);
  @$pb.TagNumber(2)
  void clearNextPageToken() => $_clearField(2);

  @$pb.TagNumber(3)
  $fixnum.Int64 get version => $_getI64(2);
  @$pb.TagNumber(3)
  set version($fixnum.Int64 value) => $_setInt64(2, value);
  @$pb.TagNumber(3)
  $core.bool hasVersion() => $_has(2);
  @$pb.TagNumber(3)
  void clearVersion() => $_clearField(3);

  /// True when known_version == version; areas is then empty.
  @$pb.TagNumber(4)
  $core.bool get notModified => $_getBF(3);
  @$pb.TagNumber(4)
  set notModified($core.bool value) => $_setBool(3, value);
  @$pb.TagNumber(4)
  $core.bool hasNotModified() => $_has(3);
  @$pb.TagNumber(4)
  void clearNotModified() => $_clearField(4);
}

class LocationServiceApi {
  final $pb.RpcClient _client;

  LocationServiceApi(this._client);

  /// The caller's area (unset when none) and latest consent state. 1 read (+1 for the latest consent record when no
  /// area is set). Works in every flag mode.
  $async.Future<GetLocationSettingsResponse> getLocationSettings(
          $pb.ClientContext? ctx, GetLocationSettingsRequest request) =>
      _client.invoke<GetLocationSettingsResponse>(ctx, 'LocationService',
          'GetLocationSettings', request, GetLocationSettingsResponse());

  /// Set or change the caller's area. area_id must be a non-retired catalogue id (VALIDATION "area_id").
  /// When the caller has no current consent at copy version >= the server minimum, the request must carry consent with
  /// adult_confirmed = true and copy_version >= the minimum (else VALIDATION "consent" when present but invalid, or
  /// FAILED_PRECONDITION "consent_required" when absent); a LOCATION_CONSENT_ACTION_GRANTED record is appended in the
  /// same transaction. A change of area under an existing consent appends nothing (no location history). Setting the
  /// stored area again writes only the idempotency doc.
  $async.Future<SetAreaResponse> setArea(
          $pb.ClientContext? ctx, SetAreaRequest request) =>
      _client.invoke<SetAreaResponse>(
          ctx, 'LocationService', 'SetArea', request, SetAreaResponse());

  /// Withdraw: delete the area doc and append a LOCATION_CONSENT_ACTION_WITHDRAWN record in one transaction. No area set
  /// => success, writing only the idempotency doc. Works in every flag mode.
  $async.Future<ClearAreaResponse> clearArea(
          $pb.ClientContext? ctx, ClearAreaRequest request) =>
      _client.invoke<ClearAreaResponse>(
          ctx, 'LocationService', 'ClearArea', request, ClearAreaResponse());

  /// The area catalogue, sorted by area_id, paged. known_version equal to the server's => not_modified = true and no
  /// areas. page_token is signed and bound to the caller and the catalogue version; a version change mid-paging =>
  /// VALIDATION "page_token" (restart). Retired areas are included (retired = true) so old plans keep their label.
  $async.Future<ListAreasResponse> listAreas(
          $pb.ClientContext? ctx, ListAreasRequest request) =>
      _client.invoke<ListAreasResponse>(
          ctx, 'LocationService', 'ListAreas', request, ListAreasResponse());
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
