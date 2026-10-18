import '../../../core/feature_flags/service_feature_gate.dart';
import '../../../core/network/api_client.dart';
import '../../../gen/dzeroth/moderation/v1/moderation.pb.dart' as pb;
import '../../../gen/dzeroth/moderation/v1/moderation.pbenum.dart';

/// What the server answered to a report.
class ReportReceipt {
  const ReportReceipt({required this.reportId, required this.alreadyReported});
  final String reportId;

  /// The same reporter already reported this target (a free no-op, ADR-0016
  /// D4): the UI says so instead of "thanks".
  final bool alreadyReported;
}

/// `ModerationService` client (ADR-0016, P7). Every call goes through the
/// `reports` [ServiceFeatureGate]: with the flag off no RPC is sent.
///
/// Reports are never cached and never retried automatically; the caller owns
/// the idempotency key (one per intent, reused on retry).
class ModerationRepository {
  ModerationRepository({
    required ApiClient apiClient,
    required ServiceFeatureGate gate,
  }) : _apiClient = apiClient,
       _gate = gate;

  final ApiClient _apiClient;
  final ServiceFeatureGate _gate;

  /// The gate, so UI can listen for the flag turning off mid-session.
  ServiceFeatureGate get gate => _gate;

  /// Whether Report entries may be offered at all.
  bool get enabled => _gate.enabled;

  Future<ReportReceipt> report({
    required String idempotencyKey,
    required ReportTargetType targetType,
    required String targetId,
    required ReportReason reason,
    String note = '',
  }) async {
    final response = await _gate.run(
      () => _apiClient.moderation.reportContent(
        pb.ReportContentRequest(
          idempotencyKey: idempotencyKey,
          targetType: targetType,
          targetId: targetId,
          reason: reason,
          note: note,
        ),
      ),
    );
    return ReportReceipt(
      reportId: response.reportId,
      alreadyReported: response.alreadyReported,
    );
  }
}
