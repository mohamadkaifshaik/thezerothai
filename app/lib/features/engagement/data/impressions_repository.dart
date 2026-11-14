import 'package:uuid/uuid.dart';

import '../../../core/feature_flags/service_feature_gate.dart';
import '../../../core/network/api_client.dart';
import '../../../gen/dzeroth/engagement/v1/engagement.pb.dart' as pb;

/// Sends `EngagementService.RecordImpressions` behind the `post_views` gate.
///
/// One call per batch (the server rate-limits it to about 6 a minute) with a
/// fresh idempotency key; never retried here. With the flag off no RPC is
/// sent; a FEATURE_DISABLED answer is remembered by the gate and rethrown as
/// a typed `FeatureDisabledException` for the tracker, which stops sending.
class ImpressionsRepository {
  ImpressionsRepository({
    required ApiClient apiClient,
    required ServiceFeatureGate gate,
    Uuid? uuid,
  }) : _apiClient = apiClient,
       _gate = gate,
       _uuid = uuid ?? const Uuid();

  final ApiClient _apiClient;
  final ServiceFeatureGate _gate;
  final Uuid _uuid;

  /// Whether views may be recorded at all right now.
  bool get enabled => _gate.enabled;

  /// Records one batch of 1 to 50 post ids.
  Future<void> record(List<String> postIds) async {
    if (postIds.isEmpty) return;
    await _gate.run(
      () => _apiClient.engagement.recordImpressions(
        pb.RecordImpressionsRequest(
          idempotencyKey: _uuid.v4(),
          postIds: postIds,
        ),
      ),
    );
  }
}
