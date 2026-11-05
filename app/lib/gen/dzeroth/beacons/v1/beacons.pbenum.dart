// This is a generated file - do not edit.
//
// Generated from dzeroth/beacons/v1/beacons.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

class BeaconActivity extends $pb.ProtobufEnum {
  static const BeaconActivity BEACON_ACTIVITY_UNSPECIFIED =
      BeaconActivity._(0, _omitEnumNames ? '' : 'BEACON_ACTIVITY_UNSPECIFIED');
  static const BeaconActivity BEACON_ACTIVITY_COFFEE =
      BeaconActivity._(1, _omitEnumNames ? '' : 'BEACON_ACTIVITY_COFFEE');
  static const BeaconActivity BEACON_ACTIVITY_MEAL =
      BeaconActivity._(2, _omitEnumNames ? '' : 'BEACON_ACTIVITY_MEAL');
  static const BeaconActivity BEACON_ACTIVITY_STUDY =
      BeaconActivity._(3, _omitEnumNames ? '' : 'BEACON_ACTIVITY_STUDY');
  static const BeaconActivity BEACON_ACTIVITY_SPORTS =
      BeaconActivity._(4, _omitEnumNames ? '' : 'BEACON_ACTIVITY_SPORTS');
  static const BeaconActivity BEACON_ACTIVITY_WALK =
      BeaconActivity._(5, _omitEnumNames ? '' : 'BEACON_ACTIVITY_WALK');
  static const BeaconActivity BEACON_ACTIVITY_SHOPPING =
      BeaconActivity._(6, _omitEnumNames ? '' : 'BEACON_ACTIVITY_SHOPPING');
  static const BeaconActivity BEACON_ACTIVITY_OTHER =
      BeaconActivity._(7, _omitEnumNames ? '' : 'BEACON_ACTIVITY_OTHER');

  static const $core.List<BeaconActivity> values = <BeaconActivity>[
    BEACON_ACTIVITY_UNSPECIFIED,
    BEACON_ACTIVITY_COFFEE,
    BEACON_ACTIVITY_MEAL,
    BEACON_ACTIVITY_STUDY,
    BEACON_ACTIVITY_SPORTS,
    BEACON_ACTIVITY_WALK,
    BEACON_ACTIVITY_SHOPPING,
    BEACON_ACTIVITY_OTHER,
  ];

  static final $core.List<BeaconActivity?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 7);
  static BeaconActivity? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const BeaconActivity._(super.value, super.name);
}

class BeaconStatus extends $pb.ProtobufEnum {
  static const BeaconStatus BEACON_STATUS_UNSPECIFIED =
      BeaconStatus._(0, _omitEnumNames ? '' : 'BEACON_STATUS_UNSPECIFIED');
  static const BeaconStatus BEACON_STATUS_OPEN =
      BeaconStatus._(1, _omitEnumNames ? '' : 'BEACON_STATUS_OPEN');
  static const BeaconStatus BEACON_STATUS_FULL =
      BeaconStatus._(2, _omitEnumNames ? '' : 'BEACON_STATUS_FULL');
  static const BeaconStatus BEACON_STATUS_CANCELLED =
      BeaconStatus._(3, _omitEnumNames ? '' : 'BEACON_STATUS_CANCELLED');

  /// Derived at read time: now >= start_at + duration_minutes. Never stored.
  static const BeaconStatus BEACON_STATUS_ENDED =
      BeaconStatus._(4, _omitEnumNames ? '' : 'BEACON_STATUS_ENDED');

  static const $core.List<BeaconStatus> values = <BeaconStatus>[
    BEACON_STATUS_UNSPECIFIED,
    BEACON_STATUS_OPEN,
    BEACON_STATUS_FULL,
    BEACON_STATUS_CANCELLED,
    BEACON_STATUS_ENDED,
  ];

  static final $core.List<BeaconStatus?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 4);
  static BeaconStatus? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const BeaconStatus._(super.value, super.name);
}

class BeaconCost extends $pb.ProtobufEnum {
  static const BeaconCost BEACON_COST_UNSPECIFIED =
      BeaconCost._(0, _omitEnumNames ? '' : 'BEACON_COST_UNSPECIFIED');
  static const BeaconCost BEACON_COST_FREE =
      BeaconCost._(1, _omitEnumNames ? '' : 'BEACON_COST_FREE');
  static const BeaconCost BEACON_COST_EVERYONE_PAYS_OWN =
      BeaconCost._(2, _omitEnumNames ? '' : 'BEACON_COST_EVERYONE_PAYS_OWN');
  static const BeaconCost BEACON_COST_SPLIT_EVENLY =
      BeaconCost._(3, _omitEnumNames ? '' : 'BEACON_COST_SPLIT_EVENLY');

  static const $core.List<BeaconCost> values = <BeaconCost>[
    BEACON_COST_UNSPECIFIED,
    BEACON_COST_FREE,
    BEACON_COST_EVERYONE_PAYS_OWN,
    BEACON_COST_SPLIT_EVENLY,
  ];

  static final $core.List<BeaconCost?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 3);
  static BeaconCost? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const BeaconCost._(super.value, super.name);
}

/// An expectation shown on the beacon, never enforced: people may change it or leave at any time.
class ChatPreference extends $pb.ProtobufEnum {
  static const ChatPreference CHAT_PREFERENCE_UNSPECIFIED =
      ChatPreference._(0, _omitEnumNames ? '' : 'CHAT_PREFERENCE_UNSPECIFIED');
  static const ChatPreference CHAT_PREFERENCE_QUIET =
      ChatPreference._(1, _omitEnumNames ? '' : 'CHAT_PREFERENCE_QUIET');
  static const ChatPreference CHAT_PREFERENCE_TASK_FOCUSED =
      ChatPreference._(2, _omitEnumNames ? '' : 'CHAT_PREFERENCE_TASK_FOCUSED');
  static const ChatPreference CHAT_PREFERENCE_OPEN_TO_CHAT =
      ChatPreference._(3, _omitEnumNames ? '' : 'CHAT_PREFERENCE_OPEN_TO_CHAT');

  static const $core.List<ChatPreference> values = <ChatPreference>[
    CHAT_PREFERENCE_UNSPECIFIED,
    CHAT_PREFERENCE_QUIET,
    CHAT_PREFERENCE_TASK_FOCUSED,
    CHAT_PREFERENCE_OPEN_TO_CHAT,
  ];

  static final $core.List<ChatPreference?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 3);
  static ChatPreference? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const ChatPreference._(super.value, super.name);
}

/// Who may request to join. Only EVERYONE exists at v1 (docs/beacons-plan.md D4); a restricted value needs a profile
/// field and its own ADR.
class BeaconEligibility extends $pb.ProtobufEnum {
  static const BeaconEligibility BEACON_ELIGIBILITY_UNSPECIFIED =
      BeaconEligibility._(
          0, _omitEnumNames ? '' : 'BEACON_ELIGIBILITY_UNSPECIFIED');
  static const BeaconEligibility BEACON_ELIGIBILITY_EVERYONE =
      BeaconEligibility._(
          1, _omitEnumNames ? '' : 'BEACON_ELIGIBILITY_EVERYONE');

  static const $core.List<BeaconEligibility> values = <BeaconEligibility>[
    BEACON_ELIGIBILITY_UNSPECIFIED,
    BEACON_ELIGIBILITY_EVERYONE,
  ];

  static final $core.List<BeaconEligibility?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 1);
  static BeaconEligibility? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const BeaconEligibility._(super.value, super.name);
}

class ParticipantState extends $pb.ProtobufEnum {
  static const ParticipantState PARTICIPANT_STATE_UNSPECIFIED =
      ParticipantState._(
          0, _omitEnumNames ? '' : 'PARTICIPANT_STATE_UNSPECIFIED');
  static const ParticipantState PARTICIPANT_STATE_REQUESTED =
      ParticipantState._(
          1, _omitEnumNames ? '' : 'PARTICIPANT_STATE_REQUESTED');
  static const ParticipantState PARTICIPANT_STATE_ACCEPTED =
      ParticipantState._(2, _omitEnumNames ? '' : 'PARTICIPANT_STATE_ACCEPTED');
  static const ParticipantState PARTICIPANT_STATE_DECLINED =
      ParticipantState._(3, _omitEnumNames ? '' : 'PARTICIPANT_STATE_DECLINED');
  static const ParticipantState PARTICIPANT_STATE_WITHDRAWN =
      ParticipantState._(
          4, _omitEnumNames ? '' : 'PARTICIPANT_STATE_WITHDRAWN');
  static const ParticipantState PARTICIPANT_STATE_LEFT =
      ParticipantState._(5, _omitEnumNames ? '' : 'PARTICIPANT_STATE_LEFT');
  static const ParticipantState PARTICIPANT_STATE_REMOVED =
      ParticipantState._(6, _omitEnumNames ? '' : 'PARTICIPANT_STATE_REMOVED');

  static const $core.List<ParticipantState> values = <ParticipantState>[
    PARTICIPANT_STATE_UNSPECIFIED,
    PARTICIPANT_STATE_REQUESTED,
    PARTICIPANT_STATE_ACCEPTED,
    PARTICIPANT_STATE_DECLINED,
    PARTICIPANT_STATE_WITHDRAWN,
    PARTICIPANT_STATE_LEFT,
    PARTICIPANT_STATE_REMOVED,
  ];

  static final $core.List<ParticipantState?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 6);
  static ParticipantState? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const ParticipantState._(super.value, super.name);
}

class ViewerRole extends $pb.ProtobufEnum {
  static const ViewerRole VIEWER_ROLE_UNSPECIFIED =
      ViewerRole._(0, _omitEnumNames ? '' : 'VIEWER_ROLE_UNSPECIFIED');
  static const ViewerRole VIEWER_ROLE_NONE =
      ViewerRole._(1, _omitEnumNames ? '' : 'VIEWER_ROLE_NONE');
  static const ViewerRole VIEWER_ROLE_ORGANISER =
      ViewerRole._(2, _omitEnumNames ? '' : 'VIEWER_ROLE_ORGANISER');
  static const ViewerRole VIEWER_ROLE_PARTICIPANT =
      ViewerRole._(3, _omitEnumNames ? '' : 'VIEWER_ROLE_PARTICIPANT');

  static const $core.List<ViewerRole> values = <ViewerRole>[
    VIEWER_ROLE_UNSPECIFIED,
    VIEWER_ROLE_NONE,
    VIEWER_ROLE_ORGANISER,
    VIEWER_ROLE_PARTICIPANT,
  ];

  static final $core.List<ViewerRole?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 3);
  static ViewerRole? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const ViewerRole._(super.value, super.name);
}

class JoinResponse extends $pb.ProtobufEnum {
  static const JoinResponse JOIN_RESPONSE_UNSPECIFIED =
      JoinResponse._(0, _omitEnumNames ? '' : 'JOIN_RESPONSE_UNSPECIFIED');
  static const JoinResponse JOIN_RESPONSE_ACCEPT =
      JoinResponse._(1, _omitEnumNames ? '' : 'JOIN_RESPONSE_ACCEPT');
  static const JoinResponse JOIN_RESPONSE_DECLINE =
      JoinResponse._(2, _omitEnumNames ? '' : 'JOIN_RESPONSE_DECLINE');

  static const $core.List<JoinResponse> values = <JoinResponse>[
    JOIN_RESPONSE_UNSPECIFIED,
    JOIN_RESPONSE_ACCEPT,
    JOIN_RESPONSE_DECLINE,
  ];

  static final $core.List<JoinResponse?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 2);
  static JoinResponse? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const JoinResponse._(super.value, super.name);
}

class MyBeaconsRole extends $pb.ProtobufEnum {
  /// Same as ALL.
  static const MyBeaconsRole MY_BEACONS_ROLE_UNSPECIFIED =
      MyBeaconsRole._(0, _omitEnumNames ? '' : 'MY_BEACONS_ROLE_UNSPECIFIED');
  static const MyBeaconsRole MY_BEACONS_ROLE_ALL =
      MyBeaconsRole._(1, _omitEnumNames ? '' : 'MY_BEACONS_ROLE_ALL');
  static const MyBeaconsRole MY_BEACONS_ROLE_ORGANISER =
      MyBeaconsRole._(2, _omitEnumNames ? '' : 'MY_BEACONS_ROLE_ORGANISER');
  static const MyBeaconsRole MY_BEACONS_ROLE_PARTICIPANT =
      MyBeaconsRole._(3, _omitEnumNames ? '' : 'MY_BEACONS_ROLE_PARTICIPANT');

  static const $core.List<MyBeaconsRole> values = <MyBeaconsRole>[
    MY_BEACONS_ROLE_UNSPECIFIED,
    MY_BEACONS_ROLE_ALL,
    MY_BEACONS_ROLE_ORGANISER,
    MY_BEACONS_ROLE_PARTICIPANT,
  ];

  static final $core.List<MyBeaconsRole?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 3);
  static MyBeaconsRole? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const MyBeaconsRole._(super.value, super.name);
}

class MyBeaconsWindow extends $pb.ProtobufEnum {
  /// Same as UPCOMING.
  static const MyBeaconsWindow MY_BEACONS_WINDOW_UNSPECIFIED =
      MyBeaconsWindow._(
          0, _omitEnumNames ? '' : 'MY_BEACONS_WINDOW_UNSPECIFIED');
  static const MyBeaconsWindow MY_BEACONS_WINDOW_UPCOMING =
      MyBeaconsWindow._(1, _omitEnumNames ? '' : 'MY_BEACONS_WINDOW_UPCOMING');
  static const MyBeaconsWindow MY_BEACONS_WINDOW_PAST =
      MyBeaconsWindow._(2, _omitEnumNames ? '' : 'MY_BEACONS_WINDOW_PAST');

  static const $core.List<MyBeaconsWindow> values = <MyBeaconsWindow>[
    MY_BEACONS_WINDOW_UNSPECIFIED,
    MY_BEACONS_WINDOW_UPCOMING,
    MY_BEACONS_WINDOW_PAST,
  ];

  static final $core.List<MyBeaconsWindow?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 2);
  static MyBeaconsWindow? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const MyBeaconsWindow._(super.value, super.name);
}

class ParticipantFilter extends $pb.ProtobufEnum {
  /// Same as ACCEPTED.
  static const ParticipantFilter PARTICIPANT_FILTER_UNSPECIFIED =
      ParticipantFilter._(
          0, _omitEnumNames ? '' : 'PARTICIPANT_FILTER_UNSPECIFIED');
  static const ParticipantFilter PARTICIPANT_FILTER_ACCEPTED =
      ParticipantFilter._(
          1, _omitEnumNames ? '' : 'PARTICIPANT_FILTER_ACCEPTED');

  /// Organiser only.
  static const ParticipantFilter PARTICIPANT_FILTER_REQUESTED =
      ParticipantFilter._(
          2, _omitEnumNames ? '' : 'PARTICIPANT_FILTER_REQUESTED');

  static const $core.List<ParticipantFilter> values = <ParticipantFilter>[
    PARTICIPANT_FILTER_UNSPECIFIED,
    PARTICIPANT_FILTER_ACCEPTED,
    PARTICIPANT_FILTER_REQUESTED,
  ];

  static final $core.List<ParticipantFilter?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 2);
  static ParticipantFilter? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const ParticipantFilter._(super.value, super.name);
}

const $core.bool _omitEnumNames =
    $core.bool.fromEnvironment('protobuf.omit_enum_names');
