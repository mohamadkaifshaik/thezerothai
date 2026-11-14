import '../../../core/network/api_client.dart';
import '../../../gen/dzeroth/identity/v1/identity.pb.dart' as identity;

/// Talks to the account-lifecycle RPCs of `IdentityService`
/// (DeleteAccount, RequestAccountExport, GetAccountExport).
///
/// Errors are converted to typed `AppException`s by [guardApiCall]
/// (`ReauthRequiredException`, `QuotaExceededException`,
/// `RateLimitedException`, `FeatureDisabledException`,
/// `DegradedModeException`, ...). The caller owns the idempotency key: one
/// key per user intent, reused on every retry of that intent.
///
/// Budget: exactly one RPC per call; this class never retries on its own.
class AccountRepository {
  AccountRepository({required ApiClient apiClient}) : _apiClient = apiClient;

  final ApiClient _apiClient;

  /// Marks the account for deletion. Returns when the server recorded
  /// `deletion_requested_at`.
  Future<DateTime?> deleteAccount({required String idempotencyKey}) async {
    final response = await guardApiCall(
      () => _apiClient.identity.deleteAccount(
        identity.DeleteAccountRequest(idempotencyKey: idempotencyKey),
      ),
    );
    return response.hasDeletionRequestedAt()
        ? response.deletionRequestedAt.toDateTime()
        : null;
  }

  /// Starts a data export, or returns the one already running: the same key
  /// re-joins its export, and a new key gets the user's PENDING export if there
  /// is one, so the returned id may come from an earlier request.
  ///
  /// [zip] asks for the ZIP archive; the server serves JSON when the flag is
  /// off for the caller, and the response's format says which one it is.
  Future<AccountExport> requestExport({
    required String idempotencyKey,
    bool zip = false,
  }) async {
    final response = await guardApiCall(
      () => _apiClient.identity.requestAccountExport(
        identity.RequestAccountExportRequest(
          idempotencyKey: idempotencyKey,
          format: zip
              ? identity.ExportFormat.EXPORT_FORMAT_ZIP
              : identity.ExportFormat.EXPORT_FORMAT_JSON,
        ),
      ),
    );
    return AccountExport(exportId: response.exportId, status: response.status);
  }

  /// Polls one export. NOT_FOUND (unknown or expired id) surfaces as
  /// `NotFoundException`. The returned [AccountExport.downloadUrl] is a
  /// short-lived signed URL: never log it.
  Future<AccountExport> getExport({required String exportId}) async {
    final response = await guardApiCall(
      () => _apiClient.identity.getAccountExport(
        identity.GetAccountExportRequest(exportId: exportId),
      ),
    );
    return AccountExport(
      exportId: response.exportId,
      status: response.status,
      downloadUrl: response.downloadUrl.isEmpty ? null : response.downloadUrl,
      downloadUrlExpiresAt: response.hasDownloadUrlExpiresAt()
          ? response.downloadUrlExpiresAt.toDateTime()
          : null,
      expiresAt: response.hasExpiresAt()
          ? response.expiresAt.toDateTime()
          : null,
    );
  }
}

/// Client view of an account export.
class AccountExport {
  const AccountExport({
    required this.exportId,
    required this.status,
    this.downloadUrl,
    this.downloadUrlExpiresAt,
    this.expiresAt,
  });

  final String exportId;
  final identity.ExportStatus status;

  /// Signed, short-lived. Never log it.
  final String? downloadUrl;
  final DateTime? downloadUrlExpiresAt;
  final DateTime? expiresAt;

  @override
  String toString() => 'AccountExport($exportId, ${status.name})';
}
