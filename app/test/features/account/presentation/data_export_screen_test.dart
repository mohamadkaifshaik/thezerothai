import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/account/data/account_repository.dart';
import 'package:dzeroth/features/account/presentation/bloc/data_export_cubit.dart';
import 'package:dzeroth/features/account/presentation/data_export_screen.dart';
import 'package:dzeroth/features/auth/data/auth_repository.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pbenum.dart' show ExportStatus;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

class _MockAccounts extends Mock implements AccountRepository {}

class _MockAuth extends Mock implements AuthRepository {}

class _FakeLauncher extends UrlLauncherPlatform {
  final launched = <String>[];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add(url);
    return true;
  }
}

const _downloadUrl = 'https://storage.example/export.zip?sig=secret';

AccountExport _export(ExportStatus status, {String? url}) => AccountExport(
  exportId: 'exp-1',
  status: status,
  downloadUrl: url,
  downloadUrlExpiresAt: null,
);

void main() {
  late _MockAccounts accounts;
  late _MockAuth auth;
  late _FakeLauncher launcher;

  setUp(() {
    accounts = _MockAccounts();
    auth = _MockAuth();
    launcher = _FakeLauncher();
    UrlLauncherPlatform.instance = launcher;
    when(() => auth.reauthNeedsGesture).thenReturn(false);
    when(
      () =>
          accounts.requestExport(idempotencyKey: any(named: 'idempotencyKey')),
    ).thenAnswer((_) async => _export(ExportStatus.EXPORT_STATUS_PENDING));
  });

  Future<void> pump(WidgetTester tester, {double width = 400}) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<AccountRepository>.value(value: accounts),
          RepositoryProvider<AuthRepository>.value(value: auth),
        ],
        child: const MaterialApp(home: DataExportScreen()),
      ),
    );
  }

  Future<void> tapRequest(WidgetTester tester) async {
    await tester.tap(find.text('Request export'));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('idle: explains the export and offers a request button', (
    tester,
  ) async {
    await pump(tester);

    expect(find.text('Download my data'), findsOneWidget);
    expect(find.text('Request export'), findsOneWidget);
    verifyNever(
      () =>
          accounts.requestExport(idempotencyKey: any(named: 'idempotencyKey')),
    );
  });

  testWidgets('PENDING then READY shows Download without a manual refresh', (
    tester,
  ) async {
    var polls = 0;
    when(() => accounts.getExport(exportId: 'exp-1')).thenAnswer((_) async {
      polls++;
      return polls == 1
          ? _export(ExportStatus.EXPORT_STATUS_PENDING)
          : _export(ExportStatus.EXPORT_STATUS_READY, url: _downloadUrl);
    });
    await pump(tester);

    await tapRequest(tester);
    expect(find.textContaining('Preparing your export'), findsOneWidget);
    expect(find.text('Download'), findsNothing);

    await tester.pump(const Duration(seconds: 10));
    await tester.pump();
    expect(find.text('Download'), findsNothing);
    await tester.pump(const Duration(seconds: 15));
    await tester.pump();

    expect(find.text('Download'), findsOneWidget);
    expect(polls, 2);

    await tester.tap(find.text('Download'));
    await tester.pump();
    await tester.pump();
    expect(launcher.launched, [_downloadUrl]);
    // Fresh URL: opening it costs no extra request.
    verify(() => accounts.getExport(exportId: 'exp-1')).called(2);
  });

  testWidgets('stops after 10 polls and shows "check back later"', (
    tester,
  ) async {
    when(() => accounts.getExport(exportId: 'exp-1'))
        .thenAnswer((_) async => _export(ExportStatus.EXPORT_STATUS_PENDING));
    await pump(tester);

    await tapRequest(tester);
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(seconds: 60));
      await tester.pump();
    }

    expect(find.textContaining('check back later'), findsOneWidget);
    verify(() => accounts.getExport(exportId: 'exp-1')).called(10);
  });

  testWidgets('backoff delays grow from 10 s to 60 s', (tester) async {
    final delays = [
      for (var i = 0; i < DataExportCubit.maxPolls; i++)
        DataExportCubit.delayForPoll(i).inSeconds,
    ];
    expect(delays, [10, 15, 22, 33, 50, 60, 60, 60, 60, 60]);
  });

  testWidgets('NOT_FOUND shows the expired state', (tester) async {
    when(() => accounts.getExport(exportId: 'exp-1'))
        .thenThrow(const NotFoundException('gone'));
    await pump(tester);

    await tapRequest(tester);
    await tester.pump(const Duration(seconds: 10));
    await tester.pump();

    expect(find.text('This export has expired.'), findsOneWidget);
    expect(find.text('Request a new export'), findsOneWidget);
  });

  testWidgets('QUOTA_EXCEEDED says one export per day', (tester) async {
    when(
      () =>
          accounts.requestExport(idempotencyKey: any(named: 'idempotencyKey')),
    ).thenThrow(const QuotaExceededException('quota'));
    await pump(tester);

    await tapRequest(tester);

    expect(find.text('You can request one export per day.'), findsOneWidget);
  });

  testWidgets('network error on request shows a retry', (tester) async {
    when(
      () =>
          accounts.requestExport(idempotencyKey: any(named: 'idempotencyKey')),
    ).thenThrow(const NetworkException('offline'));
    await pump(tester);

    await tapRequest(tester);

    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('wide layout has no overflow', (tester) async {
    await pump(tester, width: 1400);

    expect(find.text('Request export'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
