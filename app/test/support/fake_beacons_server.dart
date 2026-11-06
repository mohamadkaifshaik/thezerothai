import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/beacons/data/beacons_repository.dart';
import 'package:dzeroth/gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';

/// A [BeaconsRepository] that behaves like the backend for the rules the
/// Plans screens depend on: one list per audience paged by 20, GetBeacon of an
/// unknown id is NOT_FOUND, CreateBeacon answers an OPEN view with a fresh
/// 19-digit id, CancelBeacon flips the stored view to CANCELLED. Every call
/// first throws the next [refusals] entry, if any (a refusal creates nothing).
class FakeBeaconsServer extends Fake implements BeaconsRepository {
  /// Thrown by the next calls before anything is committed, one per call.
  final List<AppException> refusals = [];

  /// Every idempotency key that reached the server, in order.
  final List<String> receivedKeys = [];

  /// Every procedure called, in order (`list:<communityId>`, `get`, `create`,
  /// `cancel`).
  final List<String> calls = [];

  /// The public audience's upcoming plans, in list order.
  final List<pb.BeaconView> public = [];

  /// Each community's upcoming plans, in list order.
  final Map<String, List<pb.BeaconView>> byCommunity = {};

  /// The last CreateBeacon request as received.
  pb.CreateBeaconRequest? lastCreate;

  int pageSize = 20;
  int _nextId = 1234567890123456800;

  @override
  bool enabled = true;

  List<pb.BeaconView> _all() => [
    ...public,
    for (final l in byCommunity.values) ...l,
  ];

  void _refuse(String call) {
    calls.add(call);
    if (refusals.isNotEmpty) throw refusals.removeAt(0);
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
    final start = pageToken.isEmpty ? 0 : int.parse(pageToken);
    final size = limit <= 0 ? pageSize : limit;
    final end = (start + size).clamp(0, source.length);
    return BeaconsPage(
      views: source.sublist(start, end),
      nextPageToken: end < source.length ? '$end' : '',
    );
  }

  @override
  Future<pb.BeaconView> getBeacon(String beaconId) async {
    _refuse('get');
    for (final v in _all()) {
      if (v.beacon.beaconId == beaconId) return v;
    }
    throw NotFoundException('beacon not found');
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
  Future<void> cancelBeacon({
    required String idempotencyKey,
    required String beaconId,
  }) async {
    _refuse('cancel');
    receivedKeys.add(idempotencyKey);
    for (final v in _all()) {
      if (v.beacon.beaconId == beaconId) {
        v.beacon.status = pb.BeaconStatus.BEACON_STATUS_CANCELLED;
        return;
      }
    }
    throw NotFoundException('beacon not found');
  }
}
