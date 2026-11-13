import 'package:connectrpc/connect.dart' as connect;

import '../../../core/feature_flags/service_feature_gate.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/app_exception.dart';
import '../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import '../domain/beacons_feature_flag.dart';

/// One page of [BeaconsRepository.listBeacons].
class BeaconsPage {
  const BeaconsPage({required this.views, this.nextPageToken = ''});

  final List<pb.BeaconView> views;
  final String nextPageToken;
  bool get hasMore => nextPageToken.isNotEmpty;
}

/// One page of [BeaconsRepository.listParticipants].
class ParticipantsPage {
  const ParticipantsPage({required this.participants, this.nextPageToken = ''});

  final List<pb.Participant> participants;
  final String nextPageToken;
  bool get hasMore => nextPageToken.isNotEmpty;
}

/// The only caller of `BeaconService` (docs/beacons-plan.md PR 6, PR 7).
///
/// - **Flag.** Every RPC needs `beacons` in `GetMe.enabled_features`
///   ([ServiceFeatureGate]): with it off no request is sent and a
///   [FeatureDisabledException] (`feature=beacons`) is thrown. A server
///   FEATURE_DISABLED is remembered by the gate until the next `GetMe`.
/// - **UNIMPLEMENTED** (an RPC the deployed server does not have) is read as
///   [FeatureDisabledException] `feature=beacons` ("not available yet"): not
///   reported, gate not tripped.
/// - **Errors are typed** by the shared mapper: [NotFoundException] (one
///   message for every cause: missing, hidden, blocked, not visible),
///   [CommunityForbiddenException] (FORBIDDEN by reason), [StateConflictException]
///   (FAILED_PRECONDITION by reason: full, ended, cancelled, ...),
///   [LimitReachedException] (`quota` = `beacons_open`), [RateLimitedException].
/// - **Mutations** take an `idempotencyKey` made once per user action by the
///   caller and reused on a retry (rule 4). Nothing is retried here.
/// - **Roles** and viewer actions are the server's (`BeaconView.viewer`);
///   this class derives none, and ENDED is never computed from the clock.
class BeaconsRepository {
  BeaconsRepository({
    required ApiClient apiClient,
    required ServiceFeatureGate gate,
  }) : _apiClient = apiClient,
       _gate = gate;

  final ApiClient _apiClient;
  final ServiceFeatureGate _gate;

  /// Whether the flag is on for the caller (and the server has not said
  /// otherwise since the last `GetMe`).
  bool get enabled => _gate.enabled;

  /// Upcoming OPEN and FULL plans of one audience, soonest first: the public
  /// audience when [communityId] is empty, else that community's. [limit] 0
  /// means the server default (20); max 50.
  ///
  /// [activity] keeps one activity (F29, filtered on the server, so a page
  /// is never emptied here); UNSPECIFIED is every activity and sends no
  /// filter, so that request is byte for byte the unfiltered one. A server
  /// from before F29 ignores the field: the caller drops other activities.
  Future<BeaconsPage> listBeacons({
    String communityId = '',
    int limit = 0,
    String pageToken = '',
    pb.BeaconActivity activity = pb.BeaconActivity.BEACON_ACTIVITY_UNSPECIFIED,
  }) async {
    final request = pb.ListBeaconsRequest(limit: limit, pageToken: pageToken);
    if (communityId.isEmpty) {
      request.public = true;
    } else {
      request.communityId = communityId;
    }
    if (activity != pb.BeaconActivity.BEACON_ACTIVITY_UNSPECIFIED) {
      request.activity = activity;
    }
    final r = await _call(() => _apiClient.beacons.listBeacons(request));
    return BeaconsPage(views: r.views.toList(), nextPageToken: r.nextPageToken);
  }

  Future<pb.BeaconView> getBeacon(String beaconId) async {
    final r = await _call(
      () =>
          _apiClient.beacons.getBeacon(pb.GetBeaconRequest(beaconId: beaconId)),
    );
    return r.view;
  }

  /// Sends [request] with [idempotencyKey] set (the cubit builds every other
  /// field). The server validates after trim and NFC.
  Future<pb.BeaconView> createBeacon({
    required String idempotencyKey,
    required pb.CreateBeaconRequest request,
  }) async {
    final sent = request.deepCopy()..idempotencyKey = idempotencyKey;
    final r = await _call(() => _apiClient.beacons.createBeacon(sent));
    return r.view;
  }

  /// Cancels one of the caller's OPEN or FULL plans; already cancelled is
  /// success on the server.
  Future<void> cancelBeacon({
    required String idempotencyKey,
    required String beaconId,
  }) {
    return _call(
      () => _apiClient.beacons.cancelBeacon(
        pb.CancelBeaconRequest(
          idempotencyKey: idempotencyKey,
          beaconId: beaconId,
        ),
      ),
    );
  }

  /// The caller's own plans: organised, requested or accepted (role), UPCOMING
  /// or PAST (window), as the server orders them. [limit] 0 means 20; max 50.
  Future<BeaconsPage> listMyBeacons({
    pb.MyBeaconsRole role = pb.MyBeaconsRole.MY_BEACONS_ROLE_ALL,
    pb.MyBeaconsWindow window = pb.MyBeaconsWindow.MY_BEACONS_WINDOW_UPCOMING,
    int limit = 0,
    String pageToken = '',
  }) async {
    final r = await _call(
      () => _apiClient.beacons.listMyBeacons(
        pb.ListMyBeaconsRequest(
          role: role,
          window: window,
          limit: limit,
          pageToken: pageToken,
        ),
      ),
    );
    return BeaconsPage(views: r.views.toList(), nextPageToken: r.nextPageToken);
  }

  /// ACCEPTED rows (organiser and accepted participants) or, for the organiser
  /// only, REQUESTED rows with their notes; oldest first.
  Future<ParticipantsPage> listParticipants({
    required String beaconId,
    required pb.ParticipantFilter filter,
    int limit = 0,
    String pageToken = '',
  }) async {
    final r = await _call(
      () => _apiClient.beacons.listParticipants(
        pb.ListParticipantsRequest(
          beaconId: beaconId,
          filter: filter,
          limit: limit,
          pageToken: pageToken,
        ),
      ),
    );
    return ParticipantsPage(
      participants: r.participants.toList(),
      nextPageToken: r.nextPageToken,
    );
  }

  /// Sends [request] with [idempotencyKey] set; the cubit sets only the
  /// optional fields that changed (presence is the server's diff).
  Future<pb.BeaconView> updateBeacon({
    required String idempotencyKey,
    required pb.UpdateBeaconRequest request,
  }) async {
    final sent = request.deepCopy()..idempotencyKey = idempotencyKey;
    final r = await _call(() => _apiClient.beacons.updateBeacon(sent));
    return r.view;
  }

  /// Ask to join an OPEN plan; the answer is the caller's new viewer state.
  Future<pb.ViewerState> requestToJoin({
    required String idempotencyKey,
    required String beaconId,
    String note = '',
  }) async {
    final r = await _call(
      () => _apiClient.beacons.requestToJoin(
        pb.RequestToJoinRequest(
          idempotencyKey: idempotencyKey,
          beaconId: beaconId,
          note: note,
        ),
      ),
    );
    return r.viewer;
  }

  Future<void> withdrawJoinRequest({
    required String idempotencyKey,
    required String beaconId,
  }) {
    return _call(
      () => _apiClient.beacons.withdrawJoinRequest(
        pb.WithdrawJoinRequestRequest(
          idempotencyKey: idempotencyKey,
          beaconId: beaconId,
        ),
      ),
    );
  }

  /// The organiser accepts or declines one REQUESTED row.
  Future<pb.BeaconView> respondToJoinRequest({
    required String idempotencyKey,
    required String beaconId,
    required String userId,
    required bool accept,
  }) async {
    final r = await _call(
      () => _apiClient.beacons.respondToJoinRequest(
        pb.RespondToJoinRequestRequest(
          idempotencyKey: idempotencyKey,
          beaconId: beaconId,
          userId: userId,
          response: accept
              ? pb.JoinResponse.JOIN_RESPONSE_ACCEPT
              : pb.JoinResponse.JOIN_RESPONSE_DECLINE,
        ),
      ),
    );
    return r.view;
  }

  Future<void> leaveBeacon({
    required String idempotencyKey,
    required String beaconId,
  }) {
    return _call(
      () => _apiClient.beacons.leaveBeacon(
        pb.LeaveBeaconRequest(
          idempotencyKey: idempotencyKey,
          beaconId: beaconId,
        ),
      ),
    );
  }

  /// The organiser removes an ACCEPTED participant.
  Future<pb.BeaconView> removeParticipant({
    required String idempotencyKey,
    required String beaconId,
    required String userId,
  }) async {
    final r = await _call(
      () => _apiClient.beacons.removeParticipant(
        pb.RemoveParticipantRequest(
          idempotencyKey: idempotencyKey,
          beaconId: beaconId,
          userId: userId,
        ),
      ),
    );
    return r.view;
  }

  /// The plans the caller and [peerUserId] share (the desktop chat's "Shared
  /// plan" box; `chat_shared_plans`): each view carries the caller's own
  /// viewer state. [limit] 0 is the server's 3, above 10 is 10. The server
  /// may return fewer rows than [limit], or none, with a token set.
  Future<BeaconsPage> listSharedBeacons({
    required String peerUserId,
    int limit = 0,
    String pageToken = '',
  }) async {
    final r = await _call(
      () => _apiClient.beacons.listSharedBeacons(
        pb.ListSharedBeaconsRequest(
          peerUserId: peerUserId,
          limit: limit,
          pageToken: pageToken,
        ),
      ),
    );
    return BeaconsPage(views: r.views.toList(), nextPageToken: r.nextPageToken);
  }

  Future<T> _call<T>(Future<T> Function() call) async {
    final out = await _gate.run<_Out<T>>(() async {
      try {
        return _Out<T>(await call());
      } on connect.ConnectException catch (error) {
        if (error.code == connect.Code.unimplemented) return _Out<T>.notYet();
        rethrow;
      }
    });
    if (out.notYet) {
      throw const FeatureDisabledException(
        "Plans aren't available yet.",
        feature: kFeatureBeacons,
      );
    }
    return out.value as T;
  }
}

/// A call's answer, or "the server does not have this RPC yet".
class _Out<T> {
  _Out(this.value) : notYet = false;
  _Out.notYet() : value = null, notYet = true;

  final T? value;
  final bool notYet;
}
