//
//  Generated code. Do not modify.
//  source: dzeroth/beacons/v1/beacons.proto
//

import "package:connectrpc/connect.dart" as connect;
import "beacons.pb.dart" as dzerothbeaconsv1beacons;
import "beacons.connect.spec.dart" as specs;

extension type BeaconServiceClient (connect.Transport _transport) {
  /// Create a beacon organised by the caller. audience: community_id (the caller must be a JOINED member) or
  /// public = true; neither or both => VALIDATION "audience". activity != UNSPECIFIED; start_at in [now + 5 min,
  /// now + 30 d]; duration_minutes 15-240; open_spots 1..BEACONS_MAX_OPEN_SPOTS; cost and chat_preference !=
  /// UNSPECIFIED. Text rules in the header. One transaction: idempotency doc, a count() of the caller's OPEN/FULL
  /// beacons (LIMIT_REACHED "beacons_open" at 5), the beacon doc with a fresh Snowflake id (status OPEN,
  /// accepted_count 0, eligibility EVERYONE) and the caller's beaconMemberships row (role ORGANISER).
  Future<dzerothbeaconsv1beacons.CreateBeaconResponse> createBeacon(
    dzerothbeaconsv1beacons.CreateBeaconRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.BeaconService.createBeacon,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Change title, details, venue or open_spots of one of the caller's OPEN or FULL beacons (any other caller =>
  /// FORBIDDEN "not_organiser"). open_spots may not go below accepted_count (VALIDATION "open_spots"); raising it
  /// turns FULL back into OPEN, lowering it to accepted_count turns OPEN into FULL. start_at, duration, cost and
  /// audience are immutable at v1: cancel and create again. A request that changes nothing writes only the
  /// idempotency doc.
  Future<dzerothbeaconsv1beacons.UpdateBeaconResponse> updateBeacon(
    dzerothbeaconsv1beacons.UpdateBeaconRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.BeaconService.updateBeacon,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Cancel one of the caller's OPEN or FULL beacons: status CANCELLED, every ACCEPTED and REQUESTED participant row
  /// and membership marked accordingly. Participants are notified (NOTIFICATION_TYPE_BEACON_CANCELLED). Already
  /// CANCELLED => success with the idempotency doc only.
  Future<dzerothbeaconsv1beacons.CancelBeaconResponse> cancelBeacon(
    dzerothbeaconsv1beacons.CancelBeaconRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.BeaconService.cancelBeacon,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// One beacon as the caller may see it (audience, blocks and hidden applied; header). The organiser row is live
  /// (identity directory, 60 s); the viewer state is computed from the caller's participant row (1 read).
  Future<dzerothbeaconsv1beacons.GetBeaconResponse> getBeacon(
    dzerothbeaconsv1beacons.GetBeaconRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.BeaconService.getBeacon,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// OPEN and FULL beacons of one audience whose start_at >= from (default now), soonest first. Hidden beacons and
  /// beacons across a block with the caller are dropped (the caller's graph snapshot, 60 s). A community audience
  /// needs the caller JOINED (FORBIDDEN "not_member"). limit 1-50 (default 20, else VALIDATION "limit"); page_token
  /// is an opaque signed cursor, VALIDATION "page_token" when invalid or expired.
  Future<dzerothbeaconsv1beacons.ListBeaconsResponse> listBeacons(
    dzerothbeaconsv1beacons.ListBeaconsRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.BeaconService.listBeacons,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// The caller's own beacons: organised, requested or accepted (role filter), UPCOMING (start_at + duration >= now,
  /// soonest first) or PAST (most recent first), from users/{uid}/beaconMemberships; CANCELLED beacons appear under
  /// PAST. limit 1-50, default 20.
  Future<dzerothbeaconsv1beacons.ListMyBeaconsResponse> listMyBeacons(
    dzerothbeaconsv1beacons.ListMyBeaconsRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.BeaconService.listMyBeacons,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Ask to join an OPEN beacon the caller may see and is not organising. note 0-140 code points. A REQUESTED row
  /// already there => FAILED_PRECONDITION "already_requested"; an ACCEPTED one => success with the idempotency doc
  /// only; a DECLINED, WITHDRAWN, LEFT or REMOVED row may request again. At
  /// BEACONS_MAX_PENDING_REQUESTS (10) REQUESTED rows for the caller => LIMIT_REACHED "beacon_requests_pending". A
  /// FULL beacon => FAILED_PRECONDITION "full". The organiser is notified (NOTIFICATION_TYPE_BEACON_REQUEST).
  Future<dzerothbeaconsv1beacons.RequestToJoinResponse> requestToJoin(
    dzerothbeaconsv1beacons.RequestToJoinRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.BeaconService.requestToJoin,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Withdraw the caller's REQUESTED row (state WITHDRAWN). No row or any other state => FAILED_PRECONDITION
  /// "not_requested".
  Future<dzerothbeaconsv1beacons.WithdrawJoinRequestResponse> withdrawJoinRequest(
    dzerothbeaconsv1beacons.WithdrawJoinRequestRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.BeaconService.withdrawJoinRequest,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// The organiser accepts or declines one REQUESTED row (any other caller => FORBIDDEN "not_organiser"; a row in any
  /// other state => FAILED_PRECONDITION "not_requested"). ACCEPT runs in one transaction with the beacon doc: when
  /// accepted_count == open_spots the answer is FAILED_PRECONDITION "full" and nothing is written; otherwise the row
  /// becomes ACCEPTED, accepted_count grows and the beacon turns FULL when it reaches open_spots. The requester is
  /// notified on ACCEPT only (NOTIFICATION_TYPE_BEACON_ACCEPTED).
  Future<dzerothbeaconsv1beacons.RespondToJoinRequestResponse> respondToJoinRequest(
    dzerothbeaconsv1beacons.RespondToJoinRequestRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.BeaconService.respondToJoinRequest,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// Leave a beacon the caller is ACCEPTED on (state LEFT; accepted_count shrinks and a FULL beacon turns OPEN).
  /// Always allowed, never needs approval. Not ACCEPTED => FAILED_PRECONDITION "not_participant".
  Future<dzerothbeaconsv1beacons.LeaveBeaconResponse> leaveBeacon(
    dzerothbeaconsv1beacons.LeaveBeaconRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.BeaconService.leaveBeacon,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// The organiser removes an ACCEPTED participant (state REMOVED; same count rules as LeaveBeacon). Any other caller
  /// => FORBIDDEN "not_organiser"; not ACCEPTED => FAILED_PRECONDITION "not_participant".
  Future<dzerothbeaconsv1beacons.RemoveParticipantResponse> removeParticipant(
    dzerothbeaconsv1beacons.RemoveParticipantRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.BeaconService.removeParticipant,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }

  /// ACCEPTED participants (visible to the organiser and to ACCEPTED participants; anyone else => NOT_FOUND) or, for
  /// the organiser only, REQUESTED rows with their notes (anyone else => FORBIDDEN "not_organiser"). Live rows
  /// (identity directory, 60 s), oldest first. limit 1-50, default 20.
  Future<dzerothbeaconsv1beacons.ListParticipantsResponse> listParticipants(
    dzerothbeaconsv1beacons.ListParticipantsRequest input, {
    connect.Headers? headers,
    connect.AbortSignal? signal,
    Function(connect.Headers)? onHeader,
    Function(connect.Headers)? onTrailer,
  }) {
    return connect.Client(_transport).unary(
      specs.BeaconService.listParticipants,
      input,
      signal: signal,
      headers: headers,
      onHeader: onHeader,
      onTrailer: onTrailer,
    );
  }
}
