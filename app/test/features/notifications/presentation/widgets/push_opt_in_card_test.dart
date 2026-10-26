import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/notifications/data/notifications_repository.dart';
import 'package:dzeroth/features/notifications/data/push_messaging.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/push_cubit.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/push_opt_in_cubit.dart';
import 'package:dzeroth/features/notifications/presentation/widgets/push_opt_in_card.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/notifications/v1/notifications.pbenum.dart';
import 'package:dzeroth/shared/widgets/app_pill_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/fake_push_messaging.dart';
import '../../../../support/fake_push_opt_in_store.dart';

class MockNotificationsRepository extends Mock
    implements NotificationsRepository {}

class MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

void main() {
  final base = DateTime.now().toUtc();
  late DateTime now;
  late FakePushOptInStore store;
  late FakePushMessaging messaging;
  late MockNotificationsRepository repo;
  late MockOnboardingBloc onboarding;
  late PushCubit push;
  late PushOptInCubit optIn;

  setUpAll(() {
    registerFallbackValue(DevicePlatform.DEVICE_PLATFORM_ANDROID);
  });

  setUp(() {
    now = base;
    store = FakePushOptInStore();
    messaging = FakePushMessaging();
    repo = MockNotificationsRepository();
    onboarding = MockOnboardingBloc();
    when(() => repo.enabled).thenReturn(true);
    when(() => repo.deviceId(any())).thenAnswer((_) async => 'device-1');
    when(
      () => repo.registerDevice(
        idempotencyKey: any(named: 'idempotencyKey'),
        deviceId: any(named: 'deviceId'),
        fcmToken: any(named: 'fcmToken'),
        platform: any(named: 'platform'),
      ),
    ).thenAnswer((_) async {});
    push = PushCubit(messaging: messaging, repository: repo);
    optIn = PushOptInCubit(store: store, push: push, now: () => now);
  });

  tearDown(() async {
    await optIn.close();
    await push.close();
  });

  /// Both placements in one tree, like Home and Notifications sharing the
  /// app-level cubits.
  Future<void> open(
    WidgetTester tester, {
    Set<String> features = const {'notifications'},
    List<PushOptInPlacement> placements = const [PushOptInPlacement.home],
    String? uid = 'uid-a',
    bool startPush = true,
    ThemeData? theme,
    Size size = const Size(400, 800),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(enabledFeatures: features),
    );
    if (startPush) await push.start();
    await optIn.load(uid);
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<OnboardingBloc>.value(value: onboarding),
          BlocProvider<PushCubit>.value(value: push),
          BlocProvider<PushOptInCubit>.value(value: optIn),
        ],
        child: MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(textScale),
          ),
          child: MaterialApp(
            theme: theme ?? appLightTheme,
            home: Scaffold(
              body: CustomScrollView(
                slivers: [
                  for (final placement in placements)
                    SliverToBoxAdapter(
                      child: PushOptInCard(placement: placement),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  const hint = 'Notifications are off in your device settings';

  group('when it shows', () {
    testWidgets('canPrompt and no dismissal: title, copy and both actions', (
      tester,
    ) async {
      await open(tester);

      expect(find.text('Turn on notifications'), findsOneWidget);
      expect(
        find.text('Get a heads-up when someone follows or mentions you.'),
        findsOneWidget,
      );
      expect(find.text('Turn on'), findsOneWidget);
      expect(find.text('Not now'), findsOneWidget);
      expect(messaging.permissionRequests, 0, reason: 'the OS is asked on tap');
    });

    testWidgets('it is the same card in both placements', (tester) async {
      await open(
        tester,
        placements: const [
          PushOptInPlacement.home,
          PushOptInPlacement.notifications,
        ],
      );

      expect(find.text('Turn on notifications'), findsNWidgets(2));
    });
  });

  group('when it stays away', () {
    testWidgets('the notifications flag is off', (tester) async {
      await open(tester, features: const {});

      expect(find.text('Turn on notifications'), findsNothing);
      expect(find.text('Not now'), findsNothing);
    });

    testWidgets('web (push unsupported: PushState.supported is false)', (
      tester,
    ) async {
      messaging.supported = false;
      await open(tester);

      expect(find.text('Turn on notifications'), findsNothing);
    });

    testWidgets('iOS until the Apple launch', (tester) async {
      await open(tester);

      expect(find.text('Turn on notifications'), findsNothing);
      expect(find.text('Turn on'), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('push was already granted (no flash before it is known)', (
      tester,
    ) async {
      messaging.currentPermission = PushPermission.granted;
      when(() => repo.deviceId(any())).thenAnswer((_) async => 'device-1');
      await open(tester);

      expect(find.text('Turn on notifications'), findsNothing);
    });

    testWidgets('the permission is not read yet', (tester) async {
      await open(tester, startPush: false);

      expect(push.state.canPrompt, isTrue, reason: 'only the default');
      expect(find.text('Turn on notifications'), findsNothing);
    });

    testWidgets('signed out (no uid, no record)', (tester) async {
      await open(tester, uid: null);

      expect(find.text('Turn on notifications'), findsNothing);
    });
  });

  group('Not now', () {
    testWidgets('hides the card in both placements and saves it per uid', (
      tester,
    ) async {
      await open(
        tester,
        placements: const [
          PushOptInPlacement.home,
          PushOptInPlacement.notifications,
        ],
      );

      await tester.tap(find.text('Not now').first);
      await tester.pumpAndSettle();

      expect(find.text('Turn on notifications'), findsNothing);
      expect(store.records.keys, ['uid-a']);
      expect(messaging.permissionRequests, 0);
    });

    testWidgets('stays hidden next launch, shows again after 30 days', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();

      // A new launch: the same disk, a new cubit, 29 days later.
      await optIn.close();
      now = base.add(const Duration(days: 29, hours: 23));
      optIn = PushOptInCubit(store: store, push: push, now: () => now);
      await open(tester);
      expect(find.text('Turn on notifications'), findsNothing);

      // Another launch: 30 days later.
      await optIn.close();
      now = base.add(const Duration(days: 30));
      optIn = PushOptInCubit(store: store, push: push, now: () => now);
      await open(tester);
      expect(find.text('Turn on notifications'), findsOneWidget);
    });

    testWidgets('another account on the same device still sees it', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(find.text('Turn on notifications'), findsNothing);

      await optIn.load('uid-b');
      await tester.pumpAndSettle();

      expect(find.text('Turn on notifications'), findsOneWidget);
    });
  });

  group('Turn on', () {
    testWidgets('asks the OS once, registers once and the card goes away', (
      tester,
    ) async {
      await open(
        tester,
        placements: const [
          PushOptInPlacement.home,
          PushOptInPlacement.notifications,
        ],
      );

      await tester.tap(find.text('Turn on').first);
      await tester.pumpAndSettle();

      expect(messaging.permissionRequests, 1);
      expect(find.text('Turn on notifications'), findsNothing);
      expect(find.text(hint), findsNothing);
      verify(
        () => repo.registerDevice(
          idempotencyKey: any(named: 'idempotencyKey'),
          deviceId: 'device-1',
          fcmToken: 'fcm-token-1',
          platform: any(named: 'platform'),
        ),
      ).called(1);
    });

    testWidgets('a denial shows the settings hint on Notifications', (
      tester,
    ) async {
      messaging.nextPermissionAnswer = PushPermission.denied;
      await open(tester, placements: const [PushOptInPlacement.notifications]);

      await tester.tap(find.text('Turn on'));
      await tester.pumpAndSettle();

      expect(find.text('Turn on notifications'), findsNothing);
      expect(find.text(hint), findsOneWidget);
      verifyNever(
        () => repo.registerDevice(
          idempotencyKey: any(named: 'idempotencyKey'),
          deviceId: any(named: 'deviceId'),
          fcmToken: any(named: 'fcmToken'),
          platform: any(named: 'platform'),
        ),
      );
    });

    testWidgets('a denial shows nothing on Home', (tester) async {
      messaging.nextPermissionAnswer = PushPermission.denied;
      await open(tester, placements: const [PushOptInPlacement.home]);

      await tester.tap(find.text('Turn on'));
      await tester.pumpAndSettle();

      expect(find.text('Turn on notifications'), findsNothing);
      expect(find.text(hint), findsNothing);
    });

    testWidgets('a denial on Home leaves the hint for Notifications', (
      tester,
    ) async {
      messaging.nextPermissionAnswer = PushPermission.denied;
      await open(
        tester,
        placements: const [
          PushOptInPlacement.home,
          PushOptInPlacement.notifications,
        ],
      );

      await tester.tap(find.text('Turn on').first);
      await tester.pumpAndSettle();

      expect(find.text(hint), findsOneWidget);
    });

    testWidgets('the hint is not shown for a denial from an earlier session', (
      tester,
    ) async {
      messaging.currentPermission = PushPermission.denied;
      await open(tester, placements: const [PushOptInPlacement.notifications]);

      expect(find.text(hint), findsNothing);
      expect(find.text('Turn on notifications'), findsNothing);
    });
  });

  group('accessibility and layout', () {
    for (final dark in [false, true]) {
      testWidgets(
        '320dp wide at 2.0 text scale, ${dark ? 'dark' : 'light'}: no overflow',
        (tester) async {
          await open(
            tester,
            theme: dark ? appDarkTheme : appLightTheme,
            size: const Size(320, 640),
            textScale: 2,
            placements: const [
              PushOptInPlacement.home,
              PushOptInPlacement.notifications,
            ],
          );

          expect(tester.takeException(), isNull);
          expect(find.text('Turn on'), findsNWidgets(2));
          expect(find.text('Not now'), findsNWidgets(2));
        },
      );
    }

    testWidgets('the title is a header, the actions are labelled buttons', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await open(tester);

      expect(
        tester.getSemantics(find.text('Turn on notifications')),
        matchesSemantics(label: 'Turn on notifications', isHeader: true),
      );
      expect(find.bySemanticsLabel('Turn on'), findsOneWidget);
      expect(
        tester.getSemantics(find.text('Not now')),
        matchesSemantics(
          label: 'Not now',
          isButton: true,
          isEnabled: true,
          isFocusable: true,
          hasTapAction: true,
          hasFocusAction: true,
          hasEnabledState: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('both actions have a 48dp target', (tester) async {
      await open(tester);

      final pill = tester.getSize(find.byType(AppPillButton));
      expect(pill.height, greaterThanOrEqualTo(48));
      expect(
        tester.getSize(find.widgetWithText(TextButton, 'Not now')).height,
        greaterThanOrEqualTo(48),
      );
    });
  });

  // ---------------------------------------------------------------------
  // W2-13 (tester): the opt-in card across the responsive matrix, and a
  // fast double tap on "Turn on".
  // ---------------------------------------------------------------------

  group('W2-13 responsive matrix', () {
    for (final dark in [false, true]) {
      for (final width in const [360.0, 600.0, 1200.0]) {
        for (final scale in const [1.0, 1.3, 2.0]) {
          testWidgets(
            '${dark ? 'dark' : 'light'} ${width.toInt()}dp x$scale: both '
            'placements fit, 48dp actions, text inside the screen',
            (tester) async {
              await open(
                tester,
                theme: dark ? appDarkTheme : appLightTheme,
                size: Size(width, 900),
                textScale: scale,
                placements: const [
                  PushOptInPlacement.home,
                  PushOptInPlacement.notifications,
                ],
              );

              expect(tester.takeException(), isNull);
              expect(find.text('Turn on notifications'), findsNWidgets(2));
              expect(find.text('Turn on'), findsNWidgets(2));
              expect(find.text('Not now'), findsNWidgets(2));
              for (final f in [
                find.byType(AppPillButton),
                find.widgetWithText(TextButton, 'Not now'),
              ]) {
                for (var i = 0; i < 2; i++) {
                  expect(
                    tester.getSize(f.at(i)).height,
                    greaterThanOrEqualTo(48),
                  );
                }
              }
              final title = tester.getRect(
                find.text('Turn on notifications').first,
              );
              expect(title.left, greaterThanOrEqualTo(0));
              expect(title.right, lessThanOrEqualTo(width));
            },
          );
        }
      }
    }
  });

  group('W2-13 double tap', () {
    testWidgets('two taps on "Turn on" before a frame ask the OS once and '
        'register one device', (tester) async {
      await open(tester);

      await tester.tap(find.text('Turn on'));
      await tester.tap(find.text('Turn on'), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(messaging.permissionRequests, 1);
      verify(
        () => repo.registerDevice(
          idempotencyKey: any(named: 'idempotencyKey'),
          deviceId: any(named: 'deviceId'),
          fcmToken: any(named: 'fcmToken'),
          platform: any(named: 'platform'),
        ),
      ).called(1);
      expect(find.text('Turn on notifications'), findsNothing);
    });

    testWidgets('a double tap on "Turn on" that is denied asks once and shows '
        'one hint', (tester) async {
      messaging.nextPermissionAnswer = PushPermission.denied;
      await open(tester, placements: const [PushOptInPlacement.notifications]);

      await tester.tap(find.text('Turn on'));
      await tester.tap(find.text('Turn on'), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(messaging.permissionRequests, 1);
      expect(find.text(hint), findsOneWidget);
      verifyNever(
        () => repo.registerDevice(
          idempotencyKey: any(named: 'idempotencyKey'),
          deviceId: any(named: 'deviceId'),
          fcmToken: any(named: 'fcmToken'),
          platform: any(named: 'platform'),
        ),
      );
    });
  });

  testWidgets('W2-13: while the OS dialog is still open a second tap does not ask '
      'again; the answer registers once', (tester) async {
    final held = _HeldPermissionMessaging();
    await optIn.close();
    await push.close();
    push = PushCubit(messaging: held, repository: repo);
    optIn = PushOptInCubit(store: store, push: push, now: () => now);
    await open(tester);

    await tester.tap(find.text('Turn on'));
    await tester.pump();
    expect(held.permissionRequests, 1);
    expect(find.text('Turn on'), findsOneWidget, reason: 'busy, still there');
    await tester.tap(find.text('Turn on'));
    await tester.pump();
    expect(held.permissionRequests, 1, reason: 'the second tap was ignored');
    await push.enable(); // a stray programmatic second call is ignored too
    expect(held.permissionRequests, 1);

    held.gate.complete(PushPermission.granted);
    await tester.pumpAndSettle();

    expect(held.permissionRequests, 1);
    verify(
      () => repo.registerDevice(
        idempotencyKey: any(named: 'idempotencyKey'),
        deviceId: any(named: 'deviceId'),
        fcmToken: any(named: 'fcmToken'),
        platform: any(named: 'platform'),
      ),
    ).called(1);
  });
}

/// A messaging fake whose OS permission dialog stays open until [gate] completes.
class _HeldPermissionMessaging extends FakePushMessaging {
  final Completer<PushPermission> gate = Completer<PushPermission>();

  @override
  Future<PushPermission> requestPermission() {
    permissionRequests++;
    return gate.future.then((answer) {
      currentPermission = answer;
      return answer;
    });
  }
}
