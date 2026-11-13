import 'dart:ui' show Tristate;

import 'package:bloc_test/bloc_test.dart';
import 'package:drift/native.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/core/telemetry/telemetry_adapters.dart';
import 'package:dzeroth/core/telemetry/telemetry_consent_copy.dart';
import 'package:dzeroth/core/telemetry/telemetry_consent_cubit.dart';
import 'package:dzeroth/core/telemetry/telemetry_consent_store.dart';
import 'package:dzeroth/core/telemetry/telemetry_controller.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/telemetry_consent_card.dart';
import 'package:dzeroth/features/notifications/data/notifications_repository.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/push_cubit.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/push_opt_in_cubit.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/settings/presentation/widgets/telemetry_consent_row.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/fake_push_messaging.dart';
import '../../support/fake_push_opt_in_store.dart';
import '../telemetry/fake_telemetry.dart';

class MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class MockNotificationsRepository extends Mock
    implements NotificationsRepository {}

void main() {
  late AppDatabase database;
  late TelemetryConsentStore store;
  late TelemetryConsentCubit consent;
  late MockOnboardingBloc onboarding;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    store = TelemetryConsentStore(database);
    consent = TelemetryConsentCubit(store: store);
    onboarding = MockOnboardingBloc();
  });

  tearDown(() async {
    await consent.close();
    await store.dispose();
    await database.close();
  });

  const crashRow = 'Send crash reports';
  const usageRow = 'Share usage statistics';
  const both = {'crash_reporting', 'analytics'};

  Future<void> open(
    WidgetTester tester, {
    Set<String> features = both,
    bool supported = true,
    String? uid = 'uid-a',
    Widget? extra,
    double textScale = 1,
    Size size = const Size(400, 900),
    List<BlocProvider> providers = const [],
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(enabledFeatures: features),
    );
    await consent.load(uid);
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<OnboardingBloc>.value(value: onboarding),
          BlocProvider<TelemetryConsentCubit>.value(value: consent),
          ...providers,
        ],
        child: MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(textScale),
          ),
          child: MaterialApp(
            theme: appLightTheme,
            home: Scaffold(
              body: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: TelemetryConsentCard(supported: supported),
                  ),
                  if (extra != null) SliverToBoxAdapter(child: extra),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The consent store reads and writes a real (in-memory) database, whose
  /// futures complete outside the fake clock: let them finish, then pump.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(pumpEventQueue);
    await tester.pumpAndSettle();
  }

  Finder switchOf(String label) => find.descendant(
    of: find.ancestor(of: find.text(label), matching: find.byType(InkWell)),
    matching: find.byType(Switch),
  );

  group('when it shows', () {
    testWidgets('both flags on and nothing asked: title, two off switches, '
        'one sentence each, Save, Not now and the policy link', (tester) async {
      await open(tester);

      expect(find.text(TelemetryConsentCopy.cardTitle), findsOneWidget);
      for (final label in [crashRow, usageRow]) {
        expect(find.text(label), findsOneWidget);
        expect(tester.widget<Switch>(switchOf(label)).value, isFalse);
      }
      expect(
        find.textContaining('Not linked to your account'),
        findsNWidgets(2),
      );
      expect(find.text('Save'), findsOneWidget);
      expect(find.text('Not now'), findsOneWidget);
      expect(find.text('Privacy Policy'), findsOneWidget);
    });

    testWidgets('only the crash flag on: one switch', (tester) async {
      await open(tester, features: const {'crash_reporting'});

      expect(find.text(crashRow), findsOneWidget);
      expect(find.text(usageRow), findsNothing);
    });

    testWidgets('only the analytics flag on: one switch', (tester) async {
      await open(tester, features: const {'analytics'});

      expect(find.text(crashRow), findsNothing);
      expect(find.text(usageRow), findsOneWidget);
    });

    testWidgets('a kind already answered is not asked again', (tester) async {
      await store.load('uid-a');
      await store.set('uid-a', TelemetryKind.crash, ConsentChoice.off);
      await open(tester);

      expect(find.text(crashRow), findsNothing);
      expect(find.text(usageRow), findsOneWidget);
    });
  });

  group('when it does not show', () {
    testWidgets('both flags off: no card', (tester) async {
      await open(tester, features: const {});
      expect(find.text(TelemetryConsentCopy.cardTitle), findsNothing);
    });

    testWidgets('web or iOS (unsupported platform): no card', (tester) async {
      await open(tester, supported: false);
      expect(find.text(TelemetryConsentCopy.cardTitle), findsNothing);
    });

    testWidgets('signed out: no card', (tester) async {
      await open(tester, uid: null);
      expect(find.text(TelemetryConsentCopy.cardTitle), findsNothing);
    });

    testWidgets('both kinds answered: no card', (tester) async {
      await store.load('uid-a');
      await store.setAll('uid-a', {
        TelemetryKind.crash: ConsentChoice.on,
        TelemetryKind.usage: ConsentChoice.off,
      });
      await open(tester);
      expect(find.text(TelemetryConsentCopy.cardTitle), findsNothing);
    });
  });

  group('actions', () {
    testWidgets('Save stores what was switched on and the rest off', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(find.text(crashRow));
      await tester.pump();
      expect(tester.widget<Switch>(switchOf(crashRow)).value, isTrue);

      await tester.tap(find.text('Save'));
      await settle(tester);

      expect(store.crashConsented('uid-a'), isTrue);
      expect(store.choice('uid-a', TelemetryKind.usage), ConsentChoice.off);
      expect(find.text(TelemetryConsentCopy.cardTitle), findsNothing);
    });

    testWidgets('Save with nothing switched on stores off for both', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(find.text('Save'));
      await settle(tester);

      expect(store.choice('uid-a', TelemetryKind.crash), ConsentChoice.off);
      expect(store.choice('uid-a', TelemetryKind.usage), ConsentChoice.off);
      expect(find.text(TelemetryConsentCopy.cardTitle), findsNothing);
    });

    testWidgets('Not now stores off for both and the card never returns', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(find.text('Not now'));
      await settle(tester);

      expect(find.text(TelemetryConsentCopy.cardTitle), findsNothing);
      expect(
        await database.readSetting('telemetry_consent:crash:uid-a'),
        'off',
      );
      expect(
        await database.readSetting('telemetry_consent:usage:uid-a'),
        'off',
      );

      // A relaunch: a fresh cubit over the same disk.
      final relaunchedStore = TelemetryConsentStore(database);
      final relaunched = TelemetryConsentCubit(store: relaunchedStore);
      addTearDown(() async {
        await relaunched.close();
        await relaunchedStore.dispose();
      });
      await relaunched.load('uid-a');
      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider<OnboardingBloc>.value(value: onboarding),
            BlocProvider<TelemetryConsentCubit>.value(value: relaunched),
          ],
          child: const MaterialApp(
            home: Scaffold(body: TelemetryConsentCard(supported: true)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(TelemetryConsentCopy.cardTitle), findsNothing);
    });

    testWidgets('Not now keeps an answer already given', (tester) async {
      await store.load('uid-a');
      await store.set('uid-a', TelemetryKind.crash, ConsentChoice.on);
      await open(tester);
      await tester.tap(find.text('Not now'));
      await settle(tester);

      expect(store.crashConsented('uid-a'), isTrue);
      expect(store.choice('uid-a', TelemetryKind.usage), ConsentChoice.off);
    });

    testWidgets('a second account on the device is asked on its own', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(find.text('Not now'));
      await settle(tester);
      expect(find.text(TelemetryConsentCopy.cardTitle), findsNothing);

      await consent.load('uid-b');
      await settle(tester);
      expect(find.text(TelemetryConsentCopy.cardTitle), findsOneWidget);
    });
  });

  group('one card at a time, push first', () {
    testWidgets('waits while the notifications card is offered', (
      tester,
    ) async {
      final messaging = FakePushMessaging();
      final repo = MockNotificationsRepository();
      when(() => repo.enabled).thenReturn(true);
      final push = PushCubit(messaging: messaging, repository: repo);
      final optIn = PushOptInCubit(store: FakePushOptInStore(), push: push);
      addTearDown(() async {
        await optIn.close();
        await push.close();
      });
      await push.start();
      await optIn.load('uid-a');

      await open(
        tester,
        features: {...both, 'notifications'},
        providers: [
          BlocProvider<PushCubit>.value(value: push),
          BlocProvider<PushOptInCubit>.value(value: optIn),
        ],
      );
      expect(find.text(TelemetryConsentCopy.cardTitle), findsNothing);

      await optIn.notNow();
      await settle(tester);
      expect(find.text(TelemetryConsentCopy.cardTitle), findsOneWidget);
    });
  });

  group('accessibility and layout', () {
    testWidgets('each switch is one node: label, state and sentence once', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await open(tester);

      for (final label in [crashRow, usageRow]) {
        final node = tester.getSemantics(
          find.bySemanticsLabel(RegExp('^$label\n')),
        );
        expect(node.label, startsWith(label));
        expect(node.flagsCollection.isToggled, isNot(Tristate.none));
        expect(node.flagsCollection.isToggled, Tristate.isFalse);
      }
      // No second node repeats a label (the inner Switch is excluded).
      expect(find.bySemanticsLabel(RegExp('^$crashRow')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('^$usageRow')), findsOneWidget);

      await tester.tap(find.text(crashRow));
      await tester.pump();
      expect(
        tester
            .getSemantics(find.bySemanticsLabel(RegExp('^$crashRow\n')))
            .flagsCollection
            .isToggled,
        Tristate.isTrue,
      );
      handle.dispose();
    });

    testWidgets('text scale 2.0 at 360 dp: no overflow, actions reachable', (
      tester,
    ) async {
      await open(tester, textScale: 2, size: const Size(360, 800));

      expect(tester.takeException(), isNull);
      expect(find.text('Save'), findsOneWidget);
      expect(find.text('Not now'), findsOneWidget);
    });

    for (final width in <double>[360, 1024, 1440]) {
      testWidgets('$width dp: Save takes a tap anywhere in its 48 dp box; Not '
          'now beside it and the policy link under it keep their own', (
        tester,
      ) async {
        await open(tester, size: Size(width, 900));
        final save = find.ancestor(
          of: find.text('Save'),
          matching: find.byType(AppPillButton),
        );
        final box = tester.getRect(save);
        final pill = tester.getRect(
          find.descendant(of: save, matching: find.byType(Ink)),
        );
        final notNow = tester.getRect(
          find.ancestor(
            of: find.text('Not now'),
            matching: find.byType(TextButton),
          ),
        );
        final link = tester.getRect(
          find
              .ancestor(
                of: find.text('Privacy Policy'),
                matching: find.byType(InkWell),
              )
              .first,
        );
        expect(box.height, AppSpacing.minTapTarget);
        expect(pill.height, AppSize.pillCompact);
        // One run, side by side, and no box overlaps another.
        expect(notNow.center.dy, closeTo(box.center.dy, 0.5));
        expect(box.overlaps(notNow), isFalse);
        expect(box.overlaps(link), isFalse);
        expect(box.bottom, lessThanOrEqualTo(link.top));

        // The gap between Save and Not now, at the height of the band.
        await tester.tapAt(Offset((box.right + notNow.left) / 2, pill.top - 5));
        await settle(tester);
        expect(find.text(TelemetryConsentCopy.cardTitle), findsOneWidget);
        expect(
          store.choice('uid-a', TelemetryKind.crash),
          ConsentChoice.unasked,
        );

        // 5 dp under the pill, just above the policy link: Save.
        await tester.tapAt(Offset(pill.center.dx, pill.bottom + 5));
        await settle(tester);
        expect(store.choice('uid-a', TelemetryKind.crash), ConsentChoice.off);
        expect(store.choice('uid-a', TelemetryKind.usage), ConsentChoice.off);
        expect(find.text(TelemetryConsentCopy.cardTitle), findsNothing);
      });
    }
  });

  group('Settings rows', () {
    Future<void> openRows(
      WidgetTester tester, {
      Set<String> features = both,
    }) async {
      whenListen(
        onboarding,
        const Stream<OnboardingState>.empty(),
        initialState: OnboardingState(enabledFeatures: features),
      );
      await consent.load('uid-a');
      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider<OnboardingBloc>.value(value: onboarding),
            BlocProvider<TelemetryConsentCubit>.value(value: consent),
          ],
          child: MaterialApp(
            theme: appLightTheme,
            home: Scaffold(
              body: Builder(
                builder: (context) => Column(
                  children: [
                    for (final kind in TelemetryKind.values)
                      if (telemetryRowVisible(context, kind, supported: true))
                        TelemetryConsentRow(kind: kind),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('rows show per flag with the subtitle', (tester) async {
      await openRows(tester);
      expect(find.text(crashRow), findsOneWidget);
      expect(find.text(usageRow), findsOneWidget);
      expect(
        find.text('This device only. Not linked to your account.'),
        findsNWidgets(2),
      );
    });

    testWidgets('both flags off: no rows', (tester) async {
      await openRows(tester, features: const {});
      expect(find.text(crashRow), findsNothing);
      expect(find.text(usageRow), findsNothing);
    });

    testWidgets('one flag: only its row', (tester) async {
      await openRows(tester, features: const {'analytics'});
      expect(find.text(crashRow), findsNothing);
      expect(find.text(usageRow), findsOneWidget);
    });

    testWidgets('a switch turns collection on and off at once', (tester) async {
      final log = CallLog();
      final controller = TelemetryController(
        adapters: TelemetryAdapters(
          crash: FakeCrashReporter(log),
          analytics: FakeUsageAnalytics(log),
        ),
        platformSupported: true,
        consent: store,
        debugLog: (_) {},
      );
      addTearDown(controller.dispose);
      await controller.applyAtBootstrap('uid-a');
      controller.onEnabledFeatures(both);
      await openRows(tester);
      log.clear();

      await tester.tap(find.text(crashRow));
      await settle(tester);
      expect(controller.crashCollecting, isTrue);
      expect(controller.usageCollecting, isFalse);
      expect(log.calls, contains('crash.setCollecting(true)'));

      await tester.tap(find.text(crashRow));
      await settle(tester);
      expect(controller.crashCollecting, isFalse);
      expect(log.calls, contains('crash.setCollecting(false)'));
      expect(log.calls, contains('crash.deleteUnsent'));
      expect(
        await database.readSetting('telemetry_consent:crash:uid-a'),
        'off',
      );
    });
  });
}
