// This is a generated file - do not edit.
//
// Generated from dzeroth/moderation/v1/moderation.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:async' as $async;
import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

import 'moderation.pbenum.dart';

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

export 'moderation.pbenum.dart';

class ReportContentRequest extends $pb.GeneratedMessage {
  factory ReportContentRequest({
    $core.String? idempotencyKey,
    ReportTargetType? targetType,
    $core.String? targetId,
    ReportReason? reason,
    $core.String? note,
  }) {
    final result = ReportContentRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (targetType != null) result.targetType = targetType;
    if (targetId != null) result.targetId = targetId;
    if (reason != null) result.reason = reason;
    if (note != null) result.note = note;
    return result;
  }

  ReportContentRequest._();

  factory ReportContentRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ReportContentRequest()..mergeFromBuffer(data, registry);
  factory ReportContentRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ReportContentRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ReportContentRequest',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.moderation.v1'),
      createEmptyInstance: ReportContentRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aE<ReportTargetType>(2, _omitFieldNames ? '' : 'targetType',
        enumValues: ReportTargetType.values)
    ..aOS(3, _omitFieldNames ? '' : 'targetId')
    ..aE<ReportReason>(4, _omitFieldNames ? '' : 'reason',
        enumValues: ReportReason.values)
    ..aOS(5, _omitFieldNames ? '' : 'note')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ReportContentRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ReportContentRequest copyWith(void Function(ReportContentRequest) updates) =>
      super.copyWith((message) => updates(message as ReportContentRequest))
          as ReportContentRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ReportContentRequest() / ReportContentRequest.new instead')
  static ReportContentRequest create() => ReportContentRequest._();
  static $pb.GeneratedMessage $_createMessage() => ReportContentRequest._();
  @$core.override
  ReportContentRequest createEmptyInstance() => ReportContentRequest._();
  @$core.pragma('dart2js:noInline')
  static ReportContentRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ReportContentRequest>(
          ReportContentRequest.$_createMessage);
  static ReportContentRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  @$pb.TagNumber(2)
  ReportTargetType get targetType => $_getN(1);
  @$pb.TagNumber(2)
  set targetType(ReportTargetType value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasTargetType() => $_has(1);
  @$pb.TagNumber(2)
  void clearTargetType() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get targetId => $_getSZ(2);
  @$pb.TagNumber(3)
  set targetId($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasTargetId() => $_has(2);
  @$pb.TagNumber(3)
  void clearTargetId() => $_clearField(3);

  @$pb.TagNumber(4)
  ReportReason get reason => $_getN(3);
  @$pb.TagNumber(4)
  set reason(ReportReason value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasReason() => $_has(3);
  @$pb.TagNumber(4)
  void clearReason() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.String get note => $_getSZ(4);
  @$pb.TagNumber(5)
  set note($core.String value) => $_setString(4, value);
  @$pb.TagNumber(5)
  $core.bool hasNote() => $_has(4);
  @$pb.TagNumber(5)
  void clearNote() => $_clearField(5);
}

class ReportContentResponse extends $pb.GeneratedMessage {
  factory ReportContentResponse({
    $core.String? reportId,
    $core.bool? alreadyReported,
  }) {
    final result = ReportContentResponse._();
    if (reportId != null) result.reportId = reportId;
    if (alreadyReported != null) result.alreadyReported = alreadyReported;
    return result;
  }

  ReportContentResponse._();

  factory ReportContentResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ReportContentResponse()..mergeFromBuffer(data, registry);
  factory ReportContentResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ReportContentResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ReportContentResponse',
      package: const $pb.PackageName(
          _omitMessageNames ? '' : 'dzeroth.moderation.v1'),
      createEmptyInstance: ReportContentResponse.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'reportId')
    ..aOB(2, _omitFieldNames ? '' : 'alreadyReported')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ReportContentResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ReportContentResponse copyWith(
          void Function(ReportContentResponse) updates) =>
      super.copyWith((message) => updates(message as ReportContentResponse))
          as ReportContentResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ReportContentResponse() / ReportContentResponse.new instead')
  static ReportContentResponse create() => ReportContentResponse._();
  static $pb.GeneratedMessage $_createMessage() => ReportContentResponse._();
  @$core.override
  ReportContentResponse createEmptyInstance() => ReportContentResponse._();
  @$core.pragma('dart2js:noInline')
  static ReportContentResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ReportContentResponse>(
          ReportContentResponse.$_createMessage);
  static ReportContentResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get reportId => $_getSZ(0);
  @$pb.TagNumber(1)
  set reportId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasReportId() => $_has(0);
  @$pb.TagNumber(1)
  void clearReportId() => $_clearField(1);

  /// True when this reporter had already reported this target; nothing was written.
  @$pb.TagNumber(2)
  $core.bool get alreadyReported => $_getBF(1);
  @$pb.TagNumber(2)
  set alreadyReported($core.bool value) => $_setBool(1, value);
  @$pb.TagNumber(2)
  $core.bool hasAlreadyReported() => $_has(1);
  @$pb.TagNumber(2)
  void clearAlreadyReported() => $_clearField(2);
}

class ModerationServiceApi {
  final $pb.RpcClient _client;

  ModerationServiceApi(this._client);

  /// Report a post or an account. Quota: 20 reports/day (quotas/{uid}, `reports` counter; 5/day for accounts younger
  /// than 24 h).
  /// target_type POST: target_id is a 19-digit post id; the post must be visible to the caller exactly as GetPost
  /// defines (missing, deleted, taken-down, blocked-author or non-ACTIVE-author => NOT_FOUND, one message for every
  /// cause). target_type ACCOUNT: target_id is a user id; visible exactly as GetProfile defines (missing, non-ACTIVE
  /// or blocked-the-caller => NOT_FOUND).
  /// Reporting your own post or account => INVALID_ARGUMENT + VALIDATION field "target_id".
  /// note: optional, <= 500 code points after NFC and trim; control characters other than LF => VALIDATION "note".
  /// The report doc copies the reported post's text, author handle and media ids ("evidence"), so a later author
  /// delete does not destroy it.
  /// Idempotency: the report doc id is derived from (reporter, target_type, target_id), so the same reporter reporting
  /// the same target again is a success with already_reported=true, 0 writes and no quota charge, regardless of
  /// idempotency_key. idempotency_key (required, <= 64 chars) is still validated for contract uniformity.
  /// Firestore: reads cold 6 (interceptor caller users 1, post 1 + author users 1 + caller graph 1 for POST or
  /// target users 1 for ACCOUNT, report doc 1, quotas 1), warm 2 (report doc, quotas); planning 3. Writes 2 (report
  /// create, quotas); replay 0. No async work. Nothing here loops over documents.
  $async.Future<ReportContentResponse> reportContent(
          $pb.ClientContext? ctx, ReportContentRequest request) =>
      _client.invoke<ReportContentResponse>(ctx, 'ModerationService',
          'ReportContent', request, ReportContentResponse());
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
