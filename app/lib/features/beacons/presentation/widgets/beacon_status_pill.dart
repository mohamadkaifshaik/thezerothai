import 'package:material_ui/material_ui.dart';

import '../../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import '../../../../shared/widgets/primitives/app_status_pill.dart';
import '../../domain/beacon_labels.dart';

/// The plan's status as the server sent it: nothing for OPEN (the default),
/// "Full", "Cancelled" or "Ended" otherwise. Never derived from the clock.
class BeaconStatusPill extends StatelessWidget {
  const BeaconStatusPill({super.key, required this.status});

  final pb.BeaconStatus status;

  @override
  Widget build(BuildContext context) {
    if (status == pb.BeaconStatus.BEACON_STATUS_OPEN) {
      return const SizedBox.shrink();
    }
    return AppStatusPill(
      label: statusLabel(status),
      tone: beaconStatusTone(status),
    );
  }
}

/// The pill tone of a non-OPEN status: Full is info, Ended is the error red,
/// the rest neutral.
AppStatusTone beaconStatusTone(pb.BeaconStatus status) => switch (status) {
  pb.BeaconStatus.BEACON_STATUS_FULL => AppStatusTone.info,
  pb.BeaconStatus.BEACON_STATUS_ENDED => AppStatusTone.danger,
  _ => AppStatusTone.neutral,
};
