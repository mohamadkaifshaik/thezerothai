import '../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import '../../../shared/format/scheduled_time.dart';

/// Fixed user copy for the plan enums. A value this build does not
/// know (or UNSPECIFIED) reads as the generic one, never as an empty string.
String activityLabel(pb.BeaconActivity a) => switch (a) {
  pb.BeaconActivity.BEACON_ACTIVITY_COFFEE => 'Coffee',
  pb.BeaconActivity.BEACON_ACTIVITY_MEAL => 'Meal',
  pb.BeaconActivity.BEACON_ACTIVITY_STUDY => 'Study',
  pb.BeaconActivity.BEACON_ACTIVITY_SPORTS => 'Sports',
  pb.BeaconActivity.BEACON_ACTIVITY_WALK => 'Walk',
  pb.BeaconActivity.BEACON_ACTIVITY_SHOPPING => 'Shopping',
  pb.BeaconActivity.BEACON_ACTIVITY_OTHER => 'Other',
  _ => 'Plan',
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

/// `Sun, Oct 25, 2026 at 9:37 PM · 60 min`: the plan's start in the device
/// zone and its length.
String beaconWhenText(pb.Beacon b) =>
    '${formatScheduledTime(b.startAt.toDateTime())} · ${b.durationMinutes} min';

/// The privacy note of a plan's meeting point (`venue`): the create form's
/// helper and, under the venue line, the plan page at every width (tablet
/// plan section 3, R-inline). The proto only takes a named place.
const kMeetingPointNote = 'A named place, never coordinates.';

/// "Riya and 2 others are going": the first of [names] and the rest of
/// [total] ([names] is only the first page). With no names, "N are going".
String goingSentence(List<String> names, int total) {
  final count = total < names.length ? names.length : total;
  if (names.isEmpty) return count == 1 ? '1 is going' : '$count are going';
  final others = count - 1;
  if (others <= 0) return '${names.first} is going';
  return others == 1
      ? '${names.first} and 1 other are going'
      : '${names.first} and $others others are going';
}

/// `2 of 3 seats taken`.
String beaconSeatsText(pb.Beacon b) =>
    '${b.acceptedCount} of ${b.openSpots} seats taken';

String statusLabel(pb.BeaconStatus s) => switch (s) {
  pb.BeaconStatus.BEACON_STATUS_OPEN => 'Open',
  pb.BeaconStatus.BEACON_STATUS_FULL => 'Full',
  pb.BeaconStatus.BEACON_STATUS_CANCELLED => 'Cancelled',
  pb.BeaconStatus.BEACON_STATUS_ENDED => 'Ended',
  _ => 'Unknown',
};
