import 'dart:io';
import 'dart:ui' as ui;

import 'package:bloc_test/bloc_test.dart';
import 'package:drift/native.dart';
import 'package:dzeroth/app/session_wiring.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/core/telemetry/telemetry_device_forget.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/account/data/account_repository.dart';
import 'package:dzeroth/features/account/presentation/account_deleted_screen.dart';
import 'package:dzeroth/features/account/presentation/data_export_screen.dart';
import 'package:dzeroth/features/account/presentation/delete_account_screen.dart';
import 'package:dzeroth/features/auth/data/auth_repository.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/notifications/data/push_opt_in_store.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/drafts_repository.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/fake_drafts_repository.dart';
import '../../../support/fake_push_opt_in_store.dart';
import '../../../support/geometry.dart';

class _MockAccounts extends Mock implements AccountRepository {}

class _MockAuth extends Mock implements AuthRepository {}

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

const _screenshots = bool.fromEnvironment('ACCOUNT_SCREENSHOTS');
final _captureKey = GlobalKey();

/// The account pages at phone, tablet and desktop widths: the same actions at
/// each, the phone's actions pinned to the bottom, the wider layouts' inline
/// (Change handle's layouts are in profile_layouts_test, Create profile's in
/// onboarding_layouts_test).
void main() {
  const phone = Size(390, 844);
  const tablet = Size(1024, 768);
  const desktop = Size(1440, 900);

  late _MockAccounts accounts;
  late _MockAuth auth;
  late _MockAuthBloc authBloc;
  late _MockOnboarding onboarding;
  late AppDatabase db;

  setUp(() {
    accounts = _MockAccounts();
    auth = _MockAuth();
    authBloc = _MockAuthBloc();
    onboarding = _MockOnboarding();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    when(() => authBloc.add(any())).thenReturn(null);
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
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        profile: identity.Profile(userId: 'u1', handle: 'Kaif'),
      ),
    );
    when(() => auth.reauthNeedsGesture).thenReturn(false);
  });

  setUpAll(() async {
    registerFallbackValue(const AuthSignOutRequested());
    if (!_screenshots) return;
    for (final family in ['Manrope', 'DM Sans']) {
      final font = family == 'Manrope' ? 'Manrope' : 'DMSans';
      await (FontLoader(
        family,
      )..addFont(rootBundle.load('assets/fonts/$font.ttf'))).load();
    }
    var sdk = File(Platform.resolvedExecutable).parent;
    while (!File(
      '${sdk.path}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    ).existsSync()) {
      sdk = sdk.parent;
    }
    await (FontLoader('MaterialIcons')..addFont(
          File(
            '${sdk.path}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ).readAsBytes().then(ByteData.sublistView),
        ))
        .load();
  });

  Future<void> pump(
    WidgetTester tester,
    Widget screen, {
    required Size size,
    Brightness brightness = Brightness.light,
    double textScale = 1,
    String? routerPath,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      initialLocation: routerPath ?? '/',
      routes: [
        GoRoute(path: '/', builder: (_, _) => screen),
        GoRoute(
          path: AppRouter.accountDeletedPath,
          builder: (_, _) => const AccountDeletedScreen(),
        ),
        GoRoute(
          path: AppRouter.signInPath,
          builder: (_, _) => const Scaffold(body: Text('sign in stub')),
        ),
        GoRoute(
          path: AppRouter.exportDataPath,
          builder: (_, _) => const Scaffold(body: Text('export stub')),
        ),
      ],
    );
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<AccountRepository>.value(value: accounts),
          RepositoryProvider<AuthRepository>.value(value: auth),
          RepositoryProvider<AppDatabase>.value(value: db),
          RepositoryProvider<PushOptInStore>.value(value: FakePushOptInStore()),
          RepositoryProvider<DraftsRepository>.value(
            value: FakeDraftsRepository(),
          ),
          RepositoryProvider<UnexpectedErrorReporter>.value(value: (_, _) {}),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<AuthBloc>.value(value: authBloc),
            BlocProvider<OnboardingBloc>.value(value: onboarding),
          ],
          child: TelemetryForgetScope(
            forget: const TelemetryDeviceForget.none(),
            child: RepaintBoundary(
              key: _captureKey,
              child: MaterialApp.router(
                routerConfig: router,
                theme: buildAppTheme(brightness: brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(textScale)),
                  child: child!,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Finder pill(String label) => find.widgetWithText(AppPillButton, label);

  group('Delete account', () {
    const screen = DeleteAccountScreen();

    testWidgets('phone: the actions are pinned to the bottom, full width', (
      tester,
    ) async {
      await pump(tester, screen, size: phone);
      final delete = tester.getRect(pill('Delete my account'));
      expect(delete.width, phone.width - 2 * AppAccountLayout.pagePaddingH);
      expect(delete.bottom, greaterThan(phone.height - 120));
      expect(
        tester.widget<AppPillButton>(pill('Cancel')).variant,
        AppButtonVariant.text,
      );
      expect(find.text('Leaving DZEROTH?'), findsOneWidget);
    });

    for (final size in [tablet, desktop]) {
      testWidgets('${size.width.toInt()}: the actions follow the content, '
          'Cancel then the danger pill', (tester) async {
        await pump(tester, screen, size: size);
        final cancel = tester.getRect(pill('Cancel'));
        final delete = tester.getRect(pill('Delete my account'));
        expect(cancel.top, delete.top);
        expect(cancel.right, lessThan(delete.left));
        expect(delete.bottom, lessThan(size.height - 120));
        expect(
          tester.widget<AppPillButton>(pill('Cancel')).variant,
          AppButtonVariant.outline,
        );
      });
    }

    testWidgets('the same actions at every width: the typed handle enables '
        'delete', (tester) async {
      for (final size in [phone, tablet, desktop]) {
        await pump(tester, screen, size: size);
        expect(
          tester.widget<AppPillButton>(pill('Delete my account')).onPressed,
          isNull,
        );
        await tester.enterText(find.byType(TextField), 'kaif');
        await tester.pump();
        expect(
          tester.widget<AppPillButton>(pill('Delete my account')).onPressed,
          isNotNull,
        );
        expect(find.text('Download my data first'), findsOneWidget);
      }
    });

    testWidgets('phone at text scale 2.0: no overflow', (tester) async {
      await pump(tester, screen, size: phone, textScale: 2);
      expectNoOverflow(tester);
    });
  });

  group('Download my data', () {
    const screen = DataExportScreen();

    setUp(() {
      when(
        () => accounts.requestExport(
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenAnswer((_) async => throw StateError('not requested here'));
    });

    for (final size in [phone, tablet, desktop]) {
      testWidgets('${size.width.toInt()}: the headline and the request '
          'action', (tester) async {
        await pump(tester, screen, size: size);
        expect(find.text('YOUR ARCHIVE'), findsOneWidget);
        expect(find.text('Get a copy of your data.'), findsOneWidget);
        final request = tester.getRect(pill('Request export'));
        if (size == phone) {
          expect(request.width, size.width - 2 * AppAccountLayout.pagePaddingH);
          expect(request.bottom, greaterThan(size.height - 120));
        } else {
          expect(request.bottom, lessThan(size.height - 120));
        }
      });
    }

    testWidgets('phone at text scale 2.0: no overflow', (tester) async {
      await pump(tester, screen, size: phone, textScale: 2);
      expectNoOverflow(tester);
    });
  });

  group('Account deleted', () {
    const screen = AccountDeletedScreen();

    testWidgets('phone: the status page with Back to log in at the bottom', (
      tester,
    ) async {
      await pump(tester, screen, size: phone);
      expect(find.text('A fresh start.'), findsOneWidget);
      expect(tester.getRect(pill('Back to log in')).bottom, greaterThan(700));
    });

    testWidgets('tablet: the centred column between the wordmark and footer', (
      tester,
    ) async {
      await pump(tester, screen, size: tablet);
      final column = tester.getRect(pill('Back to log in'));
      expect(column.width, AppAuthLayout.tabletFormWidth);
      expect(column.center.dx, moreOrLessEquals(tablet.width / 2));
      expect(find.textContaining('Privacy Policy'), findsOneWidget);
    });

    testWidgets('desktop: the hero beside the form', (tester) async {
      await pump(tester, screen, size: desktop);
      expect(find.textContaining('company'), findsOneWidget);
      expect(
        tester.getRect(pill('Back to log in')).left,
        greaterThan(desktop.width * .6),
      );
    });

    testWidgets('the same action at every width: signs out and goes to log '
        'in', (tester) async {
      for (final size in [phone, tablet, desktop]) {
        await pump(tester, screen, size: size);
        await tester.tap(pill('Back to log in'));
        await tester.pumpAndSettle();
        expect(find.text('sign in stub'), findsOneWidget);
      }
    });

    testWidgets('phone at text scale 2.0: no overflow', (tester) async {
      await pump(tester, screen, size: phone, textScale: 2);
      expectNoOverflow(tester);
    });
  });

  // `flutter test --dart-define=ACCOUNT_SCREENSHOTS=true` writes
  // build/artifacts/account/<screen>-<size>-<brightness>.png.
  group('screenshots', skip: !_screenshots, () {
    final screens = <String, Widget>{
      'delete': const DeleteAccountScreen(),
      'export': const DataExportScreen(),
      'deleted': const AccountDeletedScreen(),
    };
    for (final entry in screens.entries) {
      for (final (name, size) in [
        ('phone', phone),
        ('tablet', tablet),
        ('desktop', desktop),
      ]) {
        for (final brightness in Brightness.values) {
          testWidgets('${entry.key} $name ${brightness.name}', (tester) async {
            await pump(tester, entry.value, size: size, brightness: brightness);
            final boundary =
                _captureKey.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            await tester.runAsync(() async {
              final image = await boundary.toImage();
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final file = File(
                'build/artifacts/account/${entry.key}-$name-${brightness.name}.png',
              );
              await file.parent.create(recursive: true);
              await file.writeAsBytes(bytes!.buffer.asUint8List());
              image.dispose();
            });
          });
        }
      }
    }
  });
}
