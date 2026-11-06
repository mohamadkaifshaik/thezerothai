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

/// The only caller of `BeaconService` (docs/beacons-plan.md PR 6).
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
  Future<BeaconsPage> listBeacons({
    String communityId = '',
    int limit = 0,
    String pageToken = '',
  }) async {
    final request = pb.ListBeaconsRequest(limit: limit, pageToken: pageToken);
    if (communityId.isEmpty) {
      request.public = true;
    } else {
      request.communityId = communityId;
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
