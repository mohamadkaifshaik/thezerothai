import 'package:dzeroth/features/beacons/domain/beacon_labels.dart';
import 'package:dzeroth/gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every enum value the server can send has fixed user copy; an unknown or
/// unspecified value reads as the generic one, never as an empty string.
void main() {
  test('activities have a label and an icon', () {
    for (final a in pb.BeaconActivity.values) {
      expect(activityLabel(a), isNotEmpty, reason: a.name);
      expect(activityIcon(a), isA<IconData>(), reason: a.name);
    }
    expect(activityLabel(pb.BeaconActivity.BEACON_ACTIVITY_COFFEE), 'Coffee');
    expect(
      activityLabel(pb.BeaconActivity.BEACON_ACTIVITY_UNSPECIFIED),
      'Plan',
    );
    expect(activityLabel(pb.BeaconActivity.BEACON_ACTIVITY_OTHER), 'Plan');
  });

  test('cost and chat preference', () {
    for (final c in pb.BeaconCost.values) {
      expect(costLabel(c), isNotEmpty, reason: c.name);
    }
    for (final p in pb.ChatPreference.values) {
      expect(chatPreferenceLabel(p), isNotEmpty, reason: p.name);
    }
    expect(costLabel(pb.BeaconCost.BEACON_COST_FREE), 'Free');
    expect(
      costLabel(pb.BeaconCost.BEACON_COST_EVERYONE_PAYS_OWN),
      'Everyone pays their own',
    );
    expect(costLabel(pb.BeaconCost.BEACON_COST_SPLIT_EVENLY), 'Split evenly');
    expect(
      chatPreferenceLabel(pb.ChatPreference.CHAT_PREFERENCE_QUIET),
      'Quiet',
    );
    expect(
      chatPreferenceLabel(pb.ChatPreference.CHAT_PREFERENCE_TASK_FOCUSED),
      'Task-focused',
    );
    expect(
      chatPreferenceLabel(pb.ChatPreference.CHAT_PREFERENCE_OPEN_TO_CHAT),
      'Open to chat',
    );
  });

  test('status', () {
    expect(statusLabel(pb.BeaconStatus.BEACON_STATUS_OPEN), 'Open');
    expect(statusLabel(pb.BeaconStatus.BEACON_STATUS_FULL), 'Full');
    expect(statusLabel(pb.BeaconStatus.BEACON_STATUS_CANCELLED), 'Cancelled');
    expect(statusLabel(pb.BeaconStatus.BEACON_STATUS_ENDED), 'Ended');
    expect(statusLabel(pb.BeaconStatus.BEACON_STATUS_UNSPECIFIED), isNotEmpty);
  });
}
