import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/account/data/account_repository.dart';
import 'package:dzeroth/features/account/presentation/bloc/account_cubit.dart';
import 'package:dzeroth/features/account/presentation/bloc/data_export_cubit.dart';
import 'package:dzeroth/features/auth/data/auth_repository.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pbenum.dart'
    show ExportStatus;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockAccounts extends Mock implements AccountRepository {}

class _MockAuth extends Mock implements AuthRepository {}

Future<String?> _pw() async => 'pw';

AccountExport _ready(String url) => AccountExport(
  exportId: 'exp-1',
  status: ExportStatus.EXPORT_STATUS_READY,
  downloadUrl: url,
);

void main() {
  late _MockAccounts accounts;
  late _MockAuth auth;
  late DateTime now;

  DataExportCubit build() => DataExportCubit(
    accountCubit: AccountCubit(
      accountRepository: accounts,
      authRepository: auth,
    ),
    accountRepository: accounts,
    clock: () => now,
  );

  // Timers run on the testWidgets fake clock.
  Future<void> elapse(WidgetTester tester, Duration d) async {
    await tester.pump(d);
    await tester.pump();
  }

  setUp(() {
    accounts = _MockAccounts();
    auth = _MockAuth();
    now = DateTime(2026, 10, 7, 12);
    when(() => auth.reauthNeedsGesture).thenReturn(false);
    when(
      () =>
          accounts.requestExport(idempotencyKey: any(named: 'idempotencyKey')),
    ).thenAnswer(
      (_) async => const AccountExport(
        exportId: 'exp-1',
        status: ExportStatus.EXPORT_STATUS_PENDING,
      ),
    );
  });

  testWidgets('a download URL older than 15 minutes is re-fetched once', (
    tester,
  ) async {
    var calls = 0;
    when(() => accounts.getExport(exportId: 'exp-1')).thenAnswer((_) async {
      calls++;
      return _ready('https://example/$calls');
    });
    final cubit = build();
    await cubit.request(promptPassword: _pw);
    await elapse(tester, const Duration(seconds: 10));
    expect(cubit.state.phase, DataExportPhase.ready);
    expect(calls, 1);

    expect((await cubit.downloadUrl()).toString(), 'https://example/1');
    expect(calls, 1);

    now = now.add(const Duration(minutes: 16));
    expect((await cubit.downloadUrl()).toString(), 'https://example/2');
    expect(calls, 2);
    await cubit.close();
  });

  testWidgets('a failed export job stops polling', (tester) async {
    when(() => accounts.getExport(exportId: 'exp-1')).thenAnswer(
      (_) async => const AccountExport(
        exportId: 'exp-1',
        status: ExportStatus.EXPORT_STATUS_FAILED,
      ),
    );
    final cubit = build();
    await cubit.request(promptPassword: _pw);
    await elapse(tester, const Duration(minutes: 10));

    expect(cubit.state.phase, DataExportPhase.failed);
    expect(cubit.state.jobFailed, isTrue);
    verify(() => accounts.getExport(exportId: 'exp-1')).called(1);
    await cubit.close();
  });

  testWidgets('a quota error while polling stops without retrying', (
    tester,
  ) async {
    when(() => accounts.getExport(exportId: 'exp-1'))
        .thenThrow(const QuotaExceededException('quota'));
    final cubit = build();
    await cubit.request(promptPassword: _pw);
    await elapse(tester, const Duration(minutes: 10));

    expect(cubit.state.phase, DataExportPhase.failed);
    expect(cubit.state.error, isA<QuotaExceededException>());
    verify(() => accounts.getExport(exportId: 'exp-1')).called(1);
    await cubit.close();
  });

  testWidgets('closing the cubit cancels pending polls', (tester) async {
    final cubit = build();
    await cubit.request(promptPassword: _pw);
    await cubit.close();
    await elapse(tester, const Duration(minutes: 10));

    verifyNever(() => accounts.getExport(exportId: any(named: 'exportId')));
  });
}
