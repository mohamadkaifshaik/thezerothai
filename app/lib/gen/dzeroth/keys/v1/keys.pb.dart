// This is a generated file - do not edit.
//
// Generated from dzeroth/keys/v1/keys.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:async' as $async;
import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart'
    as $0;

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

class KeyDevice extends $pb.GeneratedMessage {
  factory KeyDevice({
    $core.String? deviceId,
    $core.List<$core.int>? signaturePublicKey,
    $0.Timestamp? createdAt,
    $0.Timestamp? lastSeenAt,
    $core.int? keyPackageCount,
    $core.bool? hasLastResort,
  }) {
    final result = KeyDevice._();
    if (deviceId != null) result.deviceId = deviceId;
    if (signaturePublicKey != null)
      result.signaturePublicKey = signaturePublicKey;
    if (createdAt != null) result.createdAt = createdAt;
    if (lastSeenAt != null) result.lastSeenAt = lastSeenAt;
    if (keyPackageCount != null) result.keyPackageCount = keyPackageCount;
    if (hasLastResort != null) result.hasLastResort = hasLastResort;
    return result;
  }

  KeyDevice._();

  factory KeyDevice.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      KeyDevice()..mergeFromBuffer(data, registry);
  factory KeyDevice.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      KeyDevice()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'KeyDevice',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.keys.v1'),
      createEmptyInstance: KeyDevice.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'deviceId')
    ..a<$core.List<$core.int>>(
        2, _omitFieldNames ? '' : 'signaturePublicKey', $pb.PbFieldType.OY)
    ..aOM<$0.Timestamp>(3, _omitFieldNames ? '' : 'createdAt',
        subBuilder: $0.Timestamp.$_createMessage)
    ..aOM<$0.Timestamp>(4, _omitFieldNames ? '' : 'lastSeenAt',
        subBuilder: $0.Timestamp.$_createMessage)
    ..aI(5, _omitFieldNames ? '' : 'keyPackageCount')
    ..aOB(6, _omitFieldNames ? '' : 'hasLastResort')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  KeyDevice clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  KeyDevice copyWith(void Function(KeyDevice) updates) =>
      super.copyWith((message) => updates(message as KeyDevice)) as KeyDevice;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use KeyDevice() / KeyDevice.new instead')
  static KeyDevice create() => KeyDevice._();
  static $pb.GeneratedMessage $_createMessage() => KeyDevice._();
  @$core.override
  KeyDevice createEmptyInstance() => KeyDevice._();
  @$core.pragma('dart2js:noInline')
  static KeyDevice getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<KeyDevice>(KeyDevice.$_createMessage);
  static KeyDevice? _defaultInstance;

  /// [A-Za-z0-9_-]{16,64}, chosen by the device.
  @$pb.TagNumber(1)
  $core.String get deviceId => $_getSZ(0);
  @$pb.TagNumber(1)
  set deviceId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasDeviceId() => $_has(0);
  @$pb.TagNumber(1)
  void clearDeviceId() => $_clearField(1);

  /// 32 bytes (Ed25519).
  @$pb.TagNumber(2)
  $core.List<$core.int> get signaturePublicKey => $_getN(1);
  @$pb.TagNumber(2)
  set signaturePublicKey($core.List<$core.int> value) => $_setBytes(1, value);
  @$pb.TagNumber(2)
  $core.bool hasSignaturePublicKey() => $_has(1);
  @$pb.TagNumber(2)
  void clearSignaturePublicKey() => $_clearField(2);

  @$pb.TagNumber(3)
  $0.Timestamp get createdAt => $_getN(2);
  @$pb.TagNumber(3)
  set createdAt($0.Timestamp value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasCreatedAt() => $_has(2);
  @$pb.TagNumber(3)
  void clearCreatedAt() => $_clearField(3);
  @$pb.TagNumber(3)
  $0.Timestamp ensureCreatedAt() => $_ensure(2);

  /// Moved at most once per 24 h.
  @$pb.TagNumber(4)
  $0.Timestamp get lastSeenAt => $_getN(3);
  @$pb.TagNumber(4)
  set lastSeenAt($0.Timestamp value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasLastSeenAt() => $_has(3);
  @$pb.TagNumber(4)
  void clearLastSeenAt() => $_clearField(4);
  @$pb.TagNumber(4)
  $0.Timestamp ensureLastSeenAt() => $_ensure(3);

  /// One-time packages in the pool. The caller's own devices only; 0 for other users' devices.
  @$pb.TagNumber(5)
  $core.int get keyPackageCount => $_getIZ(4);
  @$pb.TagNumber(5)
  set keyPackageCount($core.int value) => $_setSignedInt32(4, value);
  @$pb.TagNumber(5)
  $core.bool hasKeyPackageCount() => $_has(4);
  @$pb.TagNumber(5)
  void clearKeyPackageCount() => $_clearField(5);

  /// The caller's own devices only; false for other users' devices.
  @$pb.TagNumber(6)
  $core.bool get hasLastResort => $_getBF(5);
  @$pb.TagNumber(6)
  set hasLastResort($core.bool value) => $_setBool(5, value);
  @$pb.TagNumber(6)
  $core.bool hasHasLastResort() => $_has(5);
  @$pb.TagNumber(6)
  void clearHasLastResort() => $_clearField(6);
}

class RegisterKeyDeviceRequest extends $pb.GeneratedMessage {
  factory RegisterKeyDeviceRequest({
    $core.String? idempotencyKey,
    $core.String? deviceId,
    $core.List<$core.int>? signaturePublicKey,
  }) {
    final result = RegisterKeyDeviceRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (deviceId != null) result.deviceId = deviceId;
    if (signaturePublicKey != null)
      result.signaturePublicKey = signaturePublicKey;
    return result;
  }

  RegisterKeyDeviceRequest._();

  factory RegisterKeyDeviceRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RegisterKeyDeviceRequest()..mergeFromBuffer(data, registry);
  factory RegisterKeyDeviceRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RegisterKeyDeviceRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RegisterKeyDeviceRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.keys.v1'),
      createEmptyInstance: RegisterKeyDeviceRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'deviceId')
    ..a<$core.List<$core.int>>(
        3, _omitFieldNames ? '' : 'signaturePublicKey', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RegisterKeyDeviceRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RegisterKeyDeviceRequest copyWith(
          void Function(RegisterKeyDeviceRequest) updates) =>
      super.copyWith((message) => updates(message as RegisterKeyDeviceRequest))
          as RegisterKeyDeviceRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use RegisterKeyDeviceRequest() / RegisterKeyDeviceRequest.new instead')
  static RegisterKeyDeviceRequest create() => RegisterKeyDeviceRequest._();
  static $pb.GeneratedMessage $_createMessage() => RegisterKeyDeviceRequest._();
  @$core.override
  RegisterKeyDeviceRequest createEmptyInstance() =>
      RegisterKeyDeviceRequest._();
  @$core.pragma('dart2js:noInline')
  static RegisterKeyDeviceRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<RegisterKeyDeviceRequest>(
          RegisterKeyDeviceRequest.$_createMessage);
  static RegisterKeyDeviceRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get deviceId => $_getSZ(1);
  @$pb.TagNumber(2)
  set deviceId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasDeviceId() => $_has(1);
  @$pb.TagNumber(2)
  void clearDeviceId() => $_clearField(2);

  /// Exactly 32 bytes.
  @$pb.TagNumber(3)
  $core.List<$core.int> get signaturePublicKey => $_getN(2);
  @$pb.TagNumber(3)
  set signaturePublicKey($core.List<$core.int> value) => $_setBytes(2, value);
  @$pb.TagNumber(3)
  $core.bool hasSignaturePublicKey() => $_has(2);
  @$pb.TagNumber(3)
  void clearSignaturePublicKey() => $_clearField(3);
}

class RegisterKeyDeviceResponse extends $pb.GeneratedMessage {
  factory RegisterKeyDeviceResponse({
    KeyDevice? device,
  }) {
    final result = RegisterKeyDeviceResponse._();
    if (device != null) result.device = device;
    return result;
  }

  RegisterKeyDeviceResponse._();

  factory RegisterKeyDeviceResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RegisterKeyDeviceResponse()..mergeFromBuffer(data, registry);
  factory RegisterKeyDeviceResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RegisterKeyDeviceResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RegisterKeyDeviceResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.keys.v1'),
      createEmptyInstance: RegisterKeyDeviceResponse.$_createMessage)
    ..aOM<KeyDevice>(1, _omitFieldNames ? '' : 'device',
        subBuilder: KeyDevice.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RegisterKeyDeviceResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RegisterKeyDeviceResponse copyWith(
          void Function(RegisterKeyDeviceResponse) updates) =>
      super.copyWith((message) => updates(message as RegisterKeyDeviceResponse))
          as RegisterKeyDeviceResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use RegisterKeyDeviceResponse() / RegisterKeyDeviceResponse.new instead')
  static RegisterKeyDeviceResponse create() => RegisterKeyDeviceResponse._();
  static $pb.GeneratedMessage $_createMessage() =>
      RegisterKeyDeviceResponse._();
  @$core.override
  RegisterKeyDeviceResponse createEmptyInstance() =>
      RegisterKeyDeviceResponse._();
  @$core.pragma('dart2js:noInline')
  static RegisterKeyDeviceResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<RegisterKeyDeviceResponse>(
          RegisterKeyDeviceResponse.$_createMessage);
  static RegisterKeyDeviceResponse? _defaultInstance;

  @$pb.TagNumber(1)
  KeyDevice get device => $_getN(0);
  @$pb.TagNumber(1)
  set device(KeyDevice value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasDevice() => $_has(0);
  @$pb.TagNumber(1)
  void clearDevice() => $_clearField(1);
  @$pb.TagNumber(1)
  KeyDevice ensureDevice() => $_ensure(0);
}

class ListMyKeyDevicesRequest extends $pb.GeneratedMessage {
  factory ListMyKeyDevicesRequest() => ListMyKeyDevicesRequest._();

  ListMyKeyDevicesRequest._();

  factory ListMyKeyDevicesRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListMyKeyDevicesRequest()..mergeFromBuffer(data, registry);
  factory ListMyKeyDevicesRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListMyKeyDevicesRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListMyKeyDevicesRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.keys.v1'),
      createEmptyInstance: ListMyKeyDevicesRequest.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListMyKeyDevicesRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListMyKeyDevicesRequest copyWith(
          void Function(ListMyKeyDevicesRequest) updates) =>
      super.copyWith((message) => updates(message as ListMyKeyDevicesRequest))
          as ListMyKeyDevicesRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ListMyKeyDevicesRequest() / ListMyKeyDevicesRequest.new instead')
  static ListMyKeyDevicesRequest create() => ListMyKeyDevicesRequest._();
  static $pb.GeneratedMessage $_createMessage() => ListMyKeyDevicesRequest._();
  @$core.override
  ListMyKeyDevicesRequest createEmptyInstance() => ListMyKeyDevicesRequest._();
  @$core.pragma('dart2js:noInline')
  static ListMyKeyDevicesRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListMyKeyDevicesRequest>(
          ListMyKeyDevicesRequest.$_createMessage);
  static ListMyKeyDevicesRequest? _defaultInstance;
}

class ListMyKeyDevicesResponse extends $pb.GeneratedMessage {
  factory ListMyKeyDevicesResponse({
    $core.Iterable<KeyDevice>? devices,
  }) {
    final result = ListMyKeyDevicesResponse._();
    if (devices != null) result.devices.addAll(devices);
    return result;
  }

  ListMyKeyDevicesResponse._();

  factory ListMyKeyDevicesResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListMyKeyDevicesResponse()..mergeFromBuffer(data, registry);
  factory ListMyKeyDevicesResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListMyKeyDevicesResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListMyKeyDevicesResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.keys.v1'),
      createEmptyInstance: ListMyKeyDevicesResponse.$_createMessage)
    ..pPM<KeyDevice>(1, _omitFieldNames ? '' : 'devices',
        subBuilder: KeyDevice.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListMyKeyDevicesResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListMyKeyDevicesResponse copyWith(
          void Function(ListMyKeyDevicesResponse) updates) =>
      super.copyWith((message) => updates(message as ListMyKeyDevicesResponse))
          as ListMyKeyDevicesResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ListMyKeyDevicesResponse() / ListMyKeyDevicesResponse.new instead')
  static ListMyKeyDevicesResponse create() => ListMyKeyDevicesResponse._();
  static $pb.GeneratedMessage $_createMessage() => ListMyKeyDevicesResponse._();
  @$core.override
  ListMyKeyDevicesResponse createEmptyInstance() =>
      ListMyKeyDevicesResponse._();
  @$core.pragma('dart2js:noInline')
  static ListMyKeyDevicesResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListMyKeyDevicesResponse>(
          ListMyKeyDevicesResponse.$_createMessage);
  static ListMyKeyDevicesResponse? _defaultInstance;

  /// At most 5, oldest first; inactive ones included, flagged by last_seen_at.
  @$pb.TagNumber(1)
  $pb.PbList<KeyDevice> get devices => $_getList(0);
}

class RemoveKeyDeviceRequest extends $pb.GeneratedMessage {
  factory RemoveKeyDeviceRequest({
    $core.String? idempotencyKey,
    $core.String? deviceId,
  }) {
    final result = RemoveKeyDeviceRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (deviceId != null) result.deviceId = deviceId;
    return result;
  }

  RemoveKeyDeviceRequest._();

  factory RemoveKeyDeviceRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RemoveKeyDeviceRequest()..mergeFromBuffer(data, registry);
  factory RemoveKeyDeviceRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RemoveKeyDeviceRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RemoveKeyDeviceRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.keys.v1'),
      createEmptyInstance: RemoveKeyDeviceRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'deviceId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RemoveKeyDeviceRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RemoveKeyDeviceRequest copyWith(
          void Function(RemoveKeyDeviceRequest) updates) =>
      super.copyWith((message) => updates(message as RemoveKeyDeviceRequest))
          as RemoveKeyDeviceRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use RemoveKeyDeviceRequest() / RemoveKeyDeviceRequest.new instead')
  static RemoveKeyDeviceRequest create() => RemoveKeyDeviceRequest._();
  static $pb.GeneratedMessage $_createMessage() => RemoveKeyDeviceRequest._();
  @$core.override
  RemoveKeyDeviceRequest createEmptyInstance() => RemoveKeyDeviceRequest._();
  @$core.pragma('dart2js:noInline')
  static RemoveKeyDeviceRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<RemoveKeyDeviceRequest>(
          RemoveKeyDeviceRequest.$_createMessage);
  static RemoveKeyDeviceRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get deviceId => $_getSZ(1);
  @$pb.TagNumber(2)
  set deviceId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasDeviceId() => $_has(1);
  @$pb.TagNumber(2)
  void clearDeviceId() => $_clearField(2);
}

class RemoveKeyDeviceResponse extends $pb.GeneratedMessage {
  factory RemoveKeyDeviceResponse() => RemoveKeyDeviceResponse._();

  RemoveKeyDeviceResponse._();

  factory RemoveKeyDeviceResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RemoveKeyDeviceResponse()..mergeFromBuffer(data, registry);
  factory RemoveKeyDeviceResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RemoveKeyDeviceResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RemoveKeyDeviceResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.keys.v1'),
      createEmptyInstance: RemoveKeyDeviceResponse.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RemoveKeyDeviceResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RemoveKeyDeviceResponse copyWith(
          void Function(RemoveKeyDeviceResponse) updates) =>
      super.copyWith((message) => updates(message as RemoveKeyDeviceResponse))
          as RemoveKeyDeviceResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use RemoveKeyDeviceResponse() / RemoveKeyDeviceResponse.new instead')
  static RemoveKeyDeviceResponse create() => RemoveKeyDeviceResponse._();
  static $pb.GeneratedMessage $_createMessage() => RemoveKeyDeviceResponse._();
  @$core.override
  RemoveKeyDeviceResponse createEmptyInstance() => RemoveKeyDeviceResponse._();
  @$core.pragma('dart2js:noInline')
  static RemoveKeyDeviceResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<RemoveKeyDeviceResponse>(
          RemoveKeyDeviceResponse.$_createMessage);
  static RemoveKeyDeviceResponse? _defaultInstance;
}

class UploadKeyPackagesRequest extends $pb.GeneratedMessage {
  factory UploadKeyPackagesRequest({
    $core.String? idempotencyKey,
    $core.String? deviceId,
    $core.Iterable<$core.List<$core.int>>? keyPackages,
    $core.List<$core.int>? lastResortKeyPackage,
  }) {
    final result = UploadKeyPackagesRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (deviceId != null) result.deviceId = deviceId;
    if (keyPackages != null) result.keyPackages.addAll(keyPackages);
    if (lastResortKeyPackage != null)
      result.lastResortKeyPackage = lastResortKeyPackage;
    return result;
  }

  UploadKeyPackagesRequest._();

  factory UploadKeyPackagesRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UploadKeyPackagesRequest()..mergeFromBuffer(data, registry);
  factory UploadKeyPackagesRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UploadKeyPackagesRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'UploadKeyPackagesRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.keys.v1'),
      createEmptyInstance: UploadKeyPackagesRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'deviceId')
    ..p<$core.List<$core.int>>(
        3, _omitFieldNames ? '' : 'keyPackages', $pb.PbFieldType.PY)
    ..a<$core.List<$core.int>>(
        4, _omitFieldNames ? '' : 'lastResortKeyPackage', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UploadKeyPackagesRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UploadKeyPackagesRequest copyWith(
          void Function(UploadKeyPackagesRequest) updates) =>
      super.copyWith((message) => updates(message as UploadKeyPackagesRequest))
          as UploadKeyPackagesRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use UploadKeyPackagesRequest() / UploadKeyPackagesRequest.new instead')
  static UploadKeyPackagesRequest create() => UploadKeyPackagesRequest._();
  static $pb.GeneratedMessage $_createMessage() => UploadKeyPackagesRequest._();
  @$core.override
  UploadKeyPackagesRequest createEmptyInstance() =>
      UploadKeyPackagesRequest._();
  @$core.pragma('dart2js:noInline')
  static UploadKeyPackagesRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<UploadKeyPackagesRequest>(
          UploadKeyPackagesRequest.$_createMessage);
  static UploadKeyPackagesRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get deviceId => $_getSZ(1);
  @$pb.TagNumber(2)
  set deviceId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasDeviceId() => $_has(1);
  @$pb.TagNumber(2)
  void clearDeviceId() => $_clearField(2);

  /// 0-100, each 1-4096 bytes. Opaque to the server.
  @$pb.TagNumber(3)
  $pb.PbList<$core.List<$core.int>> get keyPackages => $_getList(2);

  /// Optional, 1-4096 bytes; replaces the stored one when set. Empty means none sent: the stored one is kept.
  @$pb.TagNumber(4)
  $core.List<$core.int> get lastResortKeyPackage => $_getN(3);
  @$pb.TagNumber(4)
  set lastResortKeyPackage($core.List<$core.int> value) => $_setBytes(3, value);
  @$pb.TagNumber(4)
  $core.bool hasLastResortKeyPackage() => $_has(3);
  @$pb.TagNumber(4)
  void clearLastResortKeyPackage() => $_clearField(4);
}

class UploadKeyPackagesResponse extends $pb.GeneratedMessage {
  factory UploadKeyPackagesResponse({
    $core.int? keyPackageCount,
    $core.bool? hasLastResort,
  }) {
    final result = UploadKeyPackagesResponse._();
    if (keyPackageCount != null) result.keyPackageCount = keyPackageCount;
    if (hasLastResort != null) result.hasLastResort = hasLastResort;
    return result;
  }

  UploadKeyPackagesResponse._();

  factory UploadKeyPackagesResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UploadKeyPackagesResponse()..mergeFromBuffer(data, registry);
  factory UploadKeyPackagesResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UploadKeyPackagesResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'UploadKeyPackagesResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.keys.v1'),
      createEmptyInstance: UploadKeyPackagesResponse.$_createMessage)
    ..aI(1, _omitFieldNames ? '' : 'keyPackageCount')
    ..aOB(2, _omitFieldNames ? '' : 'hasLastResort')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UploadKeyPackagesResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UploadKeyPackagesResponse copyWith(
          void Function(UploadKeyPackagesResponse) updates) =>
      super.copyWith((message) => updates(message as UploadKeyPackagesResponse))
          as UploadKeyPackagesResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use UploadKeyPackagesResponse() / UploadKeyPackagesResponse.new instead')
  static UploadKeyPackagesResponse create() => UploadKeyPackagesResponse._();
  static $pb.GeneratedMessage $_createMessage() =>
      UploadKeyPackagesResponse._();
  @$core.override
  UploadKeyPackagesResponse createEmptyInstance() =>
      UploadKeyPackagesResponse._();
  @$core.pragma('dart2js:noInline')
  static UploadKeyPackagesResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<UploadKeyPackagesResponse>(
          UploadKeyPackagesResponse.$_createMessage);
  static UploadKeyPackagesResponse? _defaultInstance;

  /// One-time packages in the pool after the upload.
  @$pb.TagNumber(1)
  $core.int get keyPackageCount => $_getIZ(0);
  @$pb.TagNumber(1)
  set keyPackageCount($core.int value) => $_setSignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasKeyPackageCount() => $_has(0);
  @$pb.TagNumber(1)
  void clearKeyPackageCount() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.bool get hasLastResort => $_getBF(1);
  @$pb.TagNumber(2)
  set hasLastResort($core.bool value) => $_setBool(1, value);
  @$pb.TagNumber(2)
  $core.bool hasHasLastResort() => $_has(1);
  @$pb.TagNumber(2)
  void clearHasLastResort() => $_clearField(2);
}

class GetKeyDevicesRequest extends $pb.GeneratedMessage {
  factory GetKeyDevicesRequest({
    $core.Iterable<$core.String>? userIds,
  }) {
    final result = GetKeyDevicesRequest._();
    if (userIds != null) result.userIds.addAll(userIds);
    return result;
  }

  GetKeyDevicesRequest._();

  factory GetKeyDevicesRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetKeyDevicesRequest()..mergeFromBuffer(data, registry);
  factory GetKeyDevicesRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetKeyDevicesRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetKeyDevicesRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.keys.v1'),
      createEmptyInstance: GetKeyDevicesRequest.$_createMessage)
    ..pPS(1, _omitFieldNames ? '' : 'userIds')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetKeyDevicesRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetKeyDevicesRequest copyWith(void Function(GetKeyDevicesRequest) updates) =>
      super.copyWith((message) => updates(message as GetKeyDevicesRequest))
          as GetKeyDevicesRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use GetKeyDevicesRequest() / GetKeyDevicesRequest.new instead')
  static GetKeyDevicesRequest create() => GetKeyDevicesRequest._();
  static $pb.GeneratedMessage $_createMessage() => GetKeyDevicesRequest._();
  @$core.override
  GetKeyDevicesRequest createEmptyInstance() => GetKeyDevicesRequest._();
  @$core.pragma('dart2js:noInline')
  static GetKeyDevicesRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<GetKeyDevicesRequest>(
          GetKeyDevicesRequest.$_createMessage);
  static GetKeyDevicesRequest? _defaultInstance;

  /// 1-10; the caller's own id is allowed. A user reference: translated to and from the public id like every other
  /// user id on the wire (options.proto, user_ref).
  @$pb.TagNumber(1)
  $pb.PbList<$core.String> get userIds => $_getList(0);
}

class UserKeyDevices extends $pb.GeneratedMessage {
  factory UserKeyDevices({
    $core.String? userId,
    $core.Iterable<KeyDevice>? devices,
  }) {
    final result = UserKeyDevices._();
    if (userId != null) result.userId = userId;
    if (devices != null) result.devices.addAll(devices);
    return result;
  }

  UserKeyDevices._();

  factory UserKeyDevices.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UserKeyDevices()..mergeFromBuffer(data, registry);
  factory UserKeyDevices.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UserKeyDevices()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'UserKeyDevices',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.keys.v1'),
      createEmptyInstance: UserKeyDevices.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'userId')
    ..pPM<KeyDevice>(2, _omitFieldNames ? '' : 'devices',
        subBuilder: KeyDevice.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UserKeyDevices clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UserKeyDevices copyWith(void Function(UserKeyDevices) updates) =>
      super.copyWith((message) => updates(message as UserKeyDevices))
          as UserKeyDevices;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use UserKeyDevices() / UserKeyDevices.new instead')
  static UserKeyDevices create() => UserKeyDevices._();
  static $pb.GeneratedMessage $_createMessage() => UserKeyDevices._();
  @$core.override
  UserKeyDevices createEmptyInstance() => UserKeyDevices._();
  @$core.pragma('dart2js:noInline')
  static UserKeyDevices getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<UserKeyDevices>(
          UserKeyDevices.$_createMessage);
  static UserKeyDevices? _defaultInstance;

  /// A user reference, translated like the others (options.proto, user_ref).
  @$pb.TagNumber(1)
  $core.String get userId => $_getSZ(0);
  @$pb.TagNumber(1)
  set userId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasUserId() => $_has(0);
  @$pb.TagNumber(1)
  void clearUserId() => $_clearField(1);

  /// Active devices only.
  @$pb.TagNumber(2)
  $pb.PbList<KeyDevice> get devices => $_getList(1);
}

class GetKeyDevicesResponse extends $pb.GeneratedMessage {
  factory GetKeyDevicesResponse({
    $core.Iterable<UserKeyDevices>? users,
  }) {
    final result = GetKeyDevicesResponse._();
    if (users != null) result.users.addAll(users);
    return result;
  }

  GetKeyDevicesResponse._();

  factory GetKeyDevicesResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetKeyDevicesResponse()..mergeFromBuffer(data, registry);
  factory GetKeyDevicesResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetKeyDevicesResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetKeyDevicesResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.keys.v1'),
      createEmptyInstance: GetKeyDevicesResponse.$_createMessage)
    ..pPM<UserKeyDevices>(1, _omitFieldNames ? '' : 'users',
        subBuilder: UserKeyDevices.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetKeyDevicesResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetKeyDevicesResponse copyWith(
          void Function(GetKeyDevicesResponse) updates) =>
      super.copyWith((message) => updates(message as GetKeyDevicesResponse))
          as GetKeyDevicesResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use GetKeyDevicesResponse() / GetKeyDevicesResponse.new instead')
  static GetKeyDevicesResponse create() => GetKeyDevicesResponse._();
  static $pb.GeneratedMessage $_createMessage() => GetKeyDevicesResponse._();
  @$core.override
  GetKeyDevicesResponse createEmptyInstance() => GetKeyDevicesResponse._();
  @$core.pragma('dart2js:noInline')
  static GetKeyDevicesResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<GetKeyDevicesResponse>(
          GetKeyDevicesResponse.$_createMessage);
  static GetKeyDevicesResponse? _defaultInstance;

  /// Same order as the request, one entry per requested id (with no devices when the user has none to return).
  @$pb.TagNumber(1)
  $pb.PbList<UserKeyDevices> get users => $_getList(0);
}

class ClaimKeyPackagesRequest extends $pb.GeneratedMessage {
  factory ClaimKeyPackagesRequest({
    $core.String? idempotencyKey,
    $core.String? userId,
    $core.String? excludeDeviceId,
  }) {
    final result = ClaimKeyPackagesRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (userId != null) result.userId = userId;
    if (excludeDeviceId != null) result.excludeDeviceId = excludeDeviceId;
    return result;
  }

  ClaimKeyPackagesRequest._();

  factory ClaimKeyPackagesRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ClaimKeyPackagesRequest()..mergeFromBuffer(data, registry);
  factory ClaimKeyPackagesRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ClaimKeyPackagesRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ClaimKeyPackagesRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.keys.v1'),
      createEmptyInstance: ClaimKeyPackagesRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'userId')
    ..aOS(3, _omitFieldNames ? '' : 'excludeDeviceId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ClaimKeyPackagesRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ClaimKeyPackagesRequest copyWith(
          void Function(ClaimKeyPackagesRequest) updates) =>
      super.copyWith((message) => updates(message as ClaimKeyPackagesRequest))
          as ClaimKeyPackagesRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ClaimKeyPackagesRequest() / ClaimKeyPackagesRequest.new instead')
  static ClaimKeyPackagesRequest create() => ClaimKeyPackagesRequest._();
  static $pb.GeneratedMessage $_createMessage() => ClaimKeyPackagesRequest._();
  @$core.override
  ClaimKeyPackagesRequest createEmptyInstance() => ClaimKeyPackagesRequest._();
  @$core.pragma('dart2js:noInline')
  static ClaimKeyPackagesRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ClaimKeyPackagesRequest>(
          ClaimKeyPackagesRequest.$_createMessage);
  static ClaimKeyPackagesRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  /// A user reference, translated like the others (options.proto, user_ref).
  @$pb.TagNumber(2)
  $core.String get userId => $_getSZ(1);
  @$pb.TagNumber(2)
  set userId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasUserId() => $_has(1);
  @$pb.TagNumber(2)
  void clearUserId() => $_clearField(2);

  /// Lets a device claim for its own user's other devices without consuming its own package. Required when user_id is
  /// the caller, and then must be one of the caller's devices (an inactive one included). For another user it must be
  /// empty or a well-formed device id (else VALIDATION "exclude_device_id") and is ignored.
  @$pb.TagNumber(3)
  $core.String get excludeDeviceId => $_getSZ(2);
  @$pb.TagNumber(3)
  set excludeDeviceId($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasExcludeDeviceId() => $_has(2);
  @$pb.TagNumber(3)
  void clearExcludeDeviceId() => $_clearField(3);
}

class ClaimedKeyPackage extends $pb.GeneratedMessage {
  factory ClaimedKeyPackage({
    $core.String? deviceId,
    $core.List<$core.int>? signaturePublicKey,
    $core.List<$core.int>? keyPackage,
    $core.bool? hasKeyPackage_4,
    $core.bool? lastResort,
  }) {
    final result = ClaimedKeyPackage._();
    if (deviceId != null) result.deviceId = deviceId;
    if (signaturePublicKey != null)
      result.signaturePublicKey = signaturePublicKey;
    if (keyPackage != null) result.keyPackage = keyPackage;
    if (hasKeyPackage_4 != null) result.hasKeyPackage_4 = hasKeyPackage_4;
    if (lastResort != null) result.lastResort = lastResort;
    return result;
  }

  ClaimedKeyPackage._();

  factory ClaimedKeyPackage.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ClaimedKeyPackage()..mergeFromBuffer(data, registry);
  factory ClaimedKeyPackage.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ClaimedKeyPackage()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ClaimedKeyPackage',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.keys.v1'),
      createEmptyInstance: ClaimedKeyPackage.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'deviceId')
    ..a<$core.List<$core.int>>(
        2, _omitFieldNames ? '' : 'signaturePublicKey', $pb.PbFieldType.OY)
    ..a<$core.List<$core.int>>(
        3, _omitFieldNames ? '' : 'keyPackage', $pb.PbFieldType.OY)
    ..aOB(4, _omitFieldNames ? '' : 'hasKeyPackage')
    ..aOB(5, _omitFieldNames ? '' : 'lastResort')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ClaimedKeyPackage clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ClaimedKeyPackage copyWith(void Function(ClaimedKeyPackage) updates) =>
      super.copyWith((message) => updates(message as ClaimedKeyPackage))
          as ClaimedKeyPackage;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use ClaimedKeyPackage() / ClaimedKeyPackage.new instead')
  static ClaimedKeyPackage create() => ClaimedKeyPackage._();
  static $pb.GeneratedMessage $_createMessage() => ClaimedKeyPackage._();
  @$core.override
  ClaimedKeyPackage createEmptyInstance() => ClaimedKeyPackage._();
  @$core.pragma('dart2js:noInline')
  static ClaimedKeyPackage getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<ClaimedKeyPackage>(
          ClaimedKeyPackage.$_createMessage);
  static ClaimedKeyPackage? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get deviceId => $_getSZ(0);
  @$pb.TagNumber(1)
  set deviceId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasDeviceId() => $_has(0);
  @$pb.TagNumber(1)
  void clearDeviceId() => $_clearField(1);

  /// The device's key as the directory held it just before the package was taken. It can be stale if the device id was
  /// removed and registered again in that instant, so the client checks the key package's credential and signature key
  /// against it and against the directory entry, and skips the device on a mismatch (see the file header).
  @$pb.TagNumber(2)
  $core.List<$core.int> get signaturePublicKey => $_getN(1);
  @$pb.TagNumber(2)
  set signaturePublicKey($core.List<$core.int> value) => $_setBytes(1, value);
  @$pb.TagNumber(2)
  $core.bool hasSignaturePublicKey() => $_has(1);
  @$pb.TagNumber(2)
  void clearSignaturePublicKey() => $_clearField(2);

  /// Empty when has_key_package is false.
  @$pb.TagNumber(3)
  $core.List<$core.int> get keyPackage => $_getN(2);
  @$pb.TagNumber(3)
  set keyPackage($core.List<$core.int> value) => $_setBytes(2, value);
  @$pb.TagNumber(3)
  $core.bool hasKeyPackage() => $_has(2);
  @$pb.TagNumber(3)
  void clearKeyPackage() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.bool get hasKeyPackage_4 => $_getBF(3);
  @$pb.TagNumber(4)
  set hasKeyPackage_4($core.bool value) => $_setBool(3, value);
  @$pb.TagNumber(4)
  $core.bool hasHasKeyPackage_4() => $_has(3);
  @$pb.TagNumber(4)
  void clearHasKeyPackage_4() => $_clearField(4);

  /// True when key_package is the device's last-resort package (reusable, not consumed).
  @$pb.TagNumber(5)
  $core.bool get lastResort => $_getBF(4);
  @$pb.TagNumber(5)
  set lastResort($core.bool value) => $_setBool(4, value);
  @$pb.TagNumber(5)
  $core.bool hasLastResort() => $_has(4);
  @$pb.TagNumber(5)
  void clearLastResort() => $_clearField(5);
}

class ClaimKeyPackagesResponse extends $pb.GeneratedMessage {
  factory ClaimKeyPackagesResponse({
    $core.Iterable<ClaimedKeyPackage>? keyPackages,
  }) {
    final result = ClaimKeyPackagesResponse._();
    if (keyPackages != null) result.keyPackages.addAll(keyPackages);
    return result;
  }

  ClaimKeyPackagesResponse._();

  factory ClaimKeyPackagesResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ClaimKeyPackagesResponse()..mergeFromBuffer(data, registry);
  factory ClaimKeyPackagesResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ClaimKeyPackagesResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ClaimKeyPackagesResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.keys.v1'),
      createEmptyInstance: ClaimKeyPackagesResponse.$_createMessage)
    ..pPM<ClaimedKeyPackage>(1, _omitFieldNames ? '' : 'keyPackages',
        subBuilder: ClaimedKeyPackage.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ClaimKeyPackagesResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ClaimKeyPackagesResponse copyWith(
          void Function(ClaimKeyPackagesResponse) updates) =>
      super.copyWith((message) => updates(message as ClaimKeyPackagesResponse))
          as ClaimKeyPackagesResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ClaimKeyPackagesResponse() / ClaimKeyPackagesResponse.new instead')
  static ClaimKeyPackagesResponse create() => ClaimKeyPackagesResponse._();
  static $pb.GeneratedMessage $_createMessage() => ClaimKeyPackagesResponse._();
  @$core.override
  ClaimKeyPackagesResponse createEmptyInstance() =>
      ClaimKeyPackagesResponse._();
  @$core.pragma('dart2js:noInline')
  static ClaimKeyPackagesResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ClaimKeyPackagesResponse>(
          ClaimKeyPackagesResponse.$_createMessage);
  static ClaimKeyPackagesResponse? _defaultInstance;

  /// One per active device of user_id, oldest first, except: a device removed during the claim is left out, and for
  /// the caller's own id the excluded device is left out.
  @$pb.TagNumber(1)
  $pb.PbList<ClaimedKeyPackage> get keyPackages => $_getList(0);
}

class KeyServiceApi {
  final $pb.RpcClient _client;

  KeyServiceApi(this._client);

  /// Publish the caller's encryption device. Needs the flag on for the caller. Naturally idempotent by device_id:
  /// same id and same key => refreshes last_seen_at (at most once per 24 h) and returns the device; same id with a
  /// different key => INVALID_ARGUMENT + VALIDATION "signature_public_key"; a sixth device => FAILED_PRECONDITION +
  /// LIMIT_REACHED "key_devices" (never evicts). Validation: device_id and signature_public_key as in the header,
  /// idempotency_key format. One transaction: 1 device read + a query of at most 6 device documents, 1 write.
  $async.Future<RegisterKeyDeviceResponse> registerKeyDevice(
          $pb.ClientContext? ctx, RegisterKeyDeviceRequest request) =>
      _client.invoke<RegisterKeyDeviceResponse>(ctx, 'KeyService',
          'RegisterKeyDevice', request, RegisterKeyDeviceResponse());

  /// The caller's devices, at most 5, oldest first; inactive ones (not seen for 30 days) are included, flagged by
  /// last_seen_at. Needs the flag only not globally off. Query of at most 5 device documents (Limit 5).
  $async.Future<ListMyKeyDevicesResponse> listMyKeyDevices(
          $pb.ClientContext? ctx, ListMyKeyDevicesRequest request) =>
      _client.invoke<ListMyKeyDevicesResponse>(ctx, 'KeyService',
          'ListMyKeyDevices', request, ListMyKeyDevicesResponse());

  /// Remove one of the caller's devices together with its key package pool and its last-resort package. A missing
  /// device is success (idempotent). Needs the flag only not globally off. Validation: device_id format,
  /// idempotency_key format. Bounded delete of the device document and at most 100 pool documents.
  $async.Future<RemoveKeyDeviceResponse> removeKeyDevice(
          $pb.ClientContext? ctx, RemoveKeyDeviceRequest request) =>
      _client.invoke<RemoveKeyDeviceResponse>(ctx, 'KeyService',
          'RemoveKeyDevice', request, RemoveKeyDeviceResponse());

  /// Add key packages to a registered device's pool and optionally replace its last-resort package. Needs the flag on
  /// for the caller. Naturally idempotent: a key package's document id is derived from its bytes, so a replay stores
  /// nothing twice, and duplicates within one request are stored once. The pool holds at most 100: packages beyond the
  /// free space are dropped: when the pool is full the oldest stay and the new packages are not stored (the response
  /// carries the resulting count, which can be momentarily higher than the pool if a claim runs concurrently). An empty
  /// last_resort_key_package means none sent: the stored one is kept. Unknown device => NOT_FOUND. Neither key packages
  /// nor a last-resort package => VALIDATION "key_packages". Marks the device seen (at most once per 24 h). One
  /// transaction: 1 device read + at most 100 reads, at most 101 writes.
  $async.Future<UploadKeyPackagesResponse> uploadKeyPackages(
          $pb.ClientContext? ctx, UploadKeyPackagesRequest request) =>
      _client.invoke<UploadKeyPackagesResponse>(ctx, 'KeyService',
          'UploadKeyPackages', request, UploadKeyPackagesResponse());

  /// Active devices of up to 10 users. Needs the flag on for the caller. For each target other than the caller, the
  /// caller must be allowed to message the target by the messaging send rules; an unknown or non-ACTIVE user, a block in
  /// either direction and any other refusal answer ONE byte-identical FAILED_PRECONDITION + CANNOT_MESSAGE. A target
  /// with the flag off or with no active device answers success with an empty device list. One refused target fails the
  /// whole call with that single CANNOT_MESSAGE (no partial result). Only active devices are returned, oldest first;
  /// key_package_count and has_last_resort are zeroed for other users' devices. Validation: 1-10 user_ids, each a
  /// well-formed user id, no duplicates (the caller's own id twice included), else VALIDATION "user_ids". Reads: for
  /// each target other than the caller, the send-rules check reads at most 4 documents, all cache-first (the caller's
  /// graph, the target's profile and, only when the target accepts messages from accounts they follow, one follow edge
  /// and the conversation); then at most 10 queries of at most 5 devices (the caller and each permitted target with the
  /// flag on: nothing is read for a refused or flag-off target). No writes.
  $async.Future<GetKeyDevicesResponse> getKeyDevices(
          $pb.ClientContext? ctx, GetKeyDevicesRequest request) =>
      _client.invoke<GetKeyDevicesResponse>(
          ctx, 'KeyService', 'GetKeyDevices', request, GetKeyDevicesResponse());

  /// Claim one key package per active device of user_id, devices oldest first. Needs the flag on for the caller. Same
  /// send-rules check and the same single CANNOT_MESSAGE refusal as GetKeyDevices; a target with the flag off is an
  /// empty success; a malformed user_id is VALIDATION "user_id". For each active device the server consumes one
  /// one-time package (which one is unspecified), else returns the device's last-resort package (last_resort = true,
  /// not consumed), else has_key_package = false. Under heavy contention on one device the last-resort package (or
  /// has_key_package = false) may be returned although one-time packages remain; contention is never an error. A
  /// returned last-resort package may be one the device replaced a moment earlier (a stale read in a millisecond
  /// window); the receiving device may then be unable to use it, and the sender should claim again.
  /// There is no transaction: per device, one atomic write deletes one one-time package and decrements the count. Not
  /// atomic across devices. Reads without contention: at most 15 (1 query of at most 5 devices + 1 or 2 pool queries of
  /// at most 1 document per device); with contention at most 110 (at most 10 picks per device, 2 pool queries each, plus
  /// 1 device read); plus the send-rules check's at most 4 for another user. At most 10 committed writes.
  /// NOT replayable: a retry consumes fresh packages, and idempotency_key is format-checked only. A failed or timed-out
  /// call is not proof that nothing was consumed: packages may already have been taken, including for earlier devices
  /// of the same call when a later device fails. Claiming for the caller's own user id requires exclude_device_id to be
  /// one of the caller's devices, an inactive one included (VALIDATION "exclude_device_id"); that device is left out.
  /// For another user exclude_device_id must be empty or a well-formed device id (VALIDATION "exclude_device_id") and
  /// is ignored. Limited by RATE_LIMIT_KEYS_CLAIM_PER_MIN and the daily cap KEYS_CLAIMS_PER_DAY (see Errors).
  $async.Future<ClaimKeyPackagesResponse> claimKeyPackages(
          $pb.ClientContext? ctx, ClaimKeyPackagesRequest request) =>
      _client.invoke<ClaimKeyPackagesResponse>(ctx, 'KeyService',
          'ClaimKeyPackages', request, ClaimKeyPackagesResponse());
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
