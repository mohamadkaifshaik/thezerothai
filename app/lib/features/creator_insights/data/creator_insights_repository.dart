import '../../../core/feature_flags/service_feature_gate.dart';
import '../../../core/network/api_client.dart';
import '../../../gen/dzeroth/identity/v1/identity.pb.dart' as pb;

/// The only caller of `IdentityService.GetCreatorInsights`, behind the
/// `creator_insights` gate: with the flag off no request is sent and a
/// `FeatureDisabledException` is thrown. Errors are typed by the shared
/// mapper; nothing is retried here.
class CreatorInsightsRepository {
  CreatorInsightsRepository({
    required ApiClient apiClient,
    required ServiceFeatureGate gate,
  }) : _apiClient = apiClient,
       _gate = gate;

  final ApiClient _apiClient;
  final ServiceFeatureGate _gate;

  bool get enabled => _gate.enabled;

  /// The caller's insights over [windowDays] (1 to 28) and the same number of
  /// days before.
  Future<pb.GetCreatorInsightsResponse> load({int windowDays = 28}) {
    return _gate.run(
      () => _apiClient.identity.getCreatorInsights(
        pb.GetCreatorInsightsRequest(windowDays: windowDays),
      ),
    );
  }
}
