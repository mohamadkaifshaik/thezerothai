import 'package:flutter/material.dart';

import '../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;

/// The icon for a plan's activity. An unknown or UNSPECIFIED value reads as
/// the generic event icon.
IconData activityIcon(pb.BeaconActivity a) => switch (a) {
  pb.BeaconActivity.BEACON_ACTIVITY_COFFEE => Icons.local_cafe_outlined,
  pb.BeaconActivity.BEACON_ACTIVITY_MEAL => Icons.restaurant_outlined,
  pb.BeaconActivity.BEACON_ACTIVITY_STUDY => Icons.menu_book_outlined,
  pb.BeaconActivity.BEACON_ACTIVITY_SPORTS => Icons.sports_basketball_outlined,
  pb.BeaconActivity.BEACON_ACTIVITY_WALK => Icons.directions_walk,
  pb.BeaconActivity.BEACON_ACTIVITY_SHOPPING => Icons.shopping_bag_outlined,
  _ => Icons.event_outlined,
};
