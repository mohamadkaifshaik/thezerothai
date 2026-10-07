import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/account/data/account_repository.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_transport.dart';

void main() {
  AccountRepository build(
    Future<Object> Function(String procedure, Object input) handler,
  ) => AccountRepository(
    apiClient: ApiClient.withTransport(FakeTransport(handler)),
  );

  test('deleteAccount sends the idempotency key once', () async {
    identity.DeleteAccountRequest? seen;
    final repo = build((procedure, input) async {
      expect(procedure, endsWith('/DeleteAccount'));
      seen = input as identity.DeleteAccountRequest;
      return identity.DeleteAccountResponse();
    });

    final at = await repo.deleteAccount(idempotencyKey: 'k1');

    expect(seen!.idempotencyKey, 'k1');
    expect(at, isNull);
  });

  test('requestExport returns id and status', () async {
    final repo = build(
      (procedure, input) async => identity.RequestAccountExportResponse(
        exportId: 'e1',
        status: identity.ExportStatus.EXPORT_STATUS_PENDING,
      ),
    );

    final export = await repo.requestExport(idempotencyKey: 'k2');

    expect(export.exportId, 'e1');
    expect(export.status, identity.ExportStatus.EXPORT_STATUS_PENDING);
    expect(export.downloadUrl, isNull);
  });

  test('getExport maps a READY export with its download URL', () async {
    final repo = build(
      (procedure, input) async => identity.GetAccountExportResponse(
        exportId: 'e1',
        status: identity.ExportStatus.EXPORT_STATUS_READY,
        downloadUrl: 'https://example.invalid/x',
      ),
    );

    final export = await repo.getExport(exportId: 'e1');

    expect(export.status, identity.ExportStatus.EXPORT_STATUS_READY);
    expect(export.downloadUrl, 'https://example.invalid/x');
    expect(export.toString(), isNot(contains('example.invalid')));
  });

  test('REAUTH_REQUIRED surfaces as ReauthRequiredException', () async {
    final repo = build((procedure, input) async {
      throw connect.ConnectException(
        connect.Code.failedPrecondition,
        'old sign-in',
        details: [
          connect.ErrorDetail(
            'type.googleapis.com/dzeroth.common.v1.ErrorDetail',
            common.ErrorDetail(
              reason: common.ErrorReason.ERROR_REASON_REAUTH_REQUIRED,
            ).writeToBuffer(),
          ),
        ],
      );
    });

    await expectLater(
      repo.deleteAccount(idempotencyKey: 'k'),
      throwsA(isA<ReauthRequiredException>()),
    );
  });
}
