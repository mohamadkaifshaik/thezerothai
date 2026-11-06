import 'package:flutter/material.dart';

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
      tone: status == pb.BeaconStatus.BEACON_STATUS_FULL
          ? AppStatusTone.info
          : AppStatusTone.neutral,
    );
  }
}
