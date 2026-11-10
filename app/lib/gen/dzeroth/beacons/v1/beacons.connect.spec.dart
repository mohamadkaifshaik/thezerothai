//
//  Generated code. Do not modify.
//  source: dzeroth/beacons/v1/beacons.proto
//

import "package:connectrpc/connect.dart" as connect;
import "beacons.pb.dart" as dzerothbeaconsv1beacons;

abstract final class BeaconService {
  /// Fully-qualified name of the BeaconService service.
  static const name = 'dzeroth.beacons.v1.BeaconService';

  /// Create a beacon organised by the caller. audience: community_id (the caller must be a JOINED member) or
  /// public = true; neither or both => VALIDATION "audience". activity != UNSPECIFIED; start_at in [now + 5 min,
  /// now + 30 d]; duration_minutes 15-240; open_spots 1..BEACONS_MAX_OPEN_SPOTS; cost and chat_preference !=
  /// UNSPECIFIED. Text rules in the header. One transaction: idempotency doc, a count() of the caller's OPEN/FULL
  /// beacons (LIMIT_REACHED "beacons_open" at 5), the beacon doc with a fresh Snowflake id (status OPEN,
  /// accepted_count 0, eligibility EVERYONE) and the caller's beaconMemberships row (role ORGANISER).
  static const createBeacon = connect.Spec(
    '/$name/CreateBeacon',
    connect.StreamType.unary,
    dzerothbeaconsv1beacons.CreateBeaconRequest.new,
    dzerothbeaconsv1beacons.CreateBeaconResponse.new,
  );

  /// Change title, details, venue, open_spots, start_at, duration_minutes or cost of one of the caller's OPEN or FULL
  /// beacons (any other caller => FORBIDDEN "not_organiser"). open_spots may not go below accepted_count (VALIDATION
  /// "open_spots"); raising it turns FULL back into OPEN, lowering it to accepted_count turns OPEN into FULL.
  /// start_at, duration_minutes and cost follow the CreateBeacon rules (start_at in [now + 5 min, now + 30 d],
  /// duration_minutes 15-240, cost != UNSPECIFIED; else VALIDATION naming the field, before any lookup) and can only
  /// change before the beacon starts (now < the stored start_at, else FAILED_PRECONDITION "started"; resending the
  /// stored value is not a change). A new start_at or duration moves end, the TTL (expireAt) of the beacon and of every
  /// participant row, and start/end of every membership row, in the one transaction (at most 200 participant rows, else
  /// LIMIT_REACHED "beacon_edit_rows"). A change of any of the three keeps every participant as they are (accepted
  /// people stay and may LeaveBeacon) and notifies the ACCEPTED participants once per edit
  /// (NOTIFICATION_TYPE_BEACON_UPDATED). The audience stays immutable: cancel and create again. A request that changes
  /// nothing writes only the idempotency doc.
  static const updateBeacon = connect.Spec(
    '/$name/UpdateBeacon',
    connect.StreamType.unary,
    dzerothbeaconsv1beacons.UpdateBeaconRequest.new,
    dzerothbeaconsv1beacons.UpdateBeaconResponse.new,
  );

  /// Cancel one of the caller's OPEN or FULL beacons: status CANCELLED on the beacon only. Participant and membership
  /// rows are pointers and read the beacon's status (GetBeacon, ListMyBeacons), so nothing fans out. Participants are
  /// notified (NOTIFICATION_TYPE_BEACON_CANCELLED). Already CANCELLED => success with the idempotency doc only.
  static const cancelBeacon = connect.Spec(
    '/$name/CancelBeacon',
    connect.StreamType.unary,
    dzerothbeaconsv1beacons.CancelBeaconRequest.new,
    dzerothbeaconsv1beacons.CancelBeaconResponse.new,
  );

  /// One beacon as the caller may see it (audience, blocks and hidden applied; header). The organiser row is live
  /// (identity directory, 60 s); the viewer state is computed from the caller's participant row (1 read).
  static const getBeacon = connect.Spec(
    '/$name/GetBeacon',
    connect.StreamType.unary,
    dzerothbeaconsv1beacons.GetBeaconRequest.new,
    dzerothbeaconsv1beacons.GetBeaconResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// OPEN and FULL beacons of one audience whose start_at >= from (default now), soonest first, optionally of one
  /// activity (UNSPECIFIED = every activity; a value outside the enum => VALIDATION "activity", before any lookup).
  /// Hidden beacons and beacons across a block with the caller are dropped (the caller's graph snapshot, 60 s). A
  /// community audience needs the caller JOINED (FORBIDDEN "not_member"). limit is clamped (0 = 20, above 50 = 50);
  /// page_token is an opaque signed cursor bound to the caller, the audience and the activity filter, VALIDATION
  /// "page_token" when invalid, expired or issued for another filter.
  static const listBeacons = connect.Spec(
    '/$name/ListBeacons',
    connect.StreamType.unary,
    dzerothbeaconsv1beacons.ListBeaconsRequest.new,
    dzerothbeaconsv1beacons.ListBeaconsResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// The caller's own beacons: organised, requested or accepted (role filter), UPCOMING (start_at + duration >= now,
  /// soonest first) or PAST (most recent first), from users/{uid}/beaconMemberships. A CANCELLED beacon keeps its window
  /// and renders status CANCELLED. Rows that ended in DECLINED, WITHDRAWN, LEFT or REMOVED, rows whose beacon is gone or
  /// hidden, and rows across a block with the organiser are left out (a page may be short while next_page_token is
  /// set). limit is clamped (0 = 20, above 50 = 50).
  static const listMyBeacons = connect.Spec(
    '/$name/ListMyBeacons',
    connect.StreamType.unary,
    dzerothbeaconsv1beacons.ListMyBeaconsRequest.new,
    dzerothbeaconsv1beacons.ListMyBeaconsResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// Ask to join an OPEN beacon the caller may see. The organiser may not join their own beacon
  /// (FAILED_PRECONDITION "organiser"). note 0-140 code points. A REQUESTED row
  /// already there => FAILED_PRECONDITION "already_requested"; an ACCEPTED one => success with the idempotency doc
  /// only; a DECLINED, WITHDRAWN, LEFT or REMOVED row may request again. At
  /// BEACONS_MAX_PENDING_REQUESTS (10) REQUESTED rows for the caller => LIMIT_REACHED "beacon_requests_pending". A
  /// FULL beacon => FAILED_PRECONDITION "full". The organiser is notified (NOTIFICATION_TYPE_BEACON_REQUEST).
  static const requestToJoin = connect.Spec(
    '/$name/RequestToJoin',
    connect.StreamType.unary,
    dzerothbeaconsv1beacons.RequestToJoinRequest.new,
    dzerothbeaconsv1beacons.RequestToJoinResponse.new,
  );

  /// Withdraw the caller's REQUESTED row (state WITHDRAWN), on a live, ENDED or CANCELLED beacon alike, so a stale
  /// request can always be cleared (it stops counting toward beacon_requests_pending once its beacon ended anyway). The
  /// only gate is the caller's own row: a block, a hidden beacon or a community the caller left never prevents it. No
  /// row => NOT_FOUND (the one message above); any other state => FAILED_PRECONDITION "not_requested".
  static const withdrawJoinRequest = connect.Spec(
    '/$name/WithdrawJoinRequest',
    connect.StreamType.unary,
    dzerothbeaconsv1beacons.WithdrawJoinRequestRequest.new,
    dzerothbeaconsv1beacons.WithdrawJoinRequestResponse.new,
  );

  /// The organiser accepts or declines one REQUESTED row (any other caller => FORBIDDEN "not_organiser"; a row in any
  /// other state => FAILED_PRECONDITION "not_requested"). ACCEPT runs in one transaction with the beacon doc: when
  /// accepted_count == open_spots the answer is FAILED_PRECONDITION "full" and nothing is written; otherwise the row
  /// becomes ACCEPTED, accepted_count grows and the beacon turns FULL when it reaches open_spots. The requester is
  /// notified on ACCEPT only (NOTIFICATION_TYPE_BEACON_ACCEPTED).
  static const respondToJoinRequest = connect.Spec(
    '/$name/RespondToJoinRequest',
    connect.StreamType.unary,
    dzerothbeaconsv1beacons.RespondToJoinRequestRequest.new,
    dzerothbeaconsv1beacons.RespondToJoinRequestResponse.new,
  );

  /// Leave a beacon the caller is ACCEPTED on (state LEFT; accepted_count shrinks and a FULL beacon turns OPEN).
  /// Always allowed, never needs approval: the only gate is the caller's own row (a block, a hidden beacon or a
  /// community the caller left never prevents it). No row => NOT_FOUND (the one message above, even on an ENDED or
  /// CANCELLED beacon); ENDED or CANCELLED => "ended" | "cancelled"; not ACCEPTED => FAILED_PRECONDITION
  /// "not_participant".
  static const leaveBeacon = connect.Spec(
    '/$name/LeaveBeacon',
    connect.StreamType.unary,
    dzerothbeaconsv1beacons.LeaveBeaconRequest.new,
    dzerothbeaconsv1beacons.LeaveBeaconResponse.new,
  );

  /// The organiser removes an ACCEPTED participant (state REMOVED; same count rules as LeaveBeacon). Any other caller
  /// => FORBIDDEN "not_organiser"; not ACCEPTED => FAILED_PRECONDITION "not_participant".
  static const removeParticipant = connect.Spec(
    '/$name/RemoveParticipant',
    connect.StreamType.unary,
    dzerothbeaconsv1beacons.RemoveParticipantRequest.new,
    dzerothbeaconsv1beacons.RemoveParticipantResponse.new,
  );

  /// ACCEPTED participants (visible to the organiser and to ACCEPTED participants; anyone else => NOT_FOUND) or, for
  /// the organiser only, REQUESTED rows with their notes (anyone else => FORBIDDEN "not_organiser"). Live rows
  /// (identity directory, 60 s), oldest first. A participant does not see peers across a block in either direction
  /// (the organiser sees everyone), so a page may hold fewer rows than accepted_count. limit is clamped (0 = 20, above
  /// 50 = 50).
  static const listParticipants = connect.Spec(
    '/$name/ListParticipants',
    connect.StreamType.unary,
    dzerothbeaconsv1beacons.ListParticipantsRequest.new,
    dzerothbeaconsv1beacons.ListParticipantsResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );

  /// The upcoming (OPEN or FULL, not yet ended) beacons that the caller and peer_user_id are both in (as organiser or
  /// ACCEPTED participant), soonest first, for the "plans you share" strip of a chat. Needs FEATURE_CHAT_SHARED_PLANS on
  /// for the caller (else FAILED_PRECONDITION + FEATURE_DISABLED, metadata["feature"] = "chat_shared_plans", before any
  /// lookup) and FEATURE_BEACONS not globally off. A block in either direction with the peer, an unknown or non-ACTIVE
  /// peer, or no shared plan is an empty page (never an error, so nothing leaks). A beacon hidden by the platform and one
  /// whose organiser has a block with the caller are dropped as in ListMyBeacons; a community beacon is returned only
  /// while BOTH users are still JOINED members of its community (a viewer or peer who left or was banned drops it). The
  /// peer_user_id must be a valid user id and not the caller's (VALIDATION "peer_user_id"). limit is clamped (0 = 3, above
  /// 10 = 10). Each call examines at most 10 of the caller's upcoming memberships (soonest first) and answers the shared
  /// ones among them, so a page may hold fewer than limit rows, or none, while next_page_token is set; page_token is an
  /// opaque signed cursor bound to the caller and the peer, VALIDATION "page_token" when invalid or expired. Shares the
  /// RATE_LIMIT_BEACONS_READ_PER_MIN bucket.
  static const listSharedBeacons = connect.Spec(
    '/$name/ListSharedBeacons',
    connect.StreamType.unary,
    dzerothbeaconsv1beacons.ListSharedBeaconsRequest.new,
    dzerothbeaconsv1beacons.ListSharedBeaconsResponse.new,
    idempotency: connect.Idempotency.noSideEffects,
  );
}
