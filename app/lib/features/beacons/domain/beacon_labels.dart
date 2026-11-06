import 'package:flutter/material.dart';

import '../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;

/// Fixed user copy and icons for the plan enums. A value this build does not
/// know (or UNSPECIFIED) reads as the generic one, never as an empty string.
String activityLabel(pb.BeaconActivity a) => switch (a) {
  pb.BeaconActivity.BEACON_ACTIVITY_COFFEE => 'Coffee',
  pb.BeaconActivity.BEACON_ACTIVITY_MEAL => 'Meal',
  pb.BeaconActivity.BEACON_ACTIVITY_STUDY => 'Study',
  pb.BeaconActivity.BEACON_ACTIVITY_SPORTS => 'Sports',
  pb.BeaconActivity.BEACON_ACTIVITY_WALK => 'Walk',
  pb.BeaconActivity.BEACON_ACTIVITY_SHOPPING => 'Shopping',
  _ => 'Plan',
};

IconData activityIcon(pb.BeaconActivity a) => switch (a) {
  pb.BeaconActivity.BEACON_ACTIVITY_COFFEE => Icons.local_cafe_outlined,
  pb.BeaconActivity.BEACON_ACTIVITY_MEAL => Icons.restaurant_outlined,
  pb.BeaconActivity.BEACON_ACTIVITY_STUDY => Icons.menu_book_outlined,
  pb.BeaconActivity.BEACON_ACTIVITY_SPORTS => Icons.sports_basketball_outlined,
  pb.BeaconActivity.BEACON_ACTIVITY_WALK => Icons.directions_walk,
  pb.BeaconActivity.BEACON_ACTIVITY_SHOPPING => Icons.shopping_bag_outlined,
  _ => Icons.event_outlined,
};

String costLabel(pb.BeaconCost c) => switch (c) {
  pb.BeaconCost.BEACON_COST_FREE => 'Free',
  pb.BeaconCost.BEACON_COST_EVERYONE_PAYS_OWN => 'Everyone pays their own',
  pb.BeaconCost.BEACON_COST_SPLIT_EVENLY => 'Split evenly',
  _ => 'Cost not set',
};

String chatPreferenceLabel(pb.ChatPreference p) => switch (p) {
  pb.ChatPreference.CHAT_PREFERENCE_QUIET => 'Quiet',
  pb.ChatPreference.CHAT_PREFERENCE_TASK_FOCUSED => 'Task-focused',
  pb.ChatPreference.CHAT_PREFERENCE_OPEN_TO_CHAT => 'Open to chat',
  _ => 'No preference',
};

String statusLabel(pb.BeaconStatus s) => switch (s) {
  pb.BeaconStatus.BEACON_STATUS_OPEN => 'Open',
  pb.BeaconStatus.BEACON_STATUS_FULL => 'Full',
  pb.BeaconStatus.BEACON_STATUS_CANCELLED => 'Cancelled',
  pb.BeaconStatus.BEACON_STATUS_ENDED => 'Ended',
  _ => 'Unknown',
};
