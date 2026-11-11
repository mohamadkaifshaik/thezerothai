import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/beacons/data/beacons_repository.dart';
import 'package:dzeroth/gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:flutter_test/flutter_test.dart';

/// A [BeaconsRepository] that behaves like the backend for the rules the
/// Plans screens depend on: one list per audience paged by 20, GetBeacon of an
/// unknown id is NOT_FOUND, CreateBeacon answers an OPEN view with a fresh
/// 19-digit id, CancelBeacon flips the stored view to CANCELLED; a request
/// adds a REQUESTED row for [viewerId] and the view's viewer state follows
/// (can_withdraw), withdraw and leave end it, accept moves the row to going
/// and grows accepted_count (FULL at open_spots), decline and remove drop the
/// row, update applies the set fields and recomputes OPEN/FULL. Every call
/// first throws the next [refusals] entry, if any (a refusal creates nothing).
class FakeBeaconsServer extends Fake implements BeaconsRepository {
  /// Thrown by the next calls before anything is committed, one per call.
  final List<AppException> refusals = [];

  /// Every idempotency key that reached the server, in order.
  final List<String> receivedKeys = [];

  /// Every procedure called, in order (`list:<communityId>`, `get`, `create`,
  /// `cancel`, `request`, `withdraw`, `respond:accept`, `respond:decline`,
  /// `leave`, `remove`, `people:accepted`, `people:requested`, `mine`,
  /// `update`).
  final List<String> calls = [];

  /// The public audience's upcoming plans, in list order.
  final List<pb.BeaconView> public = [];

  /// Each community's upcoming plans, in list order.
  final Map<String, List<pb.BeaconView>> byCommunity = {};

  /// The caller's own plans as ListMyBeacons answers them (not filtered by
  /// window or role: the test sets what the server would return).
  final List<pb.BeaconView> mine = [];

  /// The `limit` of every ListMyBeacons, in order (the tablet "Your plans"
  /// section asks for 2, My plans for 20).
  final List<int> mineLimits = [];

  /// Thrown by the next ListMyBeacons calls only, one per call (before
  /// [refusals]).
  final List<AppException> mineRefusals = [];

  /// ACCEPTED and REQUESTED rows per beacon id.
  final Map<String, List<pb.Participant>> going = {};
  final Map<String, List<pb.Participant>> requests = {};

  /// The caller, as the server would see them on a request.
  String viewerId = 'me';
  String viewerHandle = 'me';

  /// The last CreateBeacon / UpdateBeacon request as received.
  pb.CreateBeaconRequest? lastCreate;
  pb.UpdateBeaconRequest? lastUpdate;

  /// The last RequestToJoin note.
  String? lastNote;

  int pageSize = 20;
  int _nextId = 1234567890123456800;

  @override
  bool enabled = true;

  List<pb.BeaconView> _all() => [
    ...public,
    for (final l in byCommunity.values) ...l,
    ...mine,
  ];

  pb.BeaconView _find(String beaconId) {
    for (final v in _all()) {
      if (v.beacon.beaconId == beaconId) return v;
    }
    throw NotFoundException('beacon not found');
  }

  void _refuse(String call) {
    calls.add(call);
    if (refusals.isNotEmpty) throw refusals.removeAt(0);
  }

  void _recomputeStatus(pb.Beacon b) {
    if (b.status == pb.BeaconStatus.BEACON_STATUS_CANCELLED ||
        b.status == pb.BeaconStatus.BEACON_STATUS_ENDED) {
      return;
    }
    b.status = b.acceptedCount >= b.openSpots
        ? pb.BeaconStatus.BEACON_STATUS_FULL
        : pb.BeaconStatus.BEACON_STATUS_OPEN;
  }

  BeaconsPage _page(List<pb.BeaconView> source, int limit, String pageToken) {
    final start = pageToken.isEmpty ? 0 : int.parse(pageToken);
    final size = limit <= 0 ? pageSize : limit;
    final end = (start + size).clamp(0, source.length);
    return BeaconsPage(
      views: source.sublist(start, end),
      nextPageToken: end < source.length ? '$end' : '',
    );
  }

  @override
  Future<BeaconsPage> listBeacons({
    String communityId = '',
    int limit = 0,
    String pageToken = '',
  }) async {
    _refuse('list:$communityId');
    final source = communityId.isEmpty
        ? public
        : (byCommunity[communityId] ?? const []);
    return _page(source, limit, pageToken);
  }

  @override
  Future<BeaconsPage> listMyBeacons({
    pb.MyBeaconsRole role = pb.MyBeaconsRole.MY_BEACONS_ROLE_ALL,
    pb.MyBeaconsWindow window = pb.MyBeaconsWindow.MY_BEACONS_WINDOW_UPCOMING,
    int limit = 0,
    String pageToken = '',
  }) async {
    mineLimits.add(limit);
    if (mineRefusals.isNotEmpty) {
      calls.add('mine');
      throw mineRefusals.removeAt(0);
    }
    _refuse('mine');
    return _page(mine, limit, pageToken);
  }

  @override
  Future<pb.BeaconView> getBeacon(String beaconId) async {
    _refuse('get');
    return _find(beaconId);
  }

  @override
  Future<pb.BeaconView> createBeacon({
    required String idempotencyKey,
    required pb.CreateBeaconRequest request,
  }) async {
    _refuse('create');
    receivedKeys.add(idempotencyKey);
    lastCreate = request;
    final view = pb.BeaconView(
      beacon: pb.Beacon(
        beaconId: '${_nextId++}',
        communityId: request.hasCommunityId() ? request.communityId : '',
        activity: request.activity,
        title: request.title,
        details: request.details,
        venue: request.venue,
        startAt: request.startAt,
        durationMinutes: request.durationMinutes,
        openSpots: request.openSpots,
        cost: request.cost,
        chatPreference: request.chatPreference,
        status: pb.BeaconStatus.BEACON_STATUS_OPEN,
      ),
      viewer: pb.ViewerState(
        role: pb.ViewerRole.VIEWER_ROLE_ORGANISER,
        canManage: true,
      ),
    );
    if (request.hasCommunityId()) {
      byCommunity.putIfAbsent(request.communityId, () => []).add(view);
    } else {
      public.add(view);
    }
    return view;
  }

  @override
  Future<pb.BeaconView> updateBeacon({
    required String idempotencyKey,
    required pb.UpdateBeaconRequest request,
  }) async {
    _refuse('update');
    receivedKeys.add(idempotencyKey);
    lastUpdate = request;
    final view = _find(request.beaconId);
    final b = view.beacon;
    if (request.hasTitle()) b.title = request.title;
    if (request.hasDetails()) b.details = request.details;
    if (request.hasVenue()) b.venue = request.venue;
    if (request.hasOpenSpots()) {
      if (request.openSpots < b.acceptedCount) {
        throw ValidationException(
          'open_spots below accepted',
          field: 'open_spots',
        );
      }
      b.openSpots = request.openSpots;
    }
    _recomputeStatus(b);
    return view;
  }

  @override
  Future<void> cancelBeacon({
    required String idempotencyKey,
    required String beaconId,
  }) async {
    _refuse('cancel');
    receivedKeys.add(idempotencyKey);
    _find(beaconId).beacon.status = pb.BeaconStatus.BEACON_STATUS_CANCELLED;
  }

  @override
  Future<pb.ViewerState> requestToJoin({
    required String idempotencyKey,
    required String beaconId,
    String note = '',
  }) async {
    _refuse('request');
    receivedKeys.add(idempotencyKey);
    lastNote = note;
    final view = _find(beaconId);
    if (view.beacon.status == pb.BeaconStatus.BEACON_STATUS_FULL) {
      throw StateConflictException('full');
    }
    requests
        .putIfAbsent(beaconId, () => [])
        .add(
          pb.Participant(
            user: common.AuthorSnapshot(userId: viewerId, handle: viewerHandle),
            state: pb.ParticipantState.PARTICIPANT_STATE_REQUESTED,
            note: note,
          ),
        );
    view.viewer = pb.ViewerState(
      role: pb.ViewerRole.VIEWER_ROLE_NONE,
      participantState: pb.ParticipantState.PARTICIPANT_STATE_REQUESTED,
      canWithdraw: true,
    );
    return view.viewer;
  }

  @override
  Future<void> withdrawJoinRequest({
    required String idempotencyKey,
    required String beaconId,
  }) async {
    _refuse('withdraw');
    receivedKeys.add(idempotencyKey);
    final view = _find(beaconId);
    requests[beaconId]?.removeWhere((p) => p.user.userId == viewerId);
    view.viewer = pb.ViewerState(
      role: pb.ViewerRole.VIEWER_ROLE_NONE,
      participantState: pb.ParticipantState.PARTICIPANT_STATE_WITHDRAWN,
      canRequest: view.beacon.status == pb.BeaconStatus.BEACON_STATUS_OPEN,
    );
  }

  @override
  Future<void> leaveBeacon({
    required String idempotencyKey,
    required String beaconId,
  }) async {
    _refuse('leave');
    receivedKeys.add(idempotencyKey);
    final view = _find(beaconId);
    going[beaconId]?.removeWhere((p) => p.user.userId == viewerId);
    view.beacon.acceptedCount = (view.beacon.acceptedCount - 1).clamp(
      0,
      1 << 20,
    );
    _recomputeStatus(view.beacon);
    view.viewer = pb.ViewerState(
      role: pb.ViewerRole.VIEWER_ROLE_NONE,
      participantState: pb.ParticipantState.PARTICIPANT_STATE_LEFT,
      canRequest: view.beacon.status == pb.BeaconStatus.BEACON_STATUS_OPEN,
    );
  }

  @override
  Future<pb.BeaconView> respondToJoinRequest({
    required String idempotencyKey,
    required String beaconId,
    required String userId,
    required bool accept,
  }) async {
    _refuse(accept ? 'respond:accept' : 'respond:decline');
    receivedKeys.add(idempotencyKey);
    final view = _find(beaconId);
    final rows = requests[beaconId] ?? [];
    final i = rows.indexWhere((p) => p.user.userId == userId);
    if (i < 0) throw StateConflictException('not_requested');
    final row = rows.removeAt(i);
    if (accept) {
      if (view.beacon.acceptedCount >= view.beacon.openSpots) {
        rows.insert(i, row);
        throw StateConflictException('full');
      }
      row.state = pb.ParticipantState.PARTICIPANT_STATE_ACCEPTED;
      row.note = '';
      going.putIfAbsent(beaconId, () => []).add(row);
      view.beacon.acceptedCount += 1;
      _recomputeStatus(view.beacon);
    }
    return view;
  }

  @override
  Future<pb.BeaconView> removeParticipant({
    required String idempotencyKey,
    required String beaconId,
    required String userId,
  }) async {
    _refuse('remove');
    receivedKeys.add(idempotencyKey);
    final view = _find(beaconId);
    final rows = going[beaconId] ?? [];
    final before = rows.length;
    rows.removeWhere((p) => p.user.userId == userId);
    if (rows.length == before) throw StateConflictException('not_participant');
    view.beacon.acceptedCount -= 1;
    _recomputeStatus(view.beacon);
    return view;
  }

  @override
  Future<ParticipantsPage> listParticipants({
    required String beaconId,
    required pb.ParticipantFilter filter,
    int limit = 0,
    String pageToken = '',
  }) async {
    final requested =
        filter == pb.ParticipantFilter.PARTICIPANT_FILTER_REQUESTED;
    _refuse(requested ? 'people:requested' : 'people:accepted');
    final source = (requested ? requests : going)[beaconId] ?? const [];
    final start = pageToken.isEmpty ? 0 : int.parse(pageToken);
    final size = limit <= 0 ? pageSize : limit;
    final end = (start + size).clamp(0, source.length);
    return ParticipantsPage(
      participants: source.sublist(start, end),
      nextPageToken: end < source.length ? '$end' : '',
    );
  }
}
