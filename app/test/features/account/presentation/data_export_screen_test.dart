import 'package:bloc_test/bloc_test.dart';
import 'package:drift/native.dart';
import 'package:dzeroth/app/session_wiring.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/account/data/account_repository.dart';
import 'package:dzeroth/features/account/presentation/data_export_screen.dart';
import 'package:dzeroth/features/auth/data/auth_repository.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/domain/auth_failure.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pbenum.dart'
    show ExportStatus;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:dzeroth/shared/format/scheduled_time.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

class _MockAccounts extends Mock implements AccountRepository {}

class _MockAuth extends Mock implements AuthRepository {}

class _FakeAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

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
  late AppDatabase db;
  late _FakeAuthBloc authBloc;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    authBloc = _FakeAuthBloc();
    whenListen(
      authBloc,
      const Stream<AuthState>.empty(),
      initialState: const AuthState(
        status: AuthStatus.authenticated,
        user: AppUser(
          uid: 'uid-1',
          email: 'a@example.com',
          emailVerified: true,
          isPasswordProvider: true,
        ),
      ),
    );
    addTearDown(db.close);
    accounts = _MockAccounts();
    auth = _MockAuth();
    launcher = _FakeLauncher();
    UrlLauncherPlatform.instance = launcher;
    when(() => auth.reauthNeedsGesture).thenReturn(false);
    // RequestAccountExport needs a recent sign-in, so a tap re-authenticates
    // first.
    when(
      () => auth.reauthenticate(promptPassword: any(named: 'promptPassword')),
    ).thenAnswer((_) async => const ReauthResult());
    when(
      () =>
          accounts.requestExport(idempotencyKey: any(named: 'idempotencyKey')),
    ).thenAnswer((_) async => _export(ExportStatus.EXPORT_STATUS_PENDING));
  });

  Widget providers(Widget child) => MultiRepositoryProvider(
    providers: [
      RepositoryProvider<AccountRepository>.value(value: accounts),
      RepositoryProvider<AuthRepository>.value(value: auth),
      RepositoryProvider<AppDatabase>.value(value: db),
      RepositoryProvider<UnexpectedErrorReporter>.value(value: (_, _) {}),
    ],
    child: BlocProvider<AuthBloc>.value(value: authBloc, child: child),
  );

  Future<void> pump(
    WidgetTester tester, {
    double width = 400,
    double textScale = 1,
    bool use24Hour = false,
  }) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      providers(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(textScale),
              alwaysUse24HourFormat: use24Hour,
            ),
            child: child!,
          ),
          home: const DataExportScreen(),
        ),
      ),
    );
    await tester.pump();
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

    await tester.tap(find.text('Check again'));
    await tester.pump(Duration.zero);
    await tester.pump();
    verify(() => accounts.getExport(exportId: 'exp-1')).called(1);
  });

  testWidgets('leaving the screen mid-poll stops polling', (tester) async {
    when(() => accounts.getExport(exportId: 'exp-1'))
        .thenAnswer((_) async => _export(ExportStatus.EXPORT_STATUS_PENDING));
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      providers(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const DataExportScreen(),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tapRequest(tester);

    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(minutes: 10));

    verifyNever(() => accounts.getExport(exportId: any(named: 'exportId')));
  });

  testWidgets('reopening resumes a saved export and shows Download', (
    tester,
  ) async {
    await db.saveExport(
      exportId: 'exp-1',
      uid: 'uid-1',
      requestedAt: DateTime.now(),
      expiresAt: DateTime.now().add(const Duration(days: 7)),
      epoch: db.sessionEpoch.value,
    );
    when(() => accounts.getExport(exportId: 'exp-1')).thenAnswer(
      (_) async => _export(ExportStatus.EXPORT_STATUS_READY, url: _downloadUrl),
    );
    await tester.runAsync(() async {
      await pump(tester);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();

    expect(find.text('Download'), findsOneWidget);
    verifyNever(
      () =>
          accounts.requestExport(idempotencyKey: any(named: 'idempotencyKey')),
    );
  });

  testWidgets('degraded mode shows the friendly limited-mode message', (
    tester,
  ) async {
    when(() => accounts.getExport(exportId: 'exp-1'))
        .thenThrow(const DegradedModeException('degraded'));
    await pump(tester);
    await tapRequest(tester);
    await tester.pump(const Duration(seconds: 10));
    await tester.pump();

    expect(find.textContaining('limited mode'), findsOneWidget);
  });

  testWidgets('a failed export job says to try again, no retry button', (
    tester,
  ) async {
    when(() => accounts.getExport(exportId: 'exp-1'))
        .thenAnswer((_) async => _export(ExportStatus.EXPORT_STATUS_FAILED));
    await pump(tester);
    await tapRequest(tester);
    await tester.pump(const Duration(seconds: 10));
    await tester.pump();

    expect(
      find.text('We could not prepare your export. Please try again.'),
      findsOneWidget,
    );
    expect(find.textContaining('tomorrow'), findsNothing);
    expect(find.text('Retry'), findsNothing);
    expect(find.text('Try again'), findsNothing);
  });

  testWidgets('2x text scale has no overflow', (tester) async {
    await pump(tester, textScale: 2);
    await tester.scrollUntilVisible(find.text('Request export'), 100);

    expect(find.text('Request export'), findsOneWidget);
    expect(tester.takeException(), isNull);
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

  testWidgets('the intro says one export at a time, not one per day', (
    tester,
  ) async {
    await pump(tester);

    expect(
      find.textContaining('You can run one export at a time'),
      findsOneWidget,
    );
    expect(find.textContaining('per day'), findsNothing);
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

  testWidgets('a cancelled re-auth leaves the button idle: no spinner, no '
      'error, no RPC; the next tap re-authenticates again', (tester) async {
    when(
      () => auth.reauthenticate(promptPassword: any(named: 'promptPassword')),
    ).thenAnswer((_) async => throw const AuthFailure.cancelled());
    await pump(tester);

    await tapRequest(tester);

    expect(find.text('Request export'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Retry'), findsNothing);
    expect(find.textContaining('went wrong'), findsNothing);
    verifyNever(
      () =>
          accounts.requestExport(idempotencyKey: any(named: 'idempotencyKey')),
    );

    when(
      () => auth.reauthenticate(promptPassword: any(named: 'promptPassword')),
    ).thenAnswer((_) async => const ReauthResult());
    await tapRequest(tester);

    expect(find.text('Request export'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    verify(
      () => auth.reauthenticate(promptPassword: any(named: 'promptPassword')),
    ).called(2);
  });

  testWidgets('web: a REAUTH_REQUIRED after the re-auth shows Retry, and Retry '
      're-authenticates again from the tap with the same key', (tester) async {
    when(() => auth.reauthNeedsGesture).thenReturn(true);
    final keys = <String>[];
    var calls = 0;
    when(
      () =>
          accounts.requestExport(idempotencyKey: any(named: 'idempotencyKey')),
    ).thenAnswer((i) async {
      keys.add(i.namedArguments[#idempotencyKey] as String);
      if (++calls == 1) throw const ReauthRequiredException('Sign in again.');
      return _export(ExportStatus.EXPORT_STATUS_PENDING);
    });
    await pump(tester);

    await tapRequest(tester);
    expect(find.text('Retry'), findsOneWidget);
    verify(
      () => auth.reauthenticate(promptPassword: any(named: 'promptPassword')),
    ).called(1); // no popup outside the gesture

    await tester.tap(find.text('Retry'));
    // The tap itself started the re-auth (checked before any pump).
    verify(
      () => auth.reauthenticate(promptPassword: any(named: 'promptPassword')),
    ).called(1);
    await tester.pump();
    await tester.pump();

    expect(find.text('Retry'), findsNothing);
    expect(keys, hasLength(2));
    expect(keys[1], keys[0]);
  });

  testWidgets('wide layout has no overflow', (tester) async {
    await pump(tester, width: 1400);

    expect(find.text('Request export'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('READY without a link shows Download with a hint; the tap '
      're-authenticates, fetches the link and opens it', (tester) async {
    var polls = 0;
    when(() => accounts.getExport(exportId: 'exp-1')).thenAnswer((_) async {
      polls++;
      // The first poll has a stale sign-in: READY, no link.
      return polls == 1
          ? _export(ExportStatus.EXPORT_STATUS_READY)
          : _export(ExportStatus.EXPORT_STATUS_READY, url: _downloadUrl);
    });
    await pump(tester);
    await tapRequest(tester);
    await tester.pump(const Duration(seconds: 10));
    await tester.pump();

    expect(find.text('Download'), findsOneWidget);
    expect(find.textContaining('confirm it'), findsOneWidget);
    verify(
      () => auth.reauthenticate(promptPassword: any(named: 'promptPassword')),
    ).called(1); // the request's own

    await tester.tap(find.text('Download'));
    await tester.pump();
    await tester.pump();

    verify(
      () => auth.reauthenticate(promptPassword: any(named: 'promptPassword')),
    ).called(1);
    expect(launcher.launched, [_downloadUrl]);
  });

  testWidgets('a cancelled re-auth on Download opens nothing and keeps the '
      'button', (tester) async {
    when(() => accounts.getExport(exportId: 'exp-1'))
        .thenAnswer((_) async => _export(ExportStatus.EXPORT_STATUS_READY));
    await pump(tester);
    await tapRequest(tester);
    await tester.pump(const Duration(seconds: 10));
    await tester.pump();
    when(
      () => auth.reauthenticate(promptPassword: any(named: 'promptPassword')),
    ).thenAnswer((_) async => throw const AuthFailure.cancelled());

    await tester.tap(find.text('Download'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Download'), findsOneWidget);
    expect(launcher.launched, isEmpty);
  });

  testWidgets('a failed re-auth on Download shows the friendly message and a '
      'retry that resumes without a new request', (tester) async {
    when(() => accounts.getExport(exportId: 'exp-1'))
        .thenAnswer((_) async => _export(ExportStatus.EXPORT_STATUS_READY));
    await pump(tester);
    await tapRequest(tester);
    await tester.pump(const Duration(seconds: 10));
    await tester.pump();
    when(
      () => auth.reauthenticate(promptPassword: any(named: 'promptPassword')),
    ).thenAnswer((_) async => throw const AuthFailure.invalidCredentials());

    await tester.tap(find.text('Download'));
    await tester.pump();
    await tester.pump();

    expect(
      find.text(const AuthFailure.invalidCredentials().message),
      findsOneWidget,
    );
    expect(launcher.launched, isEmpty);

    await tester.tap(find.text('Try again'));
    await tester.pump();
    await tester.pump(Duration.zero);
    await tester.pump();
    expect(find.text('Download'), findsOneWidget);
    verify(
      () =>
          accounts.requestExport(idempotencyKey: any(named: 'idempotencyKey')),
    ).called(1);
  });

  group('R4: the archive line (F27)', () {
    testWidgets('READY shows "Available until" from expires_at, never the '
        "link's 15 minutes", (tester) async {
      final until = DateTime.now().toUtc().add(const Duration(days: 7));
      when(() => accounts.getExport(exportId: 'exp-1')).thenAnswer(
        (_) async => AccountExport(
          exportId: 'exp-1',
          status: ExportStatus.EXPORT_STATUS_READY,
          downloadUrl: _downloadUrl,
          downloadUrlExpiresAt: DateTime.now().add(const Duration(minutes: 15)),
          expiresAt: until,
        ),
      );
      await pump(tester);
      await tapRequest(tester);
      await tester.pump(const Duration(seconds: 10));
      await tester.pump();

      expect(find.text('Your data, ready.'), findsOneWidget);
      expect(find.text('Your data export'), findsOneWidget);
      expect(
        find.text('Ready · Available until ${formatScheduledTime(until)}'),
        findsOneWidget,
      );
      expect(find.textContaining('15 min'), findsNothing);
      expect(find.text('Download'), findsOneWidget);
    });

    testWidgets('the time follows the device 24-hour setting', (tester) async {
      final until = DateTime.now().toUtc().add(const Duration(days: 7));
      when(() => accounts.getExport(exportId: 'exp-1')).thenAnswer(
        (_) async => AccountExport(
          exportId: 'exp-1',
          status: ExportStatus.EXPORT_STATUS_READY,
          downloadUrl: _downloadUrl,
          expiresAt: until,
        ),
      );
      await pump(tester, use24Hour: true);
      await tapRequest(tester);
      await tester.pump(const Duration(seconds: 10));
      await tester.pump();
      expect(
        find.text(
          'Ready · Available until '
          '${formatScheduledTime(until, use24Hour: true)}',
        ),
        findsOneWidget,
      );
    });

    testWidgets('READY without expires_at just says Ready', (tester) async {
      when(() => accounts.getExport(exportId: 'exp-1')).thenAnswer(
        (_) async =>
            _export(ExportStatus.EXPORT_STATUS_READY, url: _downloadUrl),
      );
      await pump(tester);
      await tapRequest(tester);
      await tester.pump(const Duration(seconds: 10));
      await tester.pump();
      expect(find.text('Ready'), findsOneWidget);
      expect(find.textContaining('Available until'), findsNothing);
    });

    testWidgets('idle and waiting draw no archive line', (tester) async {
      await pump(tester);
      expect(find.text('Get a copy of your data.'), findsOneWidget);
      expect(find.text('Your data export'), findsNothing);
      await tapRequest(tester);
      expect(find.text('Preparing your data.'), findsOneWidget);
      expect(find.text('Your data export'), findsNothing);
    });

    for (final (width, scale) in [(360.0, 2.0), (600.0, 2.0), (1024.0, 1.0)]) {
      testWidgets('READY at ${width.toInt()} x$scale: no overflow', (
        tester,
      ) async {
        when(() => accounts.getExport(exportId: 'exp-1')).thenAnswer(
          (_) async => AccountExport(
            exportId: 'exp-1',
            status: ExportStatus.EXPORT_STATUS_READY,
            downloadUrl: _downloadUrl,
            expiresAt: DateTime.now().toUtc().add(const Duration(days: 7)),
          ),
        );
        await pump(tester, width: width, textScale: scale);
        // Large text pushes the button below the fold.
        await tester.scrollUntilVisible(find.text('Request export'), 200);
        await tester.ensureVisible(find.text('Request export'));
        await tester.pump();
        await tapRequest(tester);
        await tester.pump(const Duration(seconds: 10));
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.textContaining('Available until'), findsOneWidget);
      });
    }
  });

  group('R4 design fidelity (DataExport.dc.html)', () {
    testWidgets('idle: the request is the large gradient pill', (tester) async {
      await pump(tester);
      final pill = tester.widget<AppPillButton>(
        find.widgetWithText(AppPillButton, 'Request export'),
      );
      expect(pill.variant, AppButtonVariant.primary);
      expect(pill.size, AppButtonSize.large);
      expect(find.text('YOUR ARCHIVE'), findsOneWidget);
    });

    testWidgets('ready: Download is the large gradient pill', (tester) async {
      when(() => accounts.getExport(exportId: 'exp-1')).thenAnswer(
        (_) async =>
            _export(ExportStatus.EXPORT_STATUS_READY, url: _downloadUrl),
      );
      await pump(tester);
      await tapRequest(tester);
      await tester.pump(const Duration(seconds: 10));
      await tester.pump();
      final pill = tester.widget<AppPillButton>(
        find.widgetWithText(AppPillButton, 'Download'),
      );
      expect(pill.variant, AppButtonVariant.primary);
      expect(pill.size, AppButtonSize.large);
    });
  });
}
