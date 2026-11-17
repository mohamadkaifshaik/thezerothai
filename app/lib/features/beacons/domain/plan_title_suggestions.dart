import '../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;

/// Short starter titles per activity (static copy, nothing is fetched). Each
/// is well inside the title limit.
List<String> planTitleSuggestions(pb.BeaconActivity activity) =>
    switch (activity) {
      pb.BeaconActivity.BEACON_ACTIVITY_COFFEE => const [
        'Coffee and a chat',
        'Quick coffee break',
      ],
      pb.BeaconActivity.BEACON_ACTIVITY_MEAL => const [
        'Lunch together',
        'Dinner and conversation',
      ],
      pb.BeaconActivity.BEACON_ACTIVITY_STUDY => const [
        'Study session',
        'Library study group',
      ],
      pb.BeaconActivity.BEACON_ACTIVITY_SPORTS => const [
        'Pickup game',
        'Evening workout',
      ],
      pb.BeaconActivity.BEACON_ACTIVITY_WALK => const [
        'Evening walk',
        'Walk and talk',
      ],
      pb.BeaconActivity.BEACON_ACTIVITY_SHOPPING => const [
        'Shopping trip',
        'Market run together',
      ],
      _ => const [],
    };
