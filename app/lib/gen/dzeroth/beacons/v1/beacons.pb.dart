// This is a generated file - do not edit.
//
// Generated from dzeroth/beacons/v1/beacons.proto.

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
    as $1;

import '../../common/v1/common.pb.dart' as $0;
import 'beacons.pbenum.dart';

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

export 'beacons.pbenum.dart';

class Beacon extends $pb.GeneratedMessage {
  factory Beacon({
    $core.String? beaconId,
    $0.AuthorSnapshot? organiser,
    $core.String? communityId,
    BeaconActivity? activity,
    $core.String? title,
    $core.String? details,
    $core.String? venue,
    $1.Timestamp? startAt,
    $core.int? durationMinutes,
    $core.int? openSpots,
    $core.int? acceptedCount,
    BeaconCost? cost,
    ChatPreference? chatPreference,
    BeaconEligibility? eligibility,
    BeaconStatus? status,
    $core.bool? hidden,
    $1.Timestamp? createdAt,
    $1.Timestamp? updatedAt,
  }) {
    final result = Beacon._();
    if (beaconId != null) result.beaconId = beaconId;
    if (organiser != null) result.organiser = organiser;
    if (communityId != null) result.communityId = communityId;
    if (activity != null) result.activity = activity;
    if (title != null) result.title = title;
    if (details != null) result.details = details;
    if (venue != null) result.venue = venue;
    if (startAt != null) result.startAt = startAt;
    if (durationMinutes != null) result.durationMinutes = durationMinutes;
    if (openSpots != null) result.openSpots = openSpots;
    if (acceptedCount != null) result.acceptedCount = acceptedCount;
    if (cost != null) result.cost = cost;
    if (chatPreference != null) result.chatPreference = chatPreference;
    if (eligibility != null) result.eligibility = eligibility;
    if (status != null) result.status = status;
    if (hidden != null) result.hidden = hidden;
    if (createdAt != null) result.createdAt = createdAt;
    if (updatedAt != null) result.updatedAt = updatedAt;
    return result;
  }

  Beacon._();

  factory Beacon.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Beacon()..mergeFromBuffer(data, registry);
  factory Beacon.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Beacon()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Beacon',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.beacons.v1'),
      createEmptyInstance: Beacon.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'beaconId')
    ..aOM<$0.AuthorSnapshot>(2, _omitFieldNames ? '' : 'organiser',
        subBuilder: $0.AuthorSnapshot.$_createMessage)
    ..aOS(3, _omitFieldNames ? '' : 'communityId')
    ..aE<BeaconActivity>(4, _omitFieldNames ? '' : 'activity',
        enumValues: BeaconActivity.values)
    ..aOS(5, _omitFieldNames ? '' : 'title')
    ..aOS(6, _omitFieldNames ? '' : 'details')
    ..aOS(7, _omitFieldNames ? '' : 'venue')
    ..aOM<$1.Timestamp>(8, _omitFieldNames ? '' : 'startAt',
        subBuilder: $1.Timestamp.$_createMessage)
    ..aI(9, _omitFieldNames ? '' : 'durationMinutes')
    ..aI(10, _omitFieldNames ? '' : 'openSpots')
    ..aI(11, _omitFieldNames ? '' : 'acceptedCount')
    ..aE<BeaconCost>(12, _omitFieldNames ? '' : 'cost',
        enumValues: BeaconCost.values)
    ..aE<ChatPreference>(13, _omitFieldNames ? '' : 'chatPreference',
        enumValues: ChatPreference.values)
    ..aE<BeaconEligibility>(14, _omitFieldNames ? '' : 'eligibility',
        enumValues: BeaconEligibility.values)
    ..aE<BeaconStatus>(15, _omitFieldNames ? '' : 'status',
        enumValues: BeaconStatus.values)
    ..aOB(16, _omitFieldNames ? '' : 'hidden')
    ..aOM<$1.Timestamp>(17, _omitFieldNames ? '' : 'createdAt',
        subBuilder: $1.Timestamp.$_createMessage)
    ..aOM<$1.Timestamp>(18, _omitFieldNames ? '' : 'updatedAt',
        subBuilder: $1.Timestamp.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Beacon clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Beacon copyWith(void Function(Beacon) updates) =>
      super.copyWith((message) => updates(message as Beacon)) as Beacon;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Beacon() / Beacon.new instead')
  static Beacon create() => Beacon._();
  static $pb.GeneratedMessage $_createMessage() => Beacon._();
  @$core.override
  Beacon createEmptyInstance() => Beacon._();
  @$core.pragma('dart2js:noInline')
  static Beacon getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Beacon>(Beacon.$_createMessage);
  static Beacon? _defaultInstance;

  /// 19-digit Snowflake.
  @$pb.TagNumber(1)
  $core.String get beaconId => $_getSZ(0);
  @$pb.TagNumber(1)
  set beaconId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasBeaconId() => $_has(0);
  @$pb.TagNumber(1)
  void clearBeaconId() => $_clearField(1);

  /// Live row (identity directory, up to 60 s stale).
  @$pb.TagNumber(2)
  $0.AuthorSnapshot get organiser => $_getN(1);
  @$pb.TagNumber(2)
  set organiser($0.AuthorSnapshot value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasOrganiser() => $_has(1);
  @$pb.TagNumber(2)
  void clearOrganiser() => $_clearField(2);
  @$pb.TagNumber(2)
  $0.AuthorSnapshot ensureOrganiser() => $_ensure(1);

  /// Empty for a public beacon.
  @$pb.TagNumber(3)
  $core.String get communityId => $_getSZ(2);
  @$pb.TagNumber(3)
  set communityId($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasCommunityId() => $_has(2);
  @$pb.TagNumber(3)
  void clearCommunityId() => $_clearField(3);

  @$pb.TagNumber(4)
  BeaconActivity get activity => $_getN(3);
  @$pb.TagNumber(4)
  set activity(BeaconActivity value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasActivity() => $_has(3);
  @$pb.TagNumber(4)
  void clearActivity() => $_clearField(4);

  /// 1-60 code points.
  @$pb.TagNumber(5)
  $core.String get title => $_getSZ(4);
  @$pb.TagNumber(5)
  set title($core.String value) => $_setString(4, value);
  @$pb.TagNumber(5)
  $core.bool hasTitle() => $_has(4);
  @$pb.TagNumber(5)
  void clearTitle() => $_clearField(5);

  /// 0-300 code points.
  @$pb.TagNumber(6)
  $core.String get details => $_getSZ(5);
  @$pb.TagNumber(6)
  set details($core.String value) => $_setString(5, value);
  @$pb.TagNumber(6)
  $core.bool hasDetails() => $_has(5);
  @$pb.TagNumber(6)
  void clearDetails() => $_clearField(6);

  /// 1-80 code points: a named meeting point, never coordinates.
  @$pb.TagNumber(7)
  $core.String get venue => $_getSZ(6);
  @$pb.TagNumber(7)
  set venue($core.String value) => $_setString(6, value);
  @$pb.TagNumber(7)
  $core.bool hasVenue() => $_has(6);
  @$pb.TagNumber(7)
  void clearVenue() => $_clearField(7);

  @$pb.TagNumber(8)
  $1.Timestamp get startAt => $_getN(7);
  @$pb.TagNumber(8)
  set startAt($1.Timestamp value) => $_setField(8, value);
  @$pb.TagNumber(8)
  $core.bool hasStartAt() => $_has(7);
  @$pb.TagNumber(8)
  void clearStartAt() => $_clearField(8);
  @$pb.TagNumber(8)
  $1.Timestamp ensureStartAt() => $_ensure(7);

  /// 15-240.
  @$pb.TagNumber(9)
  $core.int get durationMinutes => $_getIZ(8);
  @$pb.TagNumber(9)
  set durationMinutes($core.int value) => $_setSignedInt32(8, value);
  @$pb.TagNumber(9)
  $core.bool hasDurationMinutes() => $_has(8);
  @$pb.TagNumber(9)
  void clearDurationMinutes() => $_clearField(9);

  /// Seats beyond the organiser, 1..BEACONS_MAX_OPEN_SPOTS.
  @$pb.TagNumber(10)
  $core.int get openSpots => $_getIZ(9);
  @$pb.TagNumber(10)
  set openSpots($core.int value) => $_setSignedInt32(9, value);
  @$pb.TagNumber(10)
  $core.bool hasOpenSpots() => $_has(9);
  @$pb.TagNumber(10)
  void clearOpenSpots() => $_clearField(10);

  @$pb.TagNumber(11)
  $core.int get acceptedCount => $_getIZ(10);
  @$pb.TagNumber(11)
  set acceptedCount($core.int value) => $_setSignedInt32(10, value);
  @$pb.TagNumber(11)
  $core.bool hasAcceptedCount() => $_has(10);
  @$pb.TagNumber(11)
  void clearAcceptedCount() => $_clearField(11);

  @$pb.TagNumber(12)
  BeaconCost get cost => $_getN(11);
  @$pb.TagNumber(12)
  set cost(BeaconCost value) => $_setField(12, value);
  @$pb.TagNumber(12)
  $core.bool hasCost() => $_has(11);
  @$pb.TagNumber(12)
  void clearCost() => $_clearField(12);

  @$pb.TagNumber(13)
  ChatPreference get chatPreference => $_getN(12);
  @$pb.TagNumber(13)
  set chatPreference(ChatPreference value) => $_setField(13, value);
  @$pb.TagNumber(13)
  $core.bool hasChatPreference() => $_has(12);
  @$pb.TagNumber(13)
  void clearChatPreference() => $_clearField(13);

  @$pb.TagNumber(14)
  BeaconEligibility get eligibility => $_getN(13);
  @$pb.TagNumber(14)
  set eligibility(BeaconEligibility value) => $_setField(14, value);
  @$pb.TagNumber(14)
  $core.bool hasEligibility() => $_has(13);
  @$pb.TagNumber(14)
  void clearEligibility() => $_clearField(14);

  @$pb.TagNumber(15)
  BeaconStatus get status => $_getN(14);
  @$pb.TagNumber(15)
  set status(BeaconStatus value) => $_setField(15, value);
  @$pb.TagNumber(15)
  $core.bool hasStatus() => $_has(14);
  @$pb.TagNumber(15)
  void clearStatus() => $_clearField(15);

  /// Platform hide (opsctl). Only ever true in the organiser's own view.
  @$pb.TagNumber(16)
  $core.bool get hidden => $_getBF(15);
  @$pb.TagNumber(16)
  set hidden($core.bool value) => $_setBool(15, value);
  @$pb.TagNumber(16)
  $core.bool hasHidden() => $_has(15);
  @$pb.TagNumber(16)
  void clearHidden() => $_clearField(16);

  @$pb.TagNumber(17)
  $1.Timestamp get createdAt => $_getN(16);
  @$pb.TagNumber(17)
  set createdAt($1.Timestamp value) => $_setField(17, value);
  @$pb.TagNumber(17)
  $core.bool hasCreatedAt() => $_has(16);
  @$pb.TagNumber(17)
  void clearCreatedAt() => $_clearField(17);
  @$pb.TagNumber(17)
  $1.Timestamp ensureCreatedAt() => $_ensure(16);

  @$pb.TagNumber(18)
  $1.Timestamp get updatedAt => $_getN(17);
  @$pb.TagNumber(18)
  set updatedAt($1.Timestamp value) => $_setField(18, value);
  @$pb.TagNumber(18)
  $core.bool hasUpdatedAt() => $_has(17);
  @$pb.TagNumber(18)
  void clearUpdatedAt() => $_clearField(18);
  @$pb.TagNumber(18)
  $1.Timestamp ensureUpdatedAt() => $_ensure(17);
}

/// The caller's relationship with a beacon, so the client renders the right action without a second call.
class ViewerState extends $pb.GeneratedMessage {
  factory ViewerState({
    ViewerRole? role,
    ParticipantState? participantState,
    $core.bool? canRequest,
    $core.bool? canWithdraw,
    $core.bool? canLeave,
    $core.bool? canManage,
  }) {
    final result = ViewerState._();
    if (role != null) result.role = role;
    if (participantState != null) result.participantState = participantState;
    if (canRequest != null) result.canRequest = canRequest;
    if (canWithdraw != null) result.canWithdraw = canWithdraw;
    if (canLeave != null) result.canLeave = canLeave;
    if (canManage != null) result.canManage = canManage;
    return result;
  }

  ViewerState._();

  factory ViewerState.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ViewerState()..mergeFromBuffer(data, registry);
  factory ViewerState.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ViewerState()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ViewerState',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.beacons.v1'),
      createEmptyInstance: ViewerState.$_createMessage)
    ..aE<ViewerRole>(1, _omitFieldNames ? '' : 'role',
        enumValues: ViewerRole.values)
    ..aE<ParticipantState>(2, _omitFieldNames ? '' : 'participantState',
        enumValues: ParticipantState.values)
    ..aOB(3, _omitFieldNames ? '' : 'canRequest')
    ..aOB(4, _omitFieldNames ? '' : 'canWithdraw')
    ..aOB(5, _omitFieldNames ? '' : 'canLeave')
    ..aOB(6, _omitFieldNames ? '' : 'canManage')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ViewerState clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ViewerState copyWith(void Function(ViewerState) updates) =>
      super.copyWith((message) => updates(message as ViewerState))
          as ViewerState;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use ViewerState() / ViewerState.new instead')
  static ViewerState create() => ViewerState._();
  static $pb.GeneratedMessage $_createMessage() => ViewerState._();
  @$core.override
  ViewerState createEmptyInstance() => ViewerState._();
  @$core.pragma('dart2js:noInline')
  static ViewerState getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<ViewerState>(
          ViewerState.$_createMessage);
  static ViewerState? _defaultInstance;

  @$pb.TagNumber(1)
  ViewerRole get role => $_getN(0);
  @$pb.TagNumber(1)
  set role(ViewerRole value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasRole() => $_has(0);
  @$pb.TagNumber(1)
  void clearRole() => $_clearField(1);

  /// UNSPECIFIED when the viewer never requested.
  @$pb.TagNumber(2)
  ParticipantState get participantState => $_getN(1);
  @$pb.TagNumber(2)
  set participantState(ParticipantState value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasParticipantState() => $_has(1);
  @$pb.TagNumber(2)
  void clearParticipantState() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.bool get canRequest => $_getBF(2);
  @$pb.TagNumber(3)
  set canRequest($core.bool value) => $_setBool(2, value);
  @$pb.TagNumber(3)
  $core.bool hasCanRequest() => $_has(2);
  @$pb.TagNumber(3)
  void clearCanRequest() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.bool get canWithdraw => $_getBF(3);
  @$pb.TagNumber(4)
  set canWithdraw($core.bool value) => $_setBool(3, value);
  @$pb.TagNumber(4)
  $core.bool hasCanWithdraw() => $_has(3);
  @$pb.TagNumber(4)
  void clearCanWithdraw() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.bool get canLeave => $_getBF(4);
  @$pb.TagNumber(5)
  set canLeave($core.bool value) => $_setBool(4, value);
  @$pb.TagNumber(5)
  $core.bool hasCanLeave() => $_has(4);
  @$pb.TagNumber(5)
  void clearCanLeave() => $_clearField(5);

  @$pb.TagNumber(6)
  $core.bool get canManage => $_getBF(5);
  @$pb.TagNumber(6)
  set canManage($core.bool value) => $_setBool(5, value);
  @$pb.TagNumber(6)
  $core.bool hasCanManage() => $_has(5);
  @$pb.TagNumber(6)
  void clearCanManage() => $_clearField(6);
}

class BeaconView extends $pb.GeneratedMessage {
  factory BeaconView({
    Beacon? beacon,
    ViewerState? viewer,
  }) {
    final result = BeaconView._();
    if (beacon != null) result.beacon = beacon;
    if (viewer != null) result.viewer = viewer;
    return result;
  }

  BeaconView._();

  factory BeaconView.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      BeaconView()..mergeFromBuffer(data, registry);
  factory BeaconView.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      BeaconView()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'BeaconView',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.beacons.v1'),
      createEmptyInstance: BeaconView.$_createMessage)
    ..aOM<Beacon>(1, _omitFieldNames ? '' : 'beacon',
        subBuilder: Beacon.$_createMessage)
    ..aOM<ViewerState>(2, _omitFieldNames ? '' : 'viewer',
        subBuilder: ViewerState.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BeaconView clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BeaconView copyWith(void Function(BeaconView) updates) =>
      super.copyWith((message) => updates(message as BeaconView)) as BeaconView;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use BeaconView() / BeaconView.new instead')
  static BeaconView create() => BeaconView._();
  static $pb.GeneratedMessage $_createMessage() => BeaconView._();
  @$core.override
  BeaconView createEmptyInstance() => BeaconView._();
  @$core.pragma('dart2js:noInline')
  static BeaconView getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<BeaconView>(BeaconView.$_createMessage);
  static BeaconView? _defaultInstance;

  @$pb.TagNumber(1)
  Beacon get beacon => $_getN(0);
  @$pb.TagNumber(1)
  set beacon(Beacon value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasBeacon() => $_has(0);
  @$pb.TagNumber(1)
  void clearBeacon() => $_clearField(1);
  @$pb.TagNumber(1)
  Beacon ensureBeacon() => $_ensure(0);

  @$pb.TagNumber(2)
  ViewerState get viewer => $_getN(1);
  @$pb.TagNumber(2)
  set viewer(ViewerState value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasViewer() => $_has(1);
  @$pb.TagNumber(2)
  void clearViewer() => $_clearField(2);
  @$pb.TagNumber(2)
  ViewerState ensureViewer() => $_ensure(1);
}

class Participant extends $pb.GeneratedMessage {
  factory Participant({
    $0.AuthorSnapshot? user,
    ParticipantState? state,
    $core.String? note,
    $1.Timestamp? since,
  }) {
    final result = Participant._();
    if (user != null) result.user = user;
    if (state != null) result.state = state;
    if (note != null) result.note = note;
    if (since != null) result.since = since;
    return result;
  }

  Participant._();

  factory Participant.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Participant()..mergeFromBuffer(data, registry);
  factory Participant.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Participant()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Participant',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.beacons.v1'),
      createEmptyInstance: Participant.$_createMessage)
    ..aOM<$0.AuthorSnapshot>(1, _omitFieldNames ? '' : 'user',
        subBuilder: $0.AuthorSnapshot.$_createMessage)
    ..aE<ParticipantState>(2, _omitFieldNames ? '' : 'state',
        enumValues: ParticipantState.values)
    ..aOS(3, _omitFieldNames ? '' : 'note')
    ..aOM<$1.Timestamp>(4, _omitFieldNames ? '' : 'since',
        subBuilder: $1.Timestamp.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Participant clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Participant copyWith(void Function(Participant) updates) =>
      super.copyWith((message) => updates(message as Participant))
          as Participant;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Participant() / Participant.new instead')
  static Participant create() => Participant._();
  static $pb.GeneratedMessage $_createMessage() => Participant._();
  @$core.override
  Participant createEmptyInstance() => Participant._();
  @$core.pragma('dart2js:noInline')
  static Participant getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<Participant>(
          Participant.$_createMessage);
  static Participant? _defaultInstance;

  /// Live row (identity directory, up to 60 s stale).
  @$pb.TagNumber(1)
  $0.AuthorSnapshot get user => $_getN(0);
  @$pb.TagNumber(1)
  set user($0.AuthorSnapshot value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasUser() => $_has(0);
  @$pb.TagNumber(1)
  void clearUser() => $_clearField(1);
  @$pb.TagNumber(1)
  $0.AuthorSnapshot ensureUser() => $_ensure(0);

  @$pb.TagNumber(2)
  ParticipantState get state => $_getN(1);
  @$pb.TagNumber(2)
  set state(ParticipantState value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasState() => $_has(1);
  @$pb.TagNumber(2)
  void clearState() => $_clearField(2);

  /// REQUESTED rows only, organiser only; empty otherwise.
  @$pb.TagNumber(3)
  $core.String get note => $_getSZ(2);
  @$pb.TagNumber(3)
  set note($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasNote() => $_has(2);
  @$pb.TagNumber(3)
  void clearNote() => $_clearField(3);

  /// requestedAt for a REQUESTED row, respondedAt for an ACCEPTED one.
  @$pb.TagNumber(4)
  $1.Timestamp get since => $_getN(3);
  @$pb.TagNumber(4)
  set since($1.Timestamp value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasSince() => $_has(3);
  @$pb.TagNumber(4)
  void clearSince() => $_clearField(4);
  @$pb.TagNumber(4)
  $1.Timestamp ensureSince() => $_ensure(3);
}

enum CreateBeaconRequest_Audience { communityId, public, notSet }

class CreateBeaconRequest extends $pb.GeneratedMessage {
  factory CreateBeaconRequest({
    $core.String? idempotencyKey,
    $core.String? communityId,
    $core.bool? public,
    BeaconActivity? activity,
    $core.String? title,
    $core.String? details,
    $core.String? venue,
    $1.Timestamp? startAt,
    $core.int? durationMinutes,
    $core.int? openSpots,
    BeaconCost? cost,
    ChatPreference? chatPreference,
  }) {
    final result = CreateBeaconRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (communityId != null) result.communityId = communityId;
    if (public != null) result.public = public;
    if (activity != null) result.activity = activity;
    if (title != null) result.title = title;
    if (details != null) result.details = details;
    if (venue != null) result.venue = venue;
    if (startAt != null) result.startAt = startAt;
    if (durationMinutes != null) result.durationMinutes = durationMinutes;
    if (openSpots != null) result.openSpots = openSpots;
    if (cost != null) result.cost = cost;
    if (chatPreference != null) result.chatPreference = chatPreference;
    return result;
  }

  CreateBeaconRequest._();

  factory CreateBeaconRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CreateBeaconRequest()..mergeFromBuffer(data, registry);
  factory CreateBeaconRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CreateBeaconRequest()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, CreateBeaconRequest_Audience>
      _CreateBeaconRequest_AudienceByTag = {
    2: CreateBeaconRequest_Audience.communityId,
    3: CreateBeaconRequest_Audience.public,
    0: CreateBeaconRequest_Audience.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CreateBeaconRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.beacons.v1'),
      createEmptyInstance: CreateBeaconRequest.$_createMessage)
    ..oo(0, [2, 3])
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'communityId')
    ..aOB(3, _omitFieldNames ? '' : 'public')
    ..aE<BeaconActivity>(4, _omitFieldNames ? '' : 'activity',
        enumValues: BeaconActivity.values)
    ..aOS(5, _omitFieldNames ? '' : 'title')
    ..aOS(6, _omitFieldNames ? '' : 'details')
    ..aOS(7, _omitFieldNames ? '' : 'venue')
    ..aOM<$1.Timestamp>(8, _omitFieldNames ? '' : 'startAt',
        subBuilder: $1.Timestamp.$_createMessage)
    ..aI(9, _omitFieldNames ? '' : 'durationMinutes')
    ..aI(10, _omitFieldNames ? '' : 'openSpots')
    ..aE<BeaconCost>(11, _omitFieldNames ? '' : 'cost',
        enumValues: BeaconCost.values)
    ..aE<ChatPreference>(12, _omitFieldNames ? '' : 'chatPreference',
        enumValues: ChatPreference.values)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateBeaconRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateBeaconRequest copyWith(void Function(CreateBeaconRequest) updates) =>
      super.copyWith((message) => updates(message as CreateBeaconRequest))
          as CreateBeaconRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core
      .Deprecated('Use CreateBeaconRequest() / CreateBeaconRequest.new instead')
  static CreateBeaconRequest create() => CreateBeaconRequest._();
  static $pb.GeneratedMessage $_createMessage() => CreateBeaconRequest._();
  @$core.override
  CreateBeaconRequest createEmptyInstance() => CreateBeaconRequest._();
  @$core.pragma('dart2js:noInline')
  static CreateBeaconRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<CreateBeaconRequest>(
          CreateBeaconRequest.$_createMessage);
  static CreateBeaconRequest? _defaultInstance;

  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  CreateBeaconRequest_Audience whichAudience() =>
      _CreateBeaconRequest_AudienceByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  void clearAudience() => $_clearField($_whichOneof(0));

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get communityId => $_getSZ(1);
  @$pb.TagNumber(2)
  set communityId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasCommunityId() => $_has(1);
  @$pb.TagNumber(2)
  void clearCommunityId() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.bool get public => $_getBF(2);
  @$pb.TagNumber(3)
  set public($core.bool value) => $_setBool(2, value);
  @$pb.TagNumber(3)
  $core.bool hasPublic() => $_has(2);
  @$pb.TagNumber(3)
  void clearPublic() => $_clearField(3);

  @$pb.TagNumber(4)
  BeaconActivity get activity => $_getN(3);
  @$pb.TagNumber(4)
  set activity(BeaconActivity value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasActivity() => $_has(3);
  @$pb.TagNumber(4)
  void clearActivity() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.String get title => $_getSZ(4);
  @$pb.TagNumber(5)
  set title($core.String value) => $_setString(4, value);
  @$pb.TagNumber(5)
  $core.bool hasTitle() => $_has(4);
  @$pb.TagNumber(5)
  void clearTitle() => $_clearField(5);

  @$pb.TagNumber(6)
  $core.String get details => $_getSZ(5);
  @$pb.TagNumber(6)
  set details($core.String value) => $_setString(5, value);
  @$pb.TagNumber(6)
  $core.bool hasDetails() => $_has(5);
  @$pb.TagNumber(6)
  void clearDetails() => $_clearField(6);

  @$pb.TagNumber(7)
  $core.String get venue => $_getSZ(6);
  @$pb.TagNumber(7)
  set venue($core.String value) => $_setString(6, value);
  @$pb.TagNumber(7)
  $core.bool hasVenue() => $_has(6);
  @$pb.TagNumber(7)
  void clearVenue() => $_clearField(7);

  @$pb.TagNumber(8)
  $1.Timestamp get startAt => $_getN(7);
  @$pb.TagNumber(8)
  set startAt($1.Timestamp value) => $_setField(8, value);
  @$pb.TagNumber(8)
  $core.bool hasStartAt() => $_has(7);
  @$pb.TagNumber(8)
  void clearStartAt() => $_clearField(8);
  @$pb.TagNumber(8)
  $1.Timestamp ensureStartAt() => $_ensure(7);

  @$pb.TagNumber(9)
  $core.int get durationMinutes => $_getIZ(8);
  @$pb.TagNumber(9)
  set durationMinutes($core.int value) => $_setSignedInt32(8, value);
  @$pb.TagNumber(9)
  $core.bool hasDurationMinutes() => $_has(8);
  @$pb.TagNumber(9)
  void clearDurationMinutes() => $_clearField(9);

  @$pb.TagNumber(10)
  $core.int get openSpots => $_getIZ(9);
  @$pb.TagNumber(10)
  set openSpots($core.int value) => $_setSignedInt32(9, value);
  @$pb.TagNumber(10)
  $core.bool hasOpenSpots() => $_has(9);
  @$pb.TagNumber(10)
  void clearOpenSpots() => $_clearField(10);

  @$pb.TagNumber(11)
  BeaconCost get cost => $_getN(10);
  @$pb.TagNumber(11)
  set cost(BeaconCost value) => $_setField(11, value);
  @$pb.TagNumber(11)
  $core.bool hasCost() => $_has(10);
  @$pb.TagNumber(11)
  void clearCost() => $_clearField(11);

  @$pb.TagNumber(12)
  ChatPreference get chatPreference => $_getN(11);
  @$pb.TagNumber(12)
  set chatPreference(ChatPreference value) => $_setField(12, value);
  @$pb.TagNumber(12)
  $core.bool hasChatPreference() => $_has(11);
  @$pb.TagNumber(12)
  void clearChatPreference() => $_clearField(12);
}

class CreateBeaconResponse extends $pb.GeneratedMessage {
  factory CreateBeaconResponse({
    BeaconView? view,
  }) {
    final result = CreateBeaconResponse._();
    if (view != null) result.view = view;
    return result;
  }

  CreateBeaconResponse._();

  factory CreateBeaconResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CreateBeaconResponse()..mergeFromBuffer(data, registry);
  factory CreateBeaconResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CreateBeaconResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CreateBeaconResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.beacons.v1'),
      createEmptyInstance: CreateBeaconResponse.$_createMessage)
    ..aOM<BeaconView>(1, _omitFieldNames ? '' : 'view',
        subBuilder: BeaconView.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateBeaconResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CreateBeaconResponse copyWith(void Function(CreateBeaconResponse) updates) =>
      super.copyWith((message) => updates(message as CreateBeaconResponse))
          as CreateBeaconResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use CreateBeaconResponse() / CreateBeaconResponse.new instead')
  static CreateBeaconResponse create() => CreateBeaconResponse._();
  static $pb.GeneratedMessage $_createMessage() => CreateBeaconResponse._();
  @$core.override
  CreateBeaconResponse createEmptyInstance() => CreateBeaconResponse._();
  @$core.pragma('dart2js:noInline')
  static CreateBeaconResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<CreateBeaconResponse>(
          CreateBeaconResponse.$_createMessage);
  static CreateBeaconResponse? _defaultInstance;

  @$pb.TagNumber(1)
  BeaconView get view => $_getN(0);
  @$pb.TagNumber(1)
  set view(BeaconView value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasView() => $_has(0);
  @$pb.TagNumber(1)
  void clearView() => $_clearField(1);
  @$pb.TagNumber(1)
  BeaconView ensureView() => $_ensure(0);
}

class UpdateBeaconRequest extends $pb.GeneratedMessage {
  factory UpdateBeaconRequest({
    $core.String? idempotencyKey,
    $core.String? beaconId,
    $core.String? title,
    $core.String? details,
    $core.String? venue,
    $core.int? openSpots,
  }) {
    final result = UpdateBeaconRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (beaconId != null) result.beaconId = beaconId;
    if (title != null) result.title = title;
    if (details != null) result.details = details;
    if (venue != null) result.venue = venue;
    if (openSpots != null) result.openSpots = openSpots;
    return result;
  }

  UpdateBeaconRequest._();

  factory UpdateBeaconRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UpdateBeaconRequest()..mergeFromBuffer(data, registry);
  factory UpdateBeaconRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UpdateBeaconRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'UpdateBeaconRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.beacons.v1'),
      createEmptyInstance: UpdateBeaconRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'beaconId')
    ..aOS(3, _omitFieldNames ? '' : 'title')
    ..aOS(4, _omitFieldNames ? '' : 'details')
    ..aOS(5, _omitFieldNames ? '' : 'venue')
    ..aI(6, _omitFieldNames ? '' : 'openSpots')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UpdateBeaconRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UpdateBeaconRequest copyWith(void Function(UpdateBeaconRequest) updates) =>
      super.copyWith((message) => updates(message as UpdateBeaconRequest))
          as UpdateBeaconRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core
      .Deprecated('Use UpdateBeaconRequest() / UpdateBeaconRequest.new instead')
  static UpdateBeaconRequest create() => UpdateBeaconRequest._();
  static $pb.GeneratedMessage $_createMessage() => UpdateBeaconRequest._();
  @$core.override
  UpdateBeaconRequest createEmptyInstance() => UpdateBeaconRequest._();
  @$core.pragma('dart2js:noInline')
  static UpdateBeaconRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<UpdateBeaconRequest>(
          UpdateBeaconRequest.$_createMessage);
  static UpdateBeaconRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get beaconId => $_getSZ(1);
  @$pb.TagNumber(2)
  set beaconId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasBeaconId() => $_has(1);
  @$pb.TagNumber(2)
  void clearBeaconId() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get title => $_getSZ(2);
  @$pb.TagNumber(3)
  set title($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasTitle() => $_has(2);
  @$pb.TagNumber(3)
  void clearTitle() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.String get details => $_getSZ(3);
  @$pb.TagNumber(4)
  set details($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasDetails() => $_has(3);
  @$pb.TagNumber(4)
  void clearDetails() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.String get venue => $_getSZ(4);
  @$pb.TagNumber(5)
  set venue($core.String value) => $_setString(4, value);
  @$pb.TagNumber(5)
  $core.bool hasVenue() => $_has(4);
  @$pb.TagNumber(5)
  void clearVenue() => $_clearField(5);

  /// Never below accepted_count.
  @$pb.TagNumber(6)
  $core.int get openSpots => $_getIZ(5);
  @$pb.TagNumber(6)
  set openSpots($core.int value) => $_setSignedInt32(5, value);
  @$pb.TagNumber(6)
  $core.bool hasOpenSpots() => $_has(5);
  @$pb.TagNumber(6)
  void clearOpenSpots() => $_clearField(6);
}

class UpdateBeaconResponse extends $pb.GeneratedMessage {
  factory UpdateBeaconResponse({
    BeaconView? view,
  }) {
    final result = UpdateBeaconResponse._();
    if (view != null) result.view = view;
    return result;
  }

  UpdateBeaconResponse._();

  factory UpdateBeaconResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UpdateBeaconResponse()..mergeFromBuffer(data, registry);
  factory UpdateBeaconResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UpdateBeaconResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'UpdateBeaconResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.beacons.v1'),
      createEmptyInstance: UpdateBeaconResponse.$_createMessage)
    ..aOM<BeaconView>(1, _omitFieldNames ? '' : 'view',
        subBuilder: BeaconView.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UpdateBeaconResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UpdateBeaconResponse copyWith(void Function(UpdateBeaconResponse) updates) =>
      super.copyWith((message) => updates(message as UpdateBeaconResponse))
          as UpdateBeaconResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use UpdateBeaconResponse() / UpdateBeaconResponse.new instead')
  static UpdateBeaconResponse create() => UpdateBeaconResponse._();
  static $pb.GeneratedMessage $_createMessage() => UpdateBeaconResponse._();
  @$core.override
  UpdateBeaconResponse createEmptyInstance() => UpdateBeaconResponse._();
  @$core.pragma('dart2js:noInline')
  static UpdateBeaconResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<UpdateBeaconResponse>(
          UpdateBeaconResponse.$_createMessage);
  static UpdateBeaconResponse? _defaultInstance;

  @$pb.TagNumber(1)
  BeaconView get view => $_getN(0);
  @$pb.TagNumber(1)
  set view(BeaconView value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasView() => $_has(0);
  @$pb.TagNumber(1)
  void clearView() => $_clearField(1);
  @$pb.TagNumber(1)
  BeaconView ensureView() => $_ensure(0);
}

class CancelBeaconRequest extends $pb.GeneratedMessage {
  factory CancelBeaconRequest({
    $core.String? idempotencyKey,
    $core.String? beaconId,
  }) {
    final result = CancelBeaconRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (beaconId != null) result.beaconId = beaconId;
    return result;
  }

  CancelBeaconRequest._();

  factory CancelBeaconRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CancelBeaconRequest()..mergeFromBuffer(data, registry);
  factory CancelBeaconRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CancelBeaconRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CancelBeaconRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.beacons.v1'),
      createEmptyInstance: CancelBeaconRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'beaconId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CancelBeaconRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CancelBeaconRequest copyWith(void Function(CancelBeaconRequest) updates) =>
      super.copyWith((message) => updates(message as CancelBeaconRequest))
          as CancelBeaconRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core
      .Deprecated('Use CancelBeaconRequest() / CancelBeaconRequest.new instead')
  static CancelBeaconRequest create() => CancelBeaconRequest._();
  static $pb.GeneratedMessage $_createMessage() => CancelBeaconRequest._();
  @$core.override
  CancelBeaconRequest createEmptyInstance() => CancelBeaconRequest._();
  @$core.pragma('dart2js:noInline')
  static CancelBeaconRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<CancelBeaconRequest>(
          CancelBeaconRequest.$_createMessage);
  static CancelBeaconRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get beaconId => $_getSZ(1);
  @$pb.TagNumber(2)
  set beaconId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasBeaconId() => $_has(1);
  @$pb.TagNumber(2)
  void clearBeaconId() => $_clearField(2);
}

class CancelBeaconResponse extends $pb.GeneratedMessage {
  factory CancelBeaconResponse() => CancelBeaconResponse._();

  CancelBeaconResponse._();

  factory CancelBeaconResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CancelBeaconResponse()..mergeFromBuffer(data, registry);
  factory CancelBeaconResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CancelBeaconResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CancelBeaconResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.beacons.v1'),
      createEmptyInstance: CancelBeaconResponse.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CancelBeaconResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CancelBeaconResponse copyWith(void Function(CancelBeaconResponse) updates) =>
      super.copyWith((message) => updates(message as CancelBeaconResponse))
          as CancelBeaconResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use CancelBeaconResponse() / CancelBeaconResponse.new instead')
  static CancelBeaconResponse create() => CancelBeaconResponse._();
  static $pb.GeneratedMessage $_createMessage() => CancelBeaconResponse._();
  @$core.override
  CancelBeaconResponse createEmptyInstance() => CancelBeaconResponse._();
  @$core.pragma('dart2js:noInline')
  static CancelBeaconResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<CancelBeaconResponse>(
          CancelBeaconResponse.$_createMessage);
  static CancelBeaconResponse? _defaultInstance;
}

class GetBeaconRequest extends $pb.GeneratedMessage {
  factory GetBeaconRequest({
    $core.String? beaconId,
  }) {
    final result = GetBeaconRequest._();
    if (beaconId != null) result.beaconId = beaconId;
    return result;
  }

  GetBeaconRequest._();

  factory GetBeaconRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetBeaconRequest()..mergeFromBuffer(data, registry);
  factory GetBeaconRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetBeaconRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetBeaconRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.beacons.v1'),
      createEmptyInstance: GetBeaconRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'beaconId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetBeaconRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetBeaconRequest copyWith(void Function(GetBeaconRequest) updates) =>
      super.copyWith((message) => updates(message as GetBeaconRequest))
          as GetBeaconRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use GetBeaconRequest() / GetBeaconRequest.new instead')
  static GetBeaconRequest create() => GetBeaconRequest._();
  static $pb.GeneratedMessage $_createMessage() => GetBeaconRequest._();
  @$core.override
  GetBeaconRequest createEmptyInstance() => GetBeaconRequest._();
  @$core.pragma('dart2js:noInline')
  static GetBeaconRequest getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<GetBeaconRequest>(
          GetBeaconRequest.$_createMessage);
  static GetBeaconRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get beaconId => $_getSZ(0);
  @$pb.TagNumber(1)
  set beaconId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasBeaconId() => $_has(0);
  @$pb.TagNumber(1)
  void clearBeaconId() => $_clearField(1);
}

class GetBeaconResponse extends $pb.GeneratedMessage {
  factory GetBeaconResponse({
    BeaconView? view,
  }) {
    final result = GetBeaconResponse._();
    if (view != null) result.view = view;
    return result;
  }

  GetBeaconResponse._();

  factory GetBeaconResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetBeaconResponse()..mergeFromBuffer(data, registry);
  factory GetBeaconResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GetBeaconResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GetBeaconResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.beacons.v1'),
      createEmptyInstance: GetBeaconResponse.$_createMessage)
    ..aOM<BeaconView>(1, _omitFieldNames ? '' : 'view',
        subBuilder: BeaconView.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetBeaconResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GetBeaconResponse copyWith(void Function(GetBeaconResponse) updates) =>
      super.copyWith((message) => updates(message as GetBeaconResponse))
          as GetBeaconResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use GetBeaconResponse() / GetBeaconResponse.new instead')
  static GetBeaconResponse create() => GetBeaconResponse._();
  static $pb.GeneratedMessage $_createMessage() => GetBeaconResponse._();
  @$core.override
  GetBeaconResponse createEmptyInstance() => GetBeaconResponse._();
  @$core.pragma('dart2js:noInline')
  static GetBeaconResponse getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<GetBeaconResponse>(
          GetBeaconResponse.$_createMessage);
  static GetBeaconResponse? _defaultInstance;

  @$pb.TagNumber(1)
  BeaconView get view => $_getN(0);
  @$pb.TagNumber(1)
  set view(BeaconView value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasView() => $_has(0);
  @$pb.TagNumber(1)
  void clearView() => $_clearField(1);
  @$pb.TagNumber(1)
  BeaconView ensureView() => $_ensure(0);
}

enum ListBeaconsRequest_Audience { communityId, public, notSet }

class ListBeaconsRequest extends $pb.GeneratedMessage {
  factory ListBeaconsRequest({
    $core.String? communityId,
    $core.bool? public,
    $1.Timestamp? from,
    $core.int? limit,
    $core.String? pageToken,
  }) {
    final result = ListBeaconsRequest._();
    if (communityId != null) result.communityId = communityId;
    if (public != null) result.public = public;
    if (from != null) result.from = from;
    if (limit != null) result.limit = limit;
    if (pageToken != null) result.pageToken = pageToken;
    return result;
  }

  ListBeaconsRequest._();

  factory ListBeaconsRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListBeaconsRequest()..mergeFromBuffer(data, registry);
  factory ListBeaconsRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListBeaconsRequest()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, ListBeaconsRequest_Audience>
      _ListBeaconsRequest_AudienceByTag = {
    1: ListBeaconsRequest_Audience.communityId,
    2: ListBeaconsRequest_Audience.public,
    0: ListBeaconsRequest_Audience.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListBeaconsRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.beacons.v1'),
      createEmptyInstance: ListBeaconsRequest.$_createMessage)
    ..oo(0, [1, 2])
    ..aOS(1, _omitFieldNames ? '' : 'communityId')
    ..aOB(2, _omitFieldNames ? '' : 'public')
    ..aOM<$1.Timestamp>(3, _omitFieldNames ? '' : 'from',
        subBuilder: $1.Timestamp.$_createMessage)
    ..aI(4, _omitFieldNames ? '' : 'limit')
    ..aOS(5, _omitFieldNames ? '' : 'pageToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListBeaconsRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListBeaconsRequest copyWith(void Function(ListBeaconsRequest) updates) =>
      super.copyWith((message) => updates(message as ListBeaconsRequest))
          as ListBeaconsRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use ListBeaconsRequest() / ListBeaconsRequest.new instead')
  static ListBeaconsRequest create() => ListBeaconsRequest._();
  static $pb.GeneratedMessage $_createMessage() => ListBeaconsRequest._();
  @$core.override
  ListBeaconsRequest createEmptyInstance() => ListBeaconsRequest._();
  @$core.pragma('dart2js:noInline')
  static ListBeaconsRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListBeaconsRequest>(
          ListBeaconsRequest.$_createMessage);
  static ListBeaconsRequest? _defaultInstance;

  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  ListBeaconsRequest_Audience whichAudience() =>
      _ListBeaconsRequest_AudienceByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  void clearAudience() => $_clearField($_whichOneof(0));

  @$pb.TagNumber(1)
  $core.String get communityId => $_getSZ(0);
  @$pb.TagNumber(1)
  set communityId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasCommunityId() => $_has(0);
  @$pb.TagNumber(1)
  void clearCommunityId() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.bool get public => $_getBF(1);
  @$pb.TagNumber(2)
  set public($core.bool value) => $_setBool(1, value);
  @$pb.TagNumber(2)
  $core.bool hasPublic() => $_has(1);
  @$pb.TagNumber(2)
  void clearPublic() => $_clearField(2);

  /// Beacons whose start_at >= from (default now); OPEN and FULL only, hidden excluded, blocks applied.
  @$pb.TagNumber(3)
  $1.Timestamp get from => $_getN(2);
  @$pb.TagNumber(3)
  set from($1.Timestamp value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasFrom() => $_has(2);
  @$pb.TagNumber(3)
  void clearFrom() => $_clearField(3);
  @$pb.TagNumber(3)
  $1.Timestamp ensureFrom() => $_ensure(2);

  /// Clamped: 0 = 20, above 50 = 50.
  @$pb.TagNumber(4)
  $core.int get limit => $_getIZ(3);
  @$pb.TagNumber(4)
  set limit($core.int value) => $_setSignedInt32(3, value);
  @$pb.TagNumber(4)
  $core.bool hasLimit() => $_has(3);
  @$pb.TagNumber(4)
  void clearLimit() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.String get pageToken => $_getSZ(4);
  @$pb.TagNumber(5)
  set pageToken($core.String value) => $_setString(4, value);
  @$pb.TagNumber(5)
  $core.bool hasPageToken() => $_has(4);
  @$pb.TagNumber(5)
  void clearPageToken() => $_clearField(5);
}

class ListBeaconsResponse extends $pb.GeneratedMessage {
  factory ListBeaconsResponse({
    $core.Iterable<BeaconView>? views,
    $core.String? nextPageToken,
  }) {
    final result = ListBeaconsResponse._();
    if (views != null) result.views.addAll(views);
    if (nextPageToken != null) result.nextPageToken = nextPageToken;
    return result;
  }

  ListBeaconsResponse._();

  factory ListBeaconsResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListBeaconsResponse()..mergeFromBuffer(data, registry);
  factory ListBeaconsResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListBeaconsResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListBeaconsResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.beacons.v1'),
      createEmptyInstance: ListBeaconsResponse.$_createMessage)
    ..pPM<BeaconView>(1, _omitFieldNames ? '' : 'views',
        subBuilder: BeaconView.$_createMessage)
    ..aOS(2, _omitFieldNames ? '' : 'nextPageToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListBeaconsResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListBeaconsResponse copyWith(void Function(ListBeaconsResponse) updates) =>
      super.copyWith((message) => updates(message as ListBeaconsResponse))
          as ListBeaconsResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core
      .Deprecated('Use ListBeaconsResponse() / ListBeaconsResponse.new instead')
  static ListBeaconsResponse create() => ListBeaconsResponse._();
  static $pb.GeneratedMessage $_createMessage() => ListBeaconsResponse._();
  @$core.override
  ListBeaconsResponse createEmptyInstance() => ListBeaconsResponse._();
  @$core.pragma('dart2js:noInline')
  static ListBeaconsResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListBeaconsResponse>(
          ListBeaconsResponse.$_createMessage);
  static ListBeaconsResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<BeaconView> get views => $_getList(0);

  @$pb.TagNumber(2)
  $core.String get nextPageToken => $_getSZ(1);
  @$pb.TagNumber(2)
  set nextPageToken($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasNextPageToken() => $_has(1);
  @$pb.TagNumber(2)
  void clearNextPageToken() => $_clearField(2);
}

class ListMyBeaconsRequest extends $pb.GeneratedMessage {
  factory ListMyBeaconsRequest({
    MyBeaconsRole? role,
    MyBeaconsWindow? window,
    $core.int? limit,
    $core.String? pageToken,
  }) {
    final result = ListMyBeaconsRequest._();
    if (role != null) result.role = role;
    if (window != null) result.window = window;
    if (limit != null) result.limit = limit;
    if (pageToken != null) result.pageToken = pageToken;
    return result;
  }

  ListMyBeaconsRequest._();

  factory ListMyBeaconsRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListMyBeaconsRequest()..mergeFromBuffer(data, registry);
  factory ListMyBeaconsRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListMyBeaconsRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListMyBeaconsRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.beacons.v1'),
      createEmptyInstance: ListMyBeaconsRequest.$_createMessage)
    ..aE<MyBeaconsRole>(1, _omitFieldNames ? '' : 'role',
        enumValues: MyBeaconsRole.values)
    ..aE<MyBeaconsWindow>(2, _omitFieldNames ? '' : 'window',
        enumValues: MyBeaconsWindow.values)
    ..aI(3, _omitFieldNames ? '' : 'limit')
    ..aOS(4, _omitFieldNames ? '' : 'pageToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListMyBeaconsRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListMyBeaconsRequest copyWith(void Function(ListMyBeaconsRequest) updates) =>
      super.copyWith((message) => updates(message as ListMyBeaconsRequest))
          as ListMyBeaconsRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ListMyBeaconsRequest() / ListMyBeaconsRequest.new instead')
  static ListMyBeaconsRequest create() => ListMyBeaconsRequest._();
  static $pb.GeneratedMessage $_createMessage() => ListMyBeaconsRequest._();
  @$core.override
  ListMyBeaconsRequest createEmptyInstance() => ListMyBeaconsRequest._();
  @$core.pragma('dart2js:noInline')
  static ListMyBeaconsRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListMyBeaconsRequest>(
          ListMyBeaconsRequest.$_createMessage);
  static ListMyBeaconsRequest? _defaultInstance;

  @$pb.TagNumber(1)
  MyBeaconsRole get role => $_getN(0);
  @$pb.TagNumber(1)
  set role(MyBeaconsRole value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasRole() => $_has(0);
  @$pb.TagNumber(1)
  void clearRole() => $_clearField(1);

  @$pb.TagNumber(2)
  MyBeaconsWindow get window => $_getN(1);
  @$pb.TagNumber(2)
  set window(MyBeaconsWindow value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasWindow() => $_has(1);
  @$pb.TagNumber(2)
  void clearWindow() => $_clearField(2);

  /// Clamped: 0 = 20, above 50 = 50.
  @$pb.TagNumber(3)
  $core.int get limit => $_getIZ(2);
  @$pb.TagNumber(3)
  set limit($core.int value) => $_setSignedInt32(2, value);
  @$pb.TagNumber(3)
  $core.bool hasLimit() => $_has(2);
  @$pb.TagNumber(3)
  void clearLimit() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.String get pageToken => $_getSZ(3);
  @$pb.TagNumber(4)
  set pageToken($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasPageToken() => $_has(3);
  @$pb.TagNumber(4)
  void clearPageToken() => $_clearField(4);
}

class ListMyBeaconsResponse extends $pb.GeneratedMessage {
  factory ListMyBeaconsResponse({
    $core.Iterable<BeaconView>? views,
    $core.String? nextPageToken,
  }) {
    final result = ListMyBeaconsResponse._();
    if (views != null) result.views.addAll(views);
    if (nextPageToken != null) result.nextPageToken = nextPageToken;
    return result;
  }

  ListMyBeaconsResponse._();

  factory ListMyBeaconsResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListMyBeaconsResponse()..mergeFromBuffer(data, registry);
  factory ListMyBeaconsResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListMyBeaconsResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListMyBeaconsResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.beacons.v1'),
      createEmptyInstance: ListMyBeaconsResponse.$_createMessage)
    ..pPM<BeaconView>(1, _omitFieldNames ? '' : 'views',
        subBuilder: BeaconView.$_createMessage)
    ..aOS(2, _omitFieldNames ? '' : 'nextPageToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListMyBeaconsResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListMyBeaconsResponse copyWith(
          void Function(ListMyBeaconsResponse) updates) =>
      super.copyWith((message) => updates(message as ListMyBeaconsResponse))
          as ListMyBeaconsResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ListMyBeaconsResponse() / ListMyBeaconsResponse.new instead')
  static ListMyBeaconsResponse create() => ListMyBeaconsResponse._();
  static $pb.GeneratedMessage $_createMessage() => ListMyBeaconsResponse._();
  @$core.override
  ListMyBeaconsResponse createEmptyInstance() => ListMyBeaconsResponse._();
  @$core.pragma('dart2js:noInline')
  static ListMyBeaconsResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListMyBeaconsResponse>(
          ListMyBeaconsResponse.$_createMessage);
  static ListMyBeaconsResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<BeaconView> get views => $_getList(0);

  @$pb.TagNumber(2)
  $core.String get nextPageToken => $_getSZ(1);
  @$pb.TagNumber(2)
  set nextPageToken($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasNextPageToken() => $_has(1);
  @$pb.TagNumber(2)
  void clearNextPageToken() => $_clearField(2);
}

class RequestToJoinRequest extends $pb.GeneratedMessage {
  factory RequestToJoinRequest({
    $core.String? idempotencyKey,
    $core.String? beaconId,
    $core.String? note,
  }) {
    final result = RequestToJoinRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (beaconId != null) result.beaconId = beaconId;
    if (note != null) result.note = note;
    return result;
  }

  RequestToJoinRequest._();

  factory RequestToJoinRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RequestToJoinRequest()..mergeFromBuffer(data, registry);
  factory RequestToJoinRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RequestToJoinRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RequestToJoinRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.beacons.v1'),
      createEmptyInstance: RequestToJoinRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'beaconId')
    ..aOS(3, _omitFieldNames ? '' : 'note')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RequestToJoinRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RequestToJoinRequest copyWith(void Function(RequestToJoinRequest) updates) =>
      super.copyWith((message) => updates(message as RequestToJoinRequest))
          as RequestToJoinRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use RequestToJoinRequest() / RequestToJoinRequest.new instead')
  static RequestToJoinRequest create() => RequestToJoinRequest._();
  static $pb.GeneratedMessage $_createMessage() => RequestToJoinRequest._();
  @$core.override
  RequestToJoinRequest createEmptyInstance() => RequestToJoinRequest._();
  @$core.pragma('dart2js:noInline')
  static RequestToJoinRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<RequestToJoinRequest>(
          RequestToJoinRequest.$_createMessage);
  static RequestToJoinRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get beaconId => $_getSZ(1);
  @$pb.TagNumber(2)
  set beaconId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasBeaconId() => $_has(1);
  @$pb.TagNumber(2)
  void clearBeaconId() => $_clearField(2);

  /// 0-140 code points.
  @$pb.TagNumber(3)
  $core.String get note => $_getSZ(2);
  @$pb.TagNumber(3)
  set note($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasNote() => $_has(2);
  @$pb.TagNumber(3)
  void clearNote() => $_clearField(3);
}

class RequestToJoinResponse extends $pb.GeneratedMessage {
  factory RequestToJoinResponse({
    ViewerState? viewer,
  }) {
    final result = RequestToJoinResponse._();
    if (viewer != null) result.viewer = viewer;
    return result;
  }

  RequestToJoinResponse._();

  factory RequestToJoinResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RequestToJoinResponse()..mergeFromBuffer(data, registry);
  factory RequestToJoinResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RequestToJoinResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RequestToJoinResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.beacons.v1'),
      createEmptyInstance: RequestToJoinResponse.$_createMessage)
    ..aOM<ViewerState>(1, _omitFieldNames ? '' : 'viewer',
        subBuilder: ViewerState.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RequestToJoinResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RequestToJoinResponse copyWith(
          void Function(RequestToJoinResponse) updates) =>
      super.copyWith((message) => updates(message as RequestToJoinResponse))
          as RequestToJoinResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use RequestToJoinResponse() / RequestToJoinResponse.new instead')
  static RequestToJoinResponse create() => RequestToJoinResponse._();
  static $pb.GeneratedMessage $_createMessage() => RequestToJoinResponse._();
  @$core.override
  RequestToJoinResponse createEmptyInstance() => RequestToJoinResponse._();
  @$core.pragma('dart2js:noInline')
  static RequestToJoinResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<RequestToJoinResponse>(
          RequestToJoinResponse.$_createMessage);
  static RequestToJoinResponse? _defaultInstance;

  @$pb.TagNumber(1)
  ViewerState get viewer => $_getN(0);
  @$pb.TagNumber(1)
  set viewer(ViewerState value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasViewer() => $_has(0);
  @$pb.TagNumber(1)
  void clearViewer() => $_clearField(1);
  @$pb.TagNumber(1)
  ViewerState ensureViewer() => $_ensure(0);
}

class WithdrawJoinRequestRequest extends $pb.GeneratedMessage {
  factory WithdrawJoinRequestRequest({
    $core.String? idempotencyKey,
    $core.String? beaconId,
  }) {
    final result = WithdrawJoinRequestRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (beaconId != null) result.beaconId = beaconId;
    return result;
  }

  WithdrawJoinRequestRequest._();

  factory WithdrawJoinRequestRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      WithdrawJoinRequestRequest()..mergeFromBuffer(data, registry);
  factory WithdrawJoinRequestRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      WithdrawJoinRequestRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'WithdrawJoinRequestRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.beacons.v1'),
      createEmptyInstance: WithdrawJoinRequestRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'beaconId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  WithdrawJoinRequestRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  WithdrawJoinRequestRequest copyWith(
          void Function(WithdrawJoinRequestRequest) updates) =>
      super.copyWith(
              (message) => updates(message as WithdrawJoinRequestRequest))
          as WithdrawJoinRequestRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use WithdrawJoinRequestRequest() / WithdrawJoinRequestRequest.new instead')
  static WithdrawJoinRequestRequest create() => WithdrawJoinRequestRequest._();
  static $pb.GeneratedMessage $_createMessage() =>
      WithdrawJoinRequestRequest._();
  @$core.override
  WithdrawJoinRequestRequest createEmptyInstance() =>
      WithdrawJoinRequestRequest._();
  @$core.pragma('dart2js:noInline')
  static WithdrawJoinRequestRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<WithdrawJoinRequestRequest>(
          WithdrawJoinRequestRequest.$_createMessage);
  static WithdrawJoinRequestRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get beaconId => $_getSZ(1);
  @$pb.TagNumber(2)
  set beaconId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasBeaconId() => $_has(1);
  @$pb.TagNumber(2)
  void clearBeaconId() => $_clearField(2);
}

class WithdrawJoinRequestResponse extends $pb.GeneratedMessage {
  factory WithdrawJoinRequestResponse() => WithdrawJoinRequestResponse._();

  WithdrawJoinRequestResponse._();

  factory WithdrawJoinRequestResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      WithdrawJoinRequestResponse()..mergeFromBuffer(data, registry);
  factory WithdrawJoinRequestResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      WithdrawJoinRequestResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'WithdrawJoinRequestResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.beacons.v1'),
      createEmptyInstance: WithdrawJoinRequestResponse.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  WithdrawJoinRequestResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  WithdrawJoinRequestResponse copyWith(
          void Function(WithdrawJoinRequestResponse) updates) =>
      super.copyWith(
              (message) => updates(message as WithdrawJoinRequestResponse))
          as WithdrawJoinRequestResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use WithdrawJoinRequestResponse() / WithdrawJoinRequestResponse.new instead')
  static WithdrawJoinRequestResponse create() =>
      WithdrawJoinRequestResponse._();
  static $pb.GeneratedMessage $_createMessage() =>
      WithdrawJoinRequestResponse._();
  @$core.override
  WithdrawJoinRequestResponse createEmptyInstance() =>
      WithdrawJoinRequestResponse._();
  @$core.pragma('dart2js:noInline')
  static WithdrawJoinRequestResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<WithdrawJoinRequestResponse>(
          WithdrawJoinRequestResponse.$_createMessage);
  static WithdrawJoinRequestResponse? _defaultInstance;
}

class RespondToJoinRequestRequest extends $pb.GeneratedMessage {
  factory RespondToJoinRequestRequest({
    $core.String? idempotencyKey,
    $core.String? beaconId,
    $core.String? userId,
    JoinResponse? response,
  }) {
    final result = RespondToJoinRequestRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (beaconId != null) result.beaconId = beaconId;
    if (userId != null) result.userId = userId;
    if (response != null) result.response = response;
    return result;
  }

  RespondToJoinRequestRequest._();

  factory RespondToJoinRequestRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RespondToJoinRequestRequest()..mergeFromBuffer(data, registry);
  factory RespondToJoinRequestRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RespondToJoinRequestRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RespondToJoinRequestRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.beacons.v1'),
      createEmptyInstance: RespondToJoinRequestRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'beaconId')
    ..aOS(3, _omitFieldNames ? '' : 'userId')
    ..aE<JoinResponse>(4, _omitFieldNames ? '' : 'response',
        enumValues: JoinResponse.values)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RespondToJoinRequestRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RespondToJoinRequestRequest copyWith(
          void Function(RespondToJoinRequestRequest) updates) =>
      super.copyWith(
              (message) => updates(message as RespondToJoinRequestRequest))
          as RespondToJoinRequestRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use RespondToJoinRequestRequest() / RespondToJoinRequestRequest.new instead')
  static RespondToJoinRequestRequest create() =>
      RespondToJoinRequestRequest._();
  static $pb.GeneratedMessage $_createMessage() =>
      RespondToJoinRequestRequest._();
  @$core.override
  RespondToJoinRequestRequest createEmptyInstance() =>
      RespondToJoinRequestRequest._();
  @$core.pragma('dart2js:noInline')
  static RespondToJoinRequestRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<RespondToJoinRequestRequest>(
          RespondToJoinRequestRequest.$_createMessage);
  static RespondToJoinRequestRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get beaconId => $_getSZ(1);
  @$pb.TagNumber(2)
  set beaconId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasBeaconId() => $_has(1);
  @$pb.TagNumber(2)
  void clearBeaconId() => $_clearField(2);

  /// The requester. [A-Za-z0-9-]{1,128}, else VALIDATION "user_id".
  @$pb.TagNumber(3)
  $core.String get userId => $_getSZ(2);
  @$pb.TagNumber(3)
  set userId($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasUserId() => $_has(2);
  @$pb.TagNumber(3)
  void clearUserId() => $_clearField(3);

  @$pb.TagNumber(4)
  JoinResponse get response => $_getN(3);
  @$pb.TagNumber(4)
  set response(JoinResponse value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasResponse() => $_has(3);
  @$pb.TagNumber(4)
  void clearResponse() => $_clearField(4);
}

class RespondToJoinRequestResponse extends $pb.GeneratedMessage {
  factory RespondToJoinRequestResponse({
    BeaconView? view,
  }) {
    final result = RespondToJoinRequestResponse._();
    if (view != null) result.view = view;
    return result;
  }

  RespondToJoinRequestResponse._();

  factory RespondToJoinRequestResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RespondToJoinRequestResponse()..mergeFromBuffer(data, registry);
  factory RespondToJoinRequestResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RespondToJoinRequestResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RespondToJoinRequestResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.beacons.v1'),
      createEmptyInstance: RespondToJoinRequestResponse.$_createMessage)
    ..aOM<BeaconView>(1, _omitFieldNames ? '' : 'view',
        subBuilder: BeaconView.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RespondToJoinRequestResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RespondToJoinRequestResponse copyWith(
          void Function(RespondToJoinRequestResponse) updates) =>
      super.copyWith(
              (message) => updates(message as RespondToJoinRequestResponse))
          as RespondToJoinRequestResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use RespondToJoinRequestResponse() / RespondToJoinRequestResponse.new instead')
  static RespondToJoinRequestResponse create() =>
      RespondToJoinRequestResponse._();
  static $pb.GeneratedMessage $_createMessage() =>
      RespondToJoinRequestResponse._();
  @$core.override
  RespondToJoinRequestResponse createEmptyInstance() =>
      RespondToJoinRequestResponse._();
  @$core.pragma('dart2js:noInline')
  static RespondToJoinRequestResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<RespondToJoinRequestResponse>(
          RespondToJoinRequestResponse.$_createMessage);
  static RespondToJoinRequestResponse? _defaultInstance;

  @$pb.TagNumber(1)
  BeaconView get view => $_getN(0);
  @$pb.TagNumber(1)
  set view(BeaconView value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasView() => $_has(0);
  @$pb.TagNumber(1)
  void clearView() => $_clearField(1);
  @$pb.TagNumber(1)
  BeaconView ensureView() => $_ensure(0);
}

class LeaveBeaconRequest extends $pb.GeneratedMessage {
  factory LeaveBeaconRequest({
    $core.String? idempotencyKey,
    $core.String? beaconId,
  }) {
    final result = LeaveBeaconRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (beaconId != null) result.beaconId = beaconId;
    return result;
  }

  LeaveBeaconRequest._();

  factory LeaveBeaconRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      LeaveBeaconRequest()..mergeFromBuffer(data, registry);
  factory LeaveBeaconRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      LeaveBeaconRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'LeaveBeaconRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.beacons.v1'),
      createEmptyInstance: LeaveBeaconRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'beaconId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  LeaveBeaconRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  LeaveBeaconRequest copyWith(void Function(LeaveBeaconRequest) updates) =>
      super.copyWith((message) => updates(message as LeaveBeaconRequest))
          as LeaveBeaconRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use LeaveBeaconRequest() / LeaveBeaconRequest.new instead')
  static LeaveBeaconRequest create() => LeaveBeaconRequest._();
  static $pb.GeneratedMessage $_createMessage() => LeaveBeaconRequest._();
  @$core.override
  LeaveBeaconRequest createEmptyInstance() => LeaveBeaconRequest._();
  @$core.pragma('dart2js:noInline')
  static LeaveBeaconRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<LeaveBeaconRequest>(
          LeaveBeaconRequest.$_createMessage);
  static LeaveBeaconRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get beaconId => $_getSZ(1);
  @$pb.TagNumber(2)
  set beaconId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasBeaconId() => $_has(1);
  @$pb.TagNumber(2)
  void clearBeaconId() => $_clearField(2);
}

class LeaveBeaconResponse extends $pb.GeneratedMessage {
  factory LeaveBeaconResponse() => LeaveBeaconResponse._();

  LeaveBeaconResponse._();

  factory LeaveBeaconResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      LeaveBeaconResponse()..mergeFromBuffer(data, registry);
  factory LeaveBeaconResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      LeaveBeaconResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'LeaveBeaconResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.beacons.v1'),
      createEmptyInstance: LeaveBeaconResponse.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  LeaveBeaconResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  LeaveBeaconResponse copyWith(void Function(LeaveBeaconResponse) updates) =>
      super.copyWith((message) => updates(message as LeaveBeaconResponse))
          as LeaveBeaconResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core
      .Deprecated('Use LeaveBeaconResponse() / LeaveBeaconResponse.new instead')
  static LeaveBeaconResponse create() => LeaveBeaconResponse._();
  static $pb.GeneratedMessage $_createMessage() => LeaveBeaconResponse._();
  @$core.override
  LeaveBeaconResponse createEmptyInstance() => LeaveBeaconResponse._();
  @$core.pragma('dart2js:noInline')
  static LeaveBeaconResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<LeaveBeaconResponse>(
          LeaveBeaconResponse.$_createMessage);
  static LeaveBeaconResponse? _defaultInstance;
}

class RemoveParticipantRequest extends $pb.GeneratedMessage {
  factory RemoveParticipantRequest({
    $core.String? idempotencyKey,
    $core.String? beaconId,
    $core.String? userId,
  }) {
    final result = RemoveParticipantRequest._();
    if (idempotencyKey != null) result.idempotencyKey = idempotencyKey;
    if (beaconId != null) result.beaconId = beaconId;
    if (userId != null) result.userId = userId;
    return result;
  }

  RemoveParticipantRequest._();

  factory RemoveParticipantRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RemoveParticipantRequest()..mergeFromBuffer(data, registry);
  factory RemoveParticipantRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RemoveParticipantRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RemoveParticipantRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.beacons.v1'),
      createEmptyInstance: RemoveParticipantRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'idempotencyKey')
    ..aOS(2, _omitFieldNames ? '' : 'beaconId')
    ..aOS(3, _omitFieldNames ? '' : 'userId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RemoveParticipantRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RemoveParticipantRequest copyWith(
          void Function(RemoveParticipantRequest) updates) =>
      super.copyWith((message) => updates(message as RemoveParticipantRequest))
          as RemoveParticipantRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use RemoveParticipantRequest() / RemoveParticipantRequest.new instead')
  static RemoveParticipantRequest create() => RemoveParticipantRequest._();
  static $pb.GeneratedMessage $_createMessage() => RemoveParticipantRequest._();
  @$core.override
  RemoveParticipantRequest createEmptyInstance() =>
      RemoveParticipantRequest._();
  @$core.pragma('dart2js:noInline')
  static RemoveParticipantRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<RemoveParticipantRequest>(
          RemoveParticipantRequest.$_createMessage);
  static RemoveParticipantRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get idempotencyKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set idempotencyKey($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIdempotencyKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearIdempotencyKey() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get beaconId => $_getSZ(1);
  @$pb.TagNumber(2)
  set beaconId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasBeaconId() => $_has(1);
  @$pb.TagNumber(2)
  void clearBeaconId() => $_clearField(2);

  /// The ACCEPTED participant. [A-Za-z0-9-]{1,128}, else VALIDATION "user_id".
  @$pb.TagNumber(3)
  $core.String get userId => $_getSZ(2);
  @$pb.TagNumber(3)
  set userId($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasUserId() => $_has(2);
  @$pb.TagNumber(3)
  void clearUserId() => $_clearField(3);
}

class RemoveParticipantResponse extends $pb.GeneratedMessage {
  factory RemoveParticipantResponse({
    BeaconView? view,
  }) {
    final result = RemoveParticipantResponse._();
    if (view != null) result.view = view;
    return result;
  }

  RemoveParticipantResponse._();

  factory RemoveParticipantResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RemoveParticipantResponse()..mergeFromBuffer(data, registry);
  factory RemoveParticipantResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RemoveParticipantResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RemoveParticipantResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.beacons.v1'),
      createEmptyInstance: RemoveParticipantResponse.$_createMessage)
    ..aOM<BeaconView>(1, _omitFieldNames ? '' : 'view',
        subBuilder: BeaconView.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RemoveParticipantResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RemoveParticipantResponse copyWith(
          void Function(RemoveParticipantResponse) updates) =>
      super.copyWith((message) => updates(message as RemoveParticipantResponse))
          as RemoveParticipantResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use RemoveParticipantResponse() / RemoveParticipantResponse.new instead')
  static RemoveParticipantResponse create() => RemoveParticipantResponse._();
  static $pb.GeneratedMessage $_createMessage() =>
      RemoveParticipantResponse._();
  @$core.override
  RemoveParticipantResponse createEmptyInstance() =>
      RemoveParticipantResponse._();
  @$core.pragma('dart2js:noInline')
  static RemoveParticipantResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<RemoveParticipantResponse>(
          RemoveParticipantResponse.$_createMessage);
  static RemoveParticipantResponse? _defaultInstance;

  @$pb.TagNumber(1)
  BeaconView get view => $_getN(0);
  @$pb.TagNumber(1)
  set view(BeaconView value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasView() => $_has(0);
  @$pb.TagNumber(1)
  void clearView() => $_clearField(1);
  @$pb.TagNumber(1)
  BeaconView ensureView() => $_ensure(0);
}

class ListParticipantsRequest extends $pb.GeneratedMessage {
  factory ListParticipantsRequest({
    $core.String? beaconId,
    ParticipantFilter? filter,
    $core.int? limit,
    $core.String? pageToken,
  }) {
    final result = ListParticipantsRequest._();
    if (beaconId != null) result.beaconId = beaconId;
    if (filter != null) result.filter = filter;
    if (limit != null) result.limit = limit;
    if (pageToken != null) result.pageToken = pageToken;
    return result;
  }

  ListParticipantsRequest._();

  factory ListParticipantsRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListParticipantsRequest()..mergeFromBuffer(data, registry);
  factory ListParticipantsRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListParticipantsRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListParticipantsRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.beacons.v1'),
      createEmptyInstance: ListParticipantsRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'beaconId')
    ..aE<ParticipantFilter>(2, _omitFieldNames ? '' : 'filter',
        enumValues: ParticipantFilter.values)
    ..aI(3, _omitFieldNames ? '' : 'limit')
    ..aOS(4, _omitFieldNames ? '' : 'pageToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListParticipantsRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListParticipantsRequest copyWith(
          void Function(ListParticipantsRequest) updates) =>
      super.copyWith((message) => updates(message as ListParticipantsRequest))
          as ListParticipantsRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ListParticipantsRequest() / ListParticipantsRequest.new instead')
  static ListParticipantsRequest create() => ListParticipantsRequest._();
  static $pb.GeneratedMessage $_createMessage() => ListParticipantsRequest._();
  @$core.override
  ListParticipantsRequest createEmptyInstance() => ListParticipantsRequest._();
  @$core.pragma('dart2js:noInline')
  static ListParticipantsRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListParticipantsRequest>(
          ListParticipantsRequest.$_createMessage);
  static ListParticipantsRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get beaconId => $_getSZ(0);
  @$pb.TagNumber(1)
  set beaconId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasBeaconId() => $_has(0);
  @$pb.TagNumber(1)
  void clearBeaconId() => $_clearField(1);

  @$pb.TagNumber(2)
  ParticipantFilter get filter => $_getN(1);
  @$pb.TagNumber(2)
  set filter(ParticipantFilter value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasFilter() => $_has(1);
  @$pb.TagNumber(2)
  void clearFilter() => $_clearField(2);

  /// Clamped: 0 = 20, above 50 = 50.
  @$pb.TagNumber(3)
  $core.int get limit => $_getIZ(2);
  @$pb.TagNumber(3)
  set limit($core.int value) => $_setSignedInt32(2, value);
  @$pb.TagNumber(3)
  $core.bool hasLimit() => $_has(2);
  @$pb.TagNumber(3)
  void clearLimit() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.String get pageToken => $_getSZ(3);
  @$pb.TagNumber(4)
  set pageToken($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasPageToken() => $_has(3);
  @$pb.TagNumber(4)
  void clearPageToken() => $_clearField(4);
}

class ListParticipantsResponse extends $pb.GeneratedMessage {
  factory ListParticipantsResponse({
    $core.Iterable<Participant>? participants,
    $core.String? nextPageToken,
  }) {
    final result = ListParticipantsResponse._();
    if (participants != null) result.participants.addAll(participants);
    if (nextPageToken != null) result.nextPageToken = nextPageToken;
    return result;
  }

  ListParticipantsResponse._();

  factory ListParticipantsResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListParticipantsResponse()..mergeFromBuffer(data, registry);
  factory ListParticipantsResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ListParticipantsResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListParticipantsResponse',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'dzeroth.beacons.v1'),
      createEmptyInstance: ListParticipantsResponse.$_createMessage)
    ..pPM<Participant>(1, _omitFieldNames ? '' : 'participants',
        subBuilder: Participant.$_createMessage)
    ..aOS(2, _omitFieldNames ? '' : 'nextPageToken')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListParticipantsResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListParticipantsResponse copyWith(
          void Function(ListParticipantsResponse) updates) =>
      super.copyWith((message) => updates(message as ListParticipantsResponse))
          as ListParticipantsResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated(
      'Use ListParticipantsResponse() / ListParticipantsResponse.new instead')
  static ListParticipantsResponse create() => ListParticipantsResponse._();
  static $pb.GeneratedMessage $_createMessage() => ListParticipantsResponse._();
  @$core.override
  ListParticipantsResponse createEmptyInstance() =>
      ListParticipantsResponse._();
  @$core.pragma('dart2js:noInline')
  static ListParticipantsResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListParticipantsResponse>(
          ListParticipantsResponse.$_createMessage);
  static ListParticipantsResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<Participant> get participants => $_getList(0);

  @$pb.TagNumber(2)
  $core.String get nextPageToken => $_getSZ(1);
  @$pb.TagNumber(2)
  set nextPageToken($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasNextPageToken() => $_has(1);
  @$pb.TagNumber(2)
  void clearNextPageToken() => $_clearField(2);
}

class BeaconServiceApi {
  final $pb.RpcClient _client;

  BeaconServiceApi(this._client);

  /// Create a beacon organised by the caller. audience: community_id (the caller must be a JOINED member) or
  /// public = true; neither or both => VALIDATION "audience". activity != UNSPECIFIED; start_at in [now + 5 min,
  /// now + 30 d]; duration_minutes 15-240; open_spots 1..BEACONS_MAX_OPEN_SPOTS; cost and chat_preference !=
  /// UNSPECIFIED. Text rules in the header. One transaction: idempotency doc, a count() of the caller's OPEN/FULL
  /// beacons (LIMIT_REACHED "beacons_open" at 5), the beacon doc with a fresh Snowflake id (status OPEN,
  /// accepted_count 0, eligibility EVERYONE) and the caller's beaconMemberships row (role ORGANISER).
  $async.Future<CreateBeaconResponse> createBeacon(
          $pb.ClientContext? ctx, CreateBeaconRequest request) =>
      _client.invoke<CreateBeaconResponse>(ctx, 'BeaconService', 'CreateBeacon',
          request, CreateBeaconResponse());

  /// Change title, details, venue or open_spots of one of the caller's OPEN or FULL beacons (any other caller =>
  /// FORBIDDEN "not_organiser"). open_spots may not go below accepted_count (VALIDATION "open_spots"); raising it
  /// turns FULL back into OPEN, lowering it to accepted_count turns OPEN into FULL. start_at, duration, cost and
  /// audience are immutable at v1: cancel and create again. A request that changes nothing writes only the
  /// idempotency doc.
  $async.Future<UpdateBeaconResponse> updateBeacon(
          $pb.ClientContext? ctx, UpdateBeaconRequest request) =>
      _client.invoke<UpdateBeaconResponse>(ctx, 'BeaconService', 'UpdateBeacon',
          request, UpdateBeaconResponse());

  /// Cancel one of the caller's OPEN or FULL beacons: status CANCELLED on the beacon only. Participant and membership
  /// rows are pointers and read the beacon's status (GetBeacon, ListMyBeacons), so nothing fans out. Participants are
  /// notified (NOTIFICATION_TYPE_BEACON_CANCELLED). Already CANCELLED => success with the idempotency doc only.
  $async.Future<CancelBeaconResponse> cancelBeacon(
          $pb.ClientContext? ctx, CancelBeaconRequest request) =>
      _client.invoke<CancelBeaconResponse>(ctx, 'BeaconService', 'CancelBeacon',
          request, CancelBeaconResponse());

  /// One beacon as the caller may see it (audience, blocks and hidden applied; header). The organiser row is live
  /// (identity directory, 60 s); the viewer state is computed from the caller's participant row (1 read).
  $async.Future<GetBeaconResponse> getBeacon(
          $pb.ClientContext? ctx, GetBeaconRequest request) =>
      _client.invoke<GetBeaconResponse>(
          ctx, 'BeaconService', 'GetBeacon', request, GetBeaconResponse());

  /// OPEN and FULL beacons of one audience whose start_at >= from (default now), soonest first. Hidden beacons and
  /// beacons across a block with the caller are dropped (the caller's graph snapshot, 60 s). A community audience
  /// needs the caller JOINED (FORBIDDEN "not_member"). limit is clamped (0 = 20, above 50 = 50); page_token is an
  /// opaque signed cursor bound to the caller and the audience, VALIDATION "page_token" when invalid or expired.
  $async.Future<ListBeaconsResponse> listBeacons(
          $pb.ClientContext? ctx, ListBeaconsRequest request) =>
      _client.invoke<ListBeaconsResponse>(
          ctx, 'BeaconService', 'ListBeacons', request, ListBeaconsResponse());

  /// The caller's own beacons: organised, requested or accepted (role filter), UPCOMING (start_at + duration >= now,
  /// soonest first) or PAST (most recent first), from users/{uid}/beaconMemberships. A CANCELLED beacon keeps its window
  /// and renders status CANCELLED. Rows that ended in DECLINED, WITHDRAWN, LEFT or REMOVED, rows whose beacon is gone or
  /// hidden, and rows across a block with the organiser are left out (a page may be short while next_page_token is
  /// set). limit is clamped (0 = 20, above 50 = 50).
  $async.Future<ListMyBeaconsResponse> listMyBeacons(
          $pb.ClientContext? ctx, ListMyBeaconsRequest request) =>
      _client.invoke<ListMyBeaconsResponse>(ctx, 'BeaconService',
          'ListMyBeacons', request, ListMyBeaconsResponse());

  /// Ask to join an OPEN beacon the caller may see. The organiser may not join their own beacon
  /// (FAILED_PRECONDITION "organiser"). note 0-140 code points. A REQUESTED row
  /// already there => FAILED_PRECONDITION "already_requested"; an ACCEPTED one => success with the idempotency doc
  /// only; a DECLINED, WITHDRAWN, LEFT or REMOVED row may request again. At
  /// BEACONS_MAX_PENDING_REQUESTS (10) REQUESTED rows for the caller => LIMIT_REACHED "beacon_requests_pending". A
  /// FULL beacon => FAILED_PRECONDITION "full". The organiser is notified (NOTIFICATION_TYPE_BEACON_REQUEST).
  $async.Future<RequestToJoinResponse> requestToJoin(
          $pb.ClientContext? ctx, RequestToJoinRequest request) =>
      _client.invoke<RequestToJoinResponse>(ctx, 'BeaconService',
          'RequestToJoin', request, RequestToJoinResponse());

  /// Withdraw the caller's REQUESTED row (state WITHDRAWN), on a live, ENDED or CANCELLED beacon alike, so a stale
  /// request can always be cleared (it stops counting toward beacon_requests_pending once its beacon ended anyway). No
  /// row or any other state => FAILED_PRECONDITION "not_requested".
  $async.Future<WithdrawJoinRequestResponse> withdrawJoinRequest(
          $pb.ClientContext? ctx, WithdrawJoinRequestRequest request) =>
      _client.invoke<WithdrawJoinRequestResponse>(ctx, 'BeaconService',
          'WithdrawJoinRequest', request, WithdrawJoinRequestResponse());

  /// The organiser accepts or declines one REQUESTED row (any other caller => FORBIDDEN "not_organiser"; a row in any
  /// other state => FAILED_PRECONDITION "not_requested"). ACCEPT runs in one transaction with the beacon doc: when
  /// accepted_count == open_spots the answer is FAILED_PRECONDITION "full" and nothing is written; otherwise the row
  /// becomes ACCEPTED, accepted_count grows and the beacon turns FULL when it reaches open_spots. The requester is
  /// notified on ACCEPT only (NOTIFICATION_TYPE_BEACON_ACCEPTED).
  $async.Future<RespondToJoinRequestResponse> respondToJoinRequest(
          $pb.ClientContext? ctx, RespondToJoinRequestRequest request) =>
      _client.invoke<RespondToJoinRequestResponse>(ctx, 'BeaconService',
          'RespondToJoinRequest', request, RespondToJoinRequestResponse());

  /// Leave a beacon the caller is ACCEPTED on (state LEFT; accepted_count shrinks and a FULL beacon turns OPEN).
  /// Always allowed, never needs approval. Not ACCEPTED => FAILED_PRECONDITION "not_participant".
  $async.Future<LeaveBeaconResponse> leaveBeacon(
          $pb.ClientContext? ctx, LeaveBeaconRequest request) =>
      _client.invoke<LeaveBeaconResponse>(
          ctx, 'BeaconService', 'LeaveBeacon', request, LeaveBeaconResponse());

  /// The organiser removes an ACCEPTED participant (state REMOVED; same count rules as LeaveBeacon). Any other caller
  /// => FORBIDDEN "not_organiser"; not ACCEPTED => FAILED_PRECONDITION "not_participant".
  $async.Future<RemoveParticipantResponse> removeParticipant(
          $pb.ClientContext? ctx, RemoveParticipantRequest request) =>
      _client.invoke<RemoveParticipantResponse>(ctx, 'BeaconService',
          'RemoveParticipant', request, RemoveParticipantResponse());

  /// ACCEPTED participants (visible to the organiser and to ACCEPTED participants; anyone else => NOT_FOUND) or, for
  /// the organiser only, REQUESTED rows with their notes (anyone else => FORBIDDEN "not_organiser"). Live rows
  /// (identity directory, 60 s), oldest first. limit is clamped (0 = 20, above 50 = 50).
  $async.Future<ListParticipantsResponse> listParticipants(
          $pb.ClientContext? ctx, ListParticipantsRequest request) =>
      _client.invoke<ListParticipantsResponse>(ctx, 'BeaconService',
          'ListParticipants', request, ListParticipantsResponse());
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
