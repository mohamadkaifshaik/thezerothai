import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart'
    as ts;

import '../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import '../../../gen/dzeroth/common/v1/common.pb.dart' as common;
import '../../lists/domain/list_text_rules.dart' show normalizeListText;

/// The stored status of a live plan (OPEN or FULL) for [accepted] people
/// going and [openSpots] seats: FULL when every seat is taken, OPEN
/// otherwise. The server's own rule (`liveStatus` in the beacons repository),
/// applied on create and on every update.
pb.BeaconStatus beaconLiveStatus(int accepted, int openSpots) =>
    accepted >= openSpots
    ? pb.BeaconStatus.BEACON_STATUS_FULL
    : pb.BeaconStatus.BEACON_STATUS_OPEN;

/// The plan a create form would make, for its preview (tablet plan section
/// 4.1, PlanCreate): the fields as the server stores them (text trimmed and
/// NFC), nobody going yet, OPEN, and the caller as the organiser when the
/// profile is loaded ([organiser] null: none). Built from the form only; no
/// call.
pb.Beacon draftPlan({
  required pb.BeaconActivity activity,
  required String title,
  required String details,
  required String venue,
  required DateTime startAt,
  required int durationMinutes,
  required int openSpots,
  required pb.BeaconCost cost,
  required pb.ChatPreference chatPreference,
  common.AuthorSnapshot? organiser,
}) => pb.Beacon(
  activity: activity,
  title: normalizeListText(title),
  details: normalizeListText(details),
  venue: normalizeListText(venue),
  startAt: ts.Timestamp.fromDateTime(startAt.toUtc()),
  durationMinutes: durationMinutes,
  openSpots: openSpots,
  acceptedCount: 0,
  cost: cost,
  chatPreference: chatPreference,
  status: beaconLiveStatus(0, openSpots),
  organiser: organiser,
);

/// [loaded] with the edit form's fields (the `UpdateBeacon` fields this
/// client sends: title, details, meeting point, open spots), for its
/// preview (tablet plan section 4.1, PlanEdit). A live plan's status follows
/// the new seat count as the server's does; a cancelled or ended one keeps
/// its own. [loaded] is not changed.
pb.Beacon editedPlan(
  pb.Beacon loaded, {
  required String title,
  required String details,
  required String venue,
  required int openSpots,
}) {
  final live =
      loaded.status == pb.BeaconStatus.BEACON_STATUS_OPEN ||
      loaded.status == pb.BeaconStatus.BEACON_STATUS_FULL;
  return loaded.deepCopy()
    ..title = normalizeListText(title)
    ..details = normalizeListText(details)
    ..venue = normalizeListText(venue)
    ..openSpots = openSpots
    ..status = live
        ? beaconLiveStatus(loaded.acceptedCount, openSpots)
        : loaded.status;
}
