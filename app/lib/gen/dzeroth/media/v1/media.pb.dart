// This is a generated file - do not edit.
//
// Generated from dzeroth/media/v1/media.proto.

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

import '../../common/v1/common.pb.dart' as $1;
import 'media.pbenum.dart';

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

export 'media.pbenum.dart';

class UploadItem extends $pb.GeneratedMessage {
  factory UploadItem({
    $core.String? contentType,
    $fixnum.Int64? fullSizeBytes,
    $fixnum.Int64? thumbSizeBytes,
    $core.int? width,
    $core.int? height,
    $core.String? fullMd5,
    $core.String? thumbMd5,
  }) {
    final result = UploadItem._();
    if (contentType != null) result.contentType = contentType;
    if (fullSizeBytes != null) result.fullSizeBytes = fullSizeBytes;
    if (thumbSizeBytes != null) result.thumbSizeBytes = thumbSizeBytes;
    if (width != null) result.width = width;
    if (height != null) result.height = height;
    if (fullMd5 != null) result.fullMd5 = fullMd5;
    if (thumbMd5 != null) result.thumbMd5 = thumbMd5;
    return result;
  }

  UploadItem._();

  factory UploadItem.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UploadItem()..mergeFromBuffer(data, registry);
  factory UploadItem.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UploadItem()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'UploadItem',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.media.v1'),
      createEmptyInstance: UploadItem.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'contentType')
    ..aInt64(2, _omitFieldNames ? '' : 'fullSizeBytes')
    ..aInt64(3, _omitFieldNames ? '' : 'thumbSizeBytes')
    ..aI(4, _omitFieldNames ? '' : 'width')
    ..aI(5, _omitFieldNames ? '' : 'height')
    ..aOS(6, _omitFieldNames ? '' : 'fullMd5')
    ..aOS(7, _omitFieldNames ? '' : 'thumbMd5')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UploadItem clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UploadItem copyWith(void Function(UploadItem) updates) =>
      super.copyWith((message) => updates(message as UploadItem)) as UploadItem;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use UploadItem() / UploadItem.new instead')
  static UploadItem create() => UploadItem._();
  static $pb.GeneratedMessage $_createMessage() => UploadItem._();
  @$core.override
  UploadItem createEmptyInstance() => UploadItem._();
  @$core.pragma('dart2js:noInline')
  static UploadItem getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<UploadItem>(UploadItem.$_createMessage);
  static UploadItem? _defaultInstance;

  /// image/webp or image/jpeg (client re-encodes everything else on device).
  @$pb.TagNumber(1)
  $core.String get contentType => $_getSZ(0);
  @$pb.TagNumber(1)
  set contentType($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasContentType() => $_has(0);
  @$pb.TagNumber(1)
  void clearContentType() => $_clearField(1);

  @$pb.TagNumber(2)
  $fixnum.Int64 get fullSizeBytes => $_getI64(1);
  @$pb.TagNumber(2)
  set fullSizeBytes($fixnum.Int64 value) => $_setInt64(1, value);
  @$pb.TagNumber(2)
  $core.bool hasFullSizeBytes() => $_has(1);
  @$pb.TagNumber(2)
  void clearFullSizeBytes() => $_clearField(2);

  @$pb.TagNumber(3)
  $fixnum.Int64 get thumbSizeBytes => $_getI64(2);
  @$pb.TagNumber(3)
  set thumbSizeBytes($fixnum.Int64 value) => $_setInt64(2, value);
  @$pb.TagNumber(3)
  $core.bool hasThumbSizeBytes() => $_has(2);
  @$pb.TagNumber(3)
  void clearThumbSizeBytes() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.int get width => $_getIZ(3);
  @$pb.TagNumber(4)
  set width($core.int value) => $_setSignedInt32(3, value);
  @$pb.TagNumber(4)
  $core.bool hasWidth() => $_has(3);
  @$pb.TagNumber(4)
  void clearWidth() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.int get height => $_getIZ(4);
  @$pb.TagNumber(5)
  set height($core.int value) => $_setSignedInt32(4, value);
  @$pb.TagNumber(5)
  $core.bool hasHeight() => $_has(4);
  @$pb.TagNumber(5)
  void clearHeight() => $_clearField(5);

  /// Base64 MD5 of each file; bound into the signed URL so GCS rejects altered bytes.
  @$pb.TagNumber(6)
  $core.String get fullMd5 => $_getSZ(5);
  @$pb.TagNumber(6)
  set fullMd5($core.String value) => $_setString(5, value);
  @$pb.TagNumber(6)
  $core.bool hasFullMd5() => $_has(5);
  @$pb.TagNumber(6)
  void clearFullMd5() => $_clearField(6);

  @$pb.TagNumber(7)
  $core.String get thumbMd5 => $_getSZ(6);
  @$pb.TagNumber(7)
  set thumbMd5($core.String value) => $_setString(6, value);
  @$pb.TagNumber(7)
  $core.bool hasThumbMd5() => $_has(6);
  @$pb.TagNumber(7)
  void clearThumbMd5() => $_clearField(7);
}

class SignedUpload extends $pb.GeneratedMessage {
  factory SignedUpload({
    $core.String? url,
    $core.String? method,
    $core.Iterable<$core.MapEntry<$core.String, $core.String>>? headers,
    $0.Timestamp? expiresAt,
  }) {
    final result = SignedUpload._();
    if (url != null) result.url = url;
    if (method != null) result.method = method;
    if (headers != null) result.headers.addEntries(headers);
    if (expiresAt != null) result.expiresAt = expiresAt;
    return result;
  }

  SignedUpload._();

  factory SignedUpload.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SignedUpload()..mergeFromBuffer(data, registry);
  factory SignedUpload.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SignedUpload()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'SignedUpload',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.media.v1'),
      createEmptyInstance: SignedUpload.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'url')
    ..aOS(2, _omitFieldNames ? '' : 'method')
    ..m<$core.String, $core.String>(3, _omitFieldNames ? '' : 'headers',
        entryClassName: 'SignedUpload.HeadersEntry',
        keyFieldType: $pb.PbFieldType.OS,
        valueFieldType: $pb.PbFieldType.OS,
        packageName: const $pb.PackageName('dzeroth.media.v1'))
    ..aOM<$0.Timestamp>(4, _omitFieldNames ? '' : 'expiresAt',
        subBuilder: $0.Timestamp.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SignedUpload clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SignedUpload copyWith(void Function(SignedUpload) updates) =>
      super.copyWith((message) => updates(message as SignedUpload))
          as SignedUpload;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use SignedUpload() / SignedUpload.new instead')
  static SignedUpload create() => SignedUpload._();
  static $pb.GeneratedMessage $_createMessage() => SignedUpload._();
  @$core.override
  SignedUpload createEmptyInstance() => SignedUpload._();
  @$core.pragma('dart2js:noInline')
  static SignedUpload getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<SignedUpload>(
          SignedUpload.$_createMessage);
  static SignedUpload? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get url => $_getSZ(0);
  @$pb.TagNumber(1)
  set url($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasUrl() => $_has(0);
  @$pb.TagNumber(1)
  void clearUrl() => $_clearField(1);

  /// Always "PUT".
  @$pb.TagNumber(2)
  $core.String get method => $_getSZ(1);
  @$pb.TagNumber(2)
  set method($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasMethod() => $_has(1);
  @$pb.TagNumber(2)
  void clearMethod() => $_clearField(2);

  /// Headers the client MUST send exactly (Content-Type, Content-MD5, x-goog-content-length-range).
  @$pb.TagNumber(3)
  $pb.PbMap<$core.String, $core.String> get headers => $_getMap(2);

  @$pb.TagNumber(4)
  $0.Timestamp get expiresAt => $_getN(3);
  @$pb.TagNumber(4)
  set expiresAt($0.Timestamp value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasExpiresAt() => $_has(3);
  @$pb.TagNumber(4)
  void clearExpiresAt() => $_clearField(4);
  @$pb.TagNumber(4)
  $0.Timestamp ensureExpiresAt() => $_ensure(3);
}

class UploadTarget extends $pb.GeneratedMessage {
  factory UploadTarget({
    $core.String? mediaId,
    SignedUpload? full,
    SignedUpload? thumb,
  }) {
    final result = UploadTarget._();
    if (mediaId != null) result.mediaId = mediaId;
    if (full != null) result.full = full;
    if (thumb != null) result.thumb = thumb;
    return result;
  }

  UploadTarget._();

  factory UploadTarget.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UploadTarget()..mergeFromBuffer(data, registry);
  factory UploadTarget.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UploadTarget()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'UploadTarget',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.media.v1'),
      createEmptyInstance: UploadTarget.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'mediaId')
    ..aOM<SignedUpload>(2, _omitFieldNames ? '' : 'full',
        subBuilder: SignedUpload.$_createMessage)
    ..aOM<SignedUpload>(3, _omitFieldNames ? '' : 'thumb',
        subBuilder: SignedUpload.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UploadTarget clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UploadTarget copyWith(void Function(UploadTarget) updates) =>
      super.copyWith((message) => updates(message as UploadTarget))
          as UploadTarget;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use UploadTarget() / UploadTarget.new instead')
  static UploadTarget create() => UploadTarget._();
  static $pb.GeneratedMessage $_createMessage() => UploadTarget._();
  @$core.override
  UploadTarget createEmptyInstance() => UploadTarget._();
  @$core.pragma('dart2js:noInline')
  static UploadTarget getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<UploadTarget>(
          UploadTarget.$_createMessage);
  static UploadTarget? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get mediaId => $_getSZ(0);
  @$pb.TagNumber(1)
  set mediaId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasMediaId() => $_has(0);
  @$pb.TagNumber(1)
  void clearMediaId() => $_clearField(1);

  @$pb.TagNumber(2)
  SignedUpload get full => $_getN(1);
  @$pb.TagNumber(2)
  set full(SignedUpload value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasFull() => $_has(1);
  @$pb.TagNumber(2)
  void clearFull() => $_clearField(2);
  @$pb.TagNumber(2)
  SignedUpload ensureFull() => $_ensure(1);

  @$pb.TagNumber(3)
  SignedUpload get thumb => $_getN(2);
  @$pb.TagNumber(3)
  set thumb(SignedUpload value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasThumb() => $_has(2);
  @$pb.TagNumber(3)
  void clearThumb() => $_clearField(3);
  @$pb.TagNumber(3)
  SignedUpload ensureThumb() => $_ensure(2);
}

class CreateUploadRequest extends $pb.GeneratedMessage {
  factory CreateUploadRequest({
    $core.String? idempotencyKey,
    MediaPurpose? purpose,
    $core.Iterable<UploadItem>? items,
  }) {
    final result = CreateUploadRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (purpose != null) result.purpose = purpose;
    if (items != null) result.items.addAll(items);
    return result;
  }

  CreateUploadRequest._();

  factory CreateUploadRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CreateUploadRequest()..mergeFromBuffer(data, registry);
  factory CreateUploadRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CreateUploadRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CreateUploadRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.media.v1'),
      createEmptyInstance: CreateUploadRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aE<MediaPurpose>(2, _omitFieldNames ? '' : 'purpose',
        enumValues: MediaPurpose.values)
    ..pPM<UploadItem>(3, _omitFieldNames ? '' : 'items',
        subBuilder: UploadItem.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateUploadRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateUploadRequest copyWith(void Function(CreateUploadRequest) updates) =>
      super.copyWith((message) => updates(message as CreateUploadRequest))
          as CreateUploadRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core
      .Deprecated('Use CreateUploadRequest() / CreateUploadRequest.new instead')
  static CreateUploadRequest create() => CreateUploadRequest._();
  static $pb.GeneratedMessage $_createMessage() => CreateUploadRequest._();
  @$core.override
  CreateUploadRequest createEmptyInstance() => CreateUploadRequest._();
  @$core.pragma('dart2js:noInline')
  static CreateUploadRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<CreateUploadRequest>(
          CreateUploadRequest.$_createMessage);
  static CreateUploadRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  @$pb.TagNumber(2)
  MediaPurpose get purpose => $_getN(1);
  @$pb.TagNumber(2)
  set purpose(MediaPurpose value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasPurpose() => $_has(1);
  @$pb.TagNumber(2)
  void clearPurpose() => $_clearField(2);

  /// 1-4 items (exactly 1 for AVATAR).
  @$pb.TagNumber(3)
  $pb.PbList<UploadItem> get items => $_getList(2);
}

class CreateUploadResponse extends $pb.GeneratedMessage {
  factory CreateUploadResponse({
    $core.Iterable<UploadTarget>? targets,
  }) {
    final result = CreateUploadResponse._();
    if (targets != null) result.targets.addAll(targets);
    return result;
  }

  CreateUploadResponse._();

  factory CreateUploadResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CreateUploadResponse()..mergeFromBuffer(data, registry);
  factory CreateUploadResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CreateUploadResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CreateUploadResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.media.v1'),
      createEmptyInstance: CreateUploadResponse.$_createMessage)
    ..pPM<UploadTarget>(1, _omitFieldNames ? '' : 'targets',
        subBuilder: UploadTarget.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateUploadResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateUploadResponse copyWith(void Function(CreateUploadResponse) updates) =>
      super.copyWith((message) => updates(message as CreateUploadResponse))
          as CreateUploadResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use CreateUploadResponse() / CreateUploadResponse.new instead')
  static CreateUploadResponse create() => CreateUploadResponse._();
  static $pb.GeneratedMessage $_createMessage() => CreateUploadResponse._();
  @$core.override
  CreateUploadResponse createEmptyInstance() => CreateUploadResponse._();
  @$core.pragma('dart2js:noInline')
  static CreateUploadResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<CreateUploadResponse>(
          CreateUploadResponse.$_createMessage);
  static CreateUploadResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<UploadTarget> get targets => $_getList(0);
}

class FinalizeItem extends $pb.GeneratedMessage {
  factory FinalizeItem({
    $core.String? mediaId,
    $core.String? blurhash,
  }) {
    final result = FinalizeItem._();
    if (mediaId != null) result.mediaId = mediaId;
    if (blurhash != null) result.blurhash = blurhash;
    return result;
  }

  FinalizeItem._();

  factory FinalizeItem.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      FinalizeItem()..mergeFromBuffer(data, registry);
  factory FinalizeItem.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      FinalizeItem()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'FinalizeItem',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.media.v1'),
      createEmptyInstance: FinalizeItem.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'mediaId')
    ..aOS(2, _omitFieldNames ? '' : 'blurhash')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FinalizeItem clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FinalizeItem copyWith(void Function(FinalizeItem) updates) =>
      super.copyWith((message) => updates(message as FinalizeItem))
          as FinalizeItem;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use FinalizeItem() / FinalizeItem.new instead')
  static FinalizeItem create() => FinalizeItem._();
  static $pb.GeneratedMessage $_createMessage() => FinalizeItem._();
  @$core.override
  FinalizeItem createEmptyInstance() => FinalizeItem._();
  @$core.pragma('dart2js:noInline')
  static FinalizeItem getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<FinalizeItem>(
          FinalizeItem.$_createMessage);
  static FinalizeItem? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get mediaId => $_getSZ(0);
  @$pb.TagNumber(1)
  set mediaId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasMediaId() => $_has(0);
  @$pb.TagNumber(1)
  void clearMediaId() => $_clearField(1);

  /// BlurHash computed on device; <= 64 chars, base83 charset.
  @$pb.TagNumber(2)
  $core.String get blurhash => $_getSZ(1);
  @$pb.TagNumber(2)
  set blurhash($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasBlurhash() => $_has(1);
  @$pb.TagNumber(2)
  void clearBlurhash() => $_clearField(2);
}

class FinalizeUploadRequest extends $pb.GeneratedMessage {
  factory FinalizeUploadRequest({
    $core.String? idempotencyKey,
    $core.Iterable<FinalizeItem>? items,
  }) {
    final result = FinalizeUploadRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (items != null) result.items.addAll(items);
    return result;
  }

  FinalizeUploadRequest._();

  factory FinalizeUploadRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      FinalizeUploadRequest()..mergeFromBuffer(data, registry);
  factory FinalizeUploadRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      FinalizeUploadRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'FinalizeUploadRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.media.v1'),
      createEmptyInstance: FinalizeUploadRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..pPM<FinalizeItem>(2, _omitFieldNames ? '' : 'items',
        subBuilder: FinalizeItem.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FinalizeUploadRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FinalizeUploadRequest copyWith(
          void Function(FinalizeUploadRequest) updates) =>
      super.copyWith((message) => updates(message as FinalizeUploadRequest))
          as FinalizeUploadRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use FinalizeUploadRequest() / FinalizeUploadRequest.new instead')
  static FinalizeUploadRequest create() => FinalizeUploadRequest._();
  static $pb.GeneratedMessage $_createMessage() => FinalizeUploadRequest._();
  @$core.override
  FinalizeUploadRequest createEmptyInstance() => FinalizeUploadRequest._();
  @$core.pragma('dart2js:noInline')
  static FinalizeUploadRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<FinalizeUploadRequest>(
          FinalizeUploadRequest.$_createMessage);
  static FinalizeUploadRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  /// 1-4 items from the same CreateUpload.
  @$pb.TagNumber(2)
  $pb.PbList<FinalizeItem> get items => $_getList(1);
}

class MediaResult extends $pb.GeneratedMessage {
  factory MediaResult({
    $core.String? mediaId,
    MediaStatus? status,
    $1.MediaRef? media,
    $core.String? rejectionReason,
  }) {
    final result = MediaResult._();
    if (mediaId != null) result.mediaId = mediaId;
    if (status != null) result.status = status;
    if (media != null) result.media = media;
    if (rejectionReason != null) result.rejectionReason = rejectionReason;
    return result;
  }

  MediaResult._();

  factory MediaResult.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      MediaResult()..mergeFromBuffer(data, registry);
  factory MediaResult.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      MediaResult()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'MediaResult',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.media.v1'),
      createEmptyInstance: MediaResult.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'mediaId')
    ..aE<MediaStatus>(2, _omitFieldNames ? '' : 'status',
        enumValues: MediaStatus.values)
    ..aOM<$1.MediaRef>(3, _omitFieldNames ? '' : 'media',
        subBuilder: $1.MediaRef.$_createMessage)
    ..aOS(4, _omitFieldNames ? '' : 'rejectionReason')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MediaResult clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MediaResult copyWith(void Function(MediaResult) updates) =>
      super.copyWith((message) => updates(message as MediaResult))
          as MediaResult;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use MediaResult() / MediaResult.new instead')
  static MediaResult create() => MediaResult._();
  static $pb.GeneratedMessage $_createMessage() => MediaResult._();
  @$core.override
  MediaResult createEmptyInstance() => MediaResult._();
  @$core.pragma('dart2js:noInline')
  static MediaResult getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<MediaResult>(
          MediaResult.$_createMessage);
  static MediaResult? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get mediaId => $_getSZ(0);
  @$pb.TagNumber(1)
  set mediaId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasMediaId() => $_has(0);
  @$pb.TagNumber(1)
  void clearMediaId() => $_clearField(1);

  @$pb.TagNumber(2)
  MediaStatus get status => $_getN(1);
  @$pb.TagNumber(2)
  set status(MediaStatus value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasStatus() => $_has(1);
  @$pb.TagNumber(2)
  void clearStatus() => $_clearField(2);

  /// Set when READY or READY_UNSCREENED.
  @$pb.TagNumber(3)
  $1.MediaRef get media => $_getN(2);
  @$pb.TagNumber(3)
  set media($1.MediaRef value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasMedia() => $_has(2);
  @$pb.TagNumber(3)
  void clearMedia() => $_clearField(3);
  @$pb.TagNumber(3)
  $1.MediaRef ensureMedia() => $_ensure(2);

  /// Set when REJECTED; safe to show.
  @$pb.TagNumber(4)
  $core.String get rejectionReason => $_getSZ(3);
  @$pb.TagNumber(4)
  set rejectionReason($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasRejectionReason() => $_has(3);
  @$pb.TagNumber(4)
  void clearRejectionReason() => $_clearField(4);
}

class FinalizeUploadResponse extends $pb.GeneratedMessage {
  factory FinalizeUploadResponse({
    $core.Iterable<MediaResult>? results,
  }) {
    final result = FinalizeUploadResponse._();
    if (results != null) result.results.addAll(results);
    return result;
  }

  FinalizeUploadResponse._();

  factory FinalizeUploadResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      FinalizeUploadResponse()..mergeFromBuffer(data, registry);
  factory FinalizeUploadResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      FinalizeUploadResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'FinalizeUploadResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.media.v1'),
      createEmptyInstance: FinalizeUploadResponse.$_createMessage)
    ..pPM<MediaResult>(1, _omitFieldNames ? '' : 'results',
        subBuilder: MediaResult.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FinalizeUploadResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FinalizeUploadResponse copyWith(
          void Function(FinalizeUploadResponse) updates) =>
      super.copyWith((message) => updates(message as FinalizeUploadResponse))
          as FinalizeUploadResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use FinalizeUploadResponse() / FinalizeUploadResponse.new instead')
  static FinalizeUploadResponse create() => FinalizeUploadResponse._();
  static $pb.GeneratedMessage $_createMessage() => FinalizeUploadResponse._();
  @$core.override
  FinalizeUploadResponse createEmptyInstance() => FinalizeUploadResponse._();
  @$core.pragma('dart2js:noInline')
  static FinalizeUploadResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<FinalizeUploadResponse>(
          FinalizeUploadResponse.$_createMessage);
  static FinalizeUploadResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<MediaResult> get results => $_getList(0);
}

class MediaServiceApi {
  final $pb.RpcClient _client;

  MediaServiceApi(this._client);

  /// Reserve 1-4 media ids and get signed PUT URLs (full + thumb each), 10-minute TTL, bound to the exact object
  /// path, Content-Type, Content-MD5 and x-goog-content-length-range (full <= 2 MiB, thumb <= 256 KiB).
  /// Quota: 20 media/day/user (quotas/{uid}). Rejected with DEGRADED_MODE when DEGRADED_MODE != off.
  /// Batch: Create idempotency doc + media docs (PENDING, expireAt = now + 2 d) + quotas.
  /// GCS: 0 ops here (signing uses IAM signBlob, no GCS call). Client PUTs = 2 Class A per image.
  /// Firestore: reads 2/1 (quotas + replay), writes 6/3 (1 image typical).
  $async.Future<CreateUploadResponse> createUpload(
          $pb.ClientContext? ctx, CreateUploadRequest request) =>
      _client.invoke<CreateUploadResponse>(
          ctx, 'MediaService', 'CreateUpload', request, CreateUploadResponse());

  /// Verify and moderate uploaded objects, then publish. Per item: GCS object attrs + 512-byte ranged read
  /// (magic bytes) -> SafeSearch on the full image if the monthly Vision counter < 950 -> copy full+thumb to the
  /// public bucket -> READY; or REJECTED (objects deleted). Counter exhausted => READY_UNSCREENED (policy knob,
  /// ADR-0005). Naturally idempotent: items already READY/REJECTED are returned as-is.
  /// GCS per image: 2 Class A (copies) + 3 Class B (attrs, ranged read, Vision fetch); deletes are free.
  /// Firestore: reads 5/2 (media docs + Vision counter, cached 60 s), writes 5/2.
  $async.Future<FinalizeUploadResponse> finalizeUpload(
          $pb.ClientContext? ctx, FinalizeUploadRequest request) =>
      _client.invoke<FinalizeUploadResponse>(ctx, 'MediaService',
          'FinalizeUpload', request, FinalizeUploadResponse());
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
