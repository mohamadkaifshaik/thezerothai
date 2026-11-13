import 'package:dzeroth/gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart'
    as ts;

const kBeaconIdA = '1234567890123456789';
const kBeaconIdB = '1234567890123456790';

/// One `BeaconView` as the server would answer it. [startAt] is required so
/// every fixture is built from the test's own clock (fixed-date guard).
pb.BeaconView beaconView({
  required DateTime startAt,
  String id = kBeaconIdA,
  String title = 'Coffee',
  String details = '',
  String venue = 'Hall',
  pb.BeaconActivity activity = pb.BeaconActivity.BEACON_ACTIVITY_COFFEE,
  pb.BeaconStatus status = pb.BeaconStatus.BEACON_STATUS_OPEN,
  int durationMinutes = 60,
  int openSpots = 3,
  int accepted = 0,
  pb.BeaconCost cost = pb.BeaconCost.BEACON_COST_FREE,
  pb.ChatPreference chat = pb.ChatPreference.CHAT_PREFERENCE_QUIET,
  String communityId = '',
  bool hidden = false,
  bool canManage = false,
  bool quickJoin = false,
  String organiserId = 'org',
  String organiserHandle = 'org',
  String organiserName = 'Orla',
}) => pb.BeaconView(
  beacon: pb.Beacon(
    beaconId: id,
    organiser: common.AuthorSnapshot(
      userId: organiserId,
      handle: organiserHandle,
      displayName: organiserName,
    ),
    communityId: communityId,
    activity: activity,
    title: title,
    details: details,
    venue: venue,
    startAt: ts.Timestamp.fromDateTime(startAt.toUtc()),
    durationMinutes: durationMinutes,
    openSpots: openSpots,
    acceptedCount: accepted,
    cost: cost,
    chatPreference: chat,
    eligibility: pb.BeaconEligibility.BEACON_ELIGIBILITY_EVERYONE,
    status: status,
    hidden: hidden,
  ),
  viewer: pb.ViewerState(
    role: canManage
        ? pb.ViewerRole.VIEWER_ROLE_ORGANISER
        : pb.ViewerRole.VIEWER_ROLE_NONE,
    canManage: canManage,
    canRequest: !canManage && status == pb.BeaconStatus.BEACON_STATUS_OPEN,
    quickJoinAllowed:
        quickJoin && !canManage && status == pb.BeaconStatus.BEACON_STATUS_OPEN,
  ),
);

/// One participant row as ListParticipants answers it.
pb.Participant participant({
  required String userId,
  String? handle,
  String? name,
  pb.ParticipantState state = pb.ParticipantState.PARTICIPANT_STATE_ACCEPTED,
  String note = '',
}) => pb.Participant(
  user: common.AuthorSnapshot(
    userId: userId,
    handle: handle ?? userId,
    displayName: name ?? userId,
  ),
  state: state,
  note: note,
);
