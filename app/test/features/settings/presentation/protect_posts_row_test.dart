import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/theme/theme_mode_cubit.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/settings/domain/private_accounts_feature_flag.dart';
import 'package:dzeroth/features/settings/presentation/protect_posts_messages.dart';
import 'package:dzeroth/features/settings/presentation/settings_screen.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/geometry.dart';
import '../../../support/theme_harness.dart';

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MemoryThemeStore implements ThemeModeStore {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) async {}
}

/// Records every `setProtected` call and answers with the profile the server
/// would return; queue failures in [failures] (null = succeed).
class _FakeIdentity extends Fake implements IdentityRepository {
  final calls = <({String key, bool protect})>[];
  final failures = <Object?>[];
  bool refused = false;

  @override
  bool get privateAccountsRefused => refused;

  @override
  Future<identity.Profile> setProtected({
    required String idempotencyKey,
    required bool protect,
  }) async {
    calls.add((key: idempotencyKey, protect: protect));
    if (failures.isNotEmpty) {
      final failure = failures.removeAt(0);
      if (failure != null) {
        if (failure is FeatureDisabledException && protect) refused = true;
        throw failure;
      }
    }
    return identity.Profile(userId: 'me', handle: 'kaif', isPrivate: protect);
  }
}

/// W3-33b: the Settings "Protect your posts" switch, its two confirm dialogs
/// and its error copy, across the W3-21 matrix (360 / 600 / 1200 dp x light /
/// dark x text scale 1.0 / 1.3 / 2.0).
void main() {
  late _MockOnboardingBloc onboarding;
  late _FakeIdentity fake;

  setUpAll(() {
    registerFallbackValue(const OnboardingRefreshRequested());
  });

  setUp(() {
    onboarding = _MockOnboardingBloc();
    fake = _FakeIdentity();
  });

  Future<void> open(
    WidgetTester tester, {
    Set<String> flags = const {kFeaturePrivateAccounts},
    bool isPrivate = false,
    MatrixEnv? env,
  }) async {
    final auth = _MockAuthBloc();
    whenListen(
      auth,
      const Stream<AuthState>.empty(),
      initialState: const AuthState(status: AuthStatus.authenticated),
    );
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        enabledFeatures: flags,
        profile: identity.Profile(
          userId: 'me',
          handle: 'kaif',
          isPrivate: isPrivate,
        ),
      ),
    );
    await pumpThemed(
      tester,
      RepositoryProvider<IdentityRepository>.value(
        value: fake,
        child: MultiBlocProvider(
          providers: [
            BlocProvider<AuthBloc>.value(value: auth),
            BlocProvider<OnboardingBloc>.value(value: onboarding),
            BlocProvider<ThemeModeCubit>(
              create: (_) => ThemeModeCubit(_MemoryThemeStore()),
            ),
          ],
          child: const SettingsList(),
        ),
      ),
      brightness: env?.brightness ?? Brightness.light,
      size: env?.size ?? const Size(400, 1400),
      textScale: env?.textScale ?? 1.0,
    );
  }

  final row = find.ancestor(
    of: find.text(kProtectPostsTitle),
    matching: find.byType(InkWell),
  );
  final rowSwitch = find.byType(Switch);

  Future<void> reveal(WidgetTester tester) async {
    await tester.ensureVisible(find.text(kProtectPostsTitle));
    await tester.pumpAndSettle();
  }

  group('turn on', () {
    forEachThemeAndWidth(
      'row, dialog and buttons fit; confirm saves once',
      (tester, env) async {
        await open(tester, env: env);
        await reveal(tester);
        expect(tester.takeException(), isNull);
        expect(tester.widget<Switch>(rowSwitch).value, isFalse);
        expectMinTarget(tester, row, reason: 'Protect row');
        expectInsideHorizontally(tester, row, env.size.width);

        await tester.tap(row);
        await tester.pumpAndSettle();
        expect(find.text(kProtectConfirmTitle), findsOneWidget);
        for (final point in kProtectConfirmPoints) {
          expect(find.text(point), findsOneWidget, reason: point);
        }
        // Founder answer B1: shared images may still open from their link.
        expect(
          find.textContaining('may still open for anyone who has their link'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        for (final label in ['Cancel', kProtectConfirmAction]) {
          final button = find.widgetWithText(TextButton, label);
          await tester.ensureVisible(button);
          expectMinTarget(tester, button, reason: label);
        }

        await tester.tap(
          find.widgetWithText(TextButton, kProtectConfirmAction),
        );
        await tester.pumpAndSettle();
        expect(fake.calls.map((c) => c.protect), [true]);
        final updated =
            verify(
                  () => onboarding.add(
                    captureAny(that: isA<OnboardingProfileUpdated>()),
                  ),
                ).captured.single
                as OnboardingProfileUpdated;
        expect(updated.profile.isPrivate, isTrue);
      },
      textScales: kMatrixTextScalesLarge,
      height: 1400,
    );
  });

  group('turn off', () {
    forEachThemeAndWidth(
      'a protected account sees the switch on, whatever the flag',
      (tester, env) async {
        await open(tester, flags: const {}, isPrivate: true, env: env);
        await reveal(tester);
        expect(tester.takeException(), isNull);
        expect(tester.widget<Switch>(rowSwitch).value, isTrue);
        expectMinTarget(tester, row, reason: 'Protect row');

        await tester.tap(row);
        await tester.pumpAndSettle();
        expect(find.text(kUnprotectConfirmTitle), findsOneWidget);
        expect(find.text(kUnprotectConfirmBody), findsOneWidget);
        expect(find.textContaining('approved automatically'), findsOneWidget);
        final confirm = find.widgetWithText(
          TextButton,
          kUnprotectConfirmAction,
        );
        await tester.ensureVisible(confirm);
        expectMinTarget(tester, confirm);

        await tester.tap(confirm);
        await tester.pumpAndSettle();
        expect(fake.calls.map((c) => c.protect), [false]);
      },
      textScales: kMatrixTextScalesLarge,
      height: 1400,
    );
  });

  testWidgets('a public account without the flag has no switch', (
    tester,
  ) async {
    await open(tester, flags: const {});
    expect(find.text(kProtectPostsTitle), findsNothing);
    expect(rowSwitch, findsNothing);
  });

  // W3-35c: who sees the switch and in which position (the visibility rule:
  // the flag decides turning ON; a protected account always sees its way
  // OFF, the undo rule), and which confirm each row opens.
  for (final entry in {
    'public, flag off': (
      flags: const <String>{},
      isPrivate: false,
      shown: false,
      on: false,
    ),
    'public, flag on': (
      flags: const {kFeaturePrivateAccounts},
      isPrivate: false,
      shown: true,
      on: false,
    ),
    'protected, flag off': (
      flags: const <String>{},
      isPrivate: true,
      shown: true,
      on: true,
    ),
    'protected, flag on': (
      flags: const {kFeaturePrivateAccounts},
      isPrivate: true,
      shown: true,
      on: true,
    ),
  }.entries) {
    testWidgets('visibility: ${entry.key}', (tester) async {
      final v = entry.value;
      await open(tester, flags: v.flags, isPrivate: v.isPrivate);
      expect(
        find.text(kProtectPostsTitle),
        v.shown ? findsOneWidget : findsNothing,
      );
      if (!v.shown) return;
      await reveal(tester);
      expect(tester.widget<Switch>(rowSwitch).value, v.on);
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(
        find.text(v.on ? kUnprotectConfirmTitle : kProtectConfirmTitle),
        findsOneWidget,
      );
      expect(
        find.text(v.on ? kProtectConfirmTitle : kUnprotectConfirmTitle),
        findsNothing,
      );
    });
  }

  testWidgets('Cancel saves nothing', (tester) async {
    await open(tester);
    await reveal(tester);
    await tester.tap(row);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(fake.calls, isEmpty);
    expect(tester.widget<Switch>(rowSwitch).value, isFalse);
  });

  group('errors', () {
    Future<void> turnOn(WidgetTester tester) async {
      await tester.tap(row);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, kProtectConfirmAction));
      await tester.pumpAndSettle();
    }

    Future<void> failWith(WidgetTester tester, Object failure) async {
      fake.failures.add(failure);
      await open(tester);
      await reveal(tester);
      await turnOn(tester);
    }

    testWidgets('the daily quota says 4 times a day and the switch stays off', (
      tester,
    ) async {
      await failWith(
        tester,
        const QuotaExceededException('x', quota: kPrivacyTogglesQuotaName),
      );
      expect(
        find.text('You can change this 4 times a day. Try again tomorrow.'),
        findsOneWidget,
      );
      expect(tester.widget<Switch>(rowSwitch).value, isFalse);
      expect(fake.calls.single.protect, isTrue);
    });

    testWidgets('the protected-accounts cap has its own copy', (tester) async {
      await failWith(
        tester,
        const LimitReachedException('x', quota: kPrivateAccountsLimitName),
      );
      expect(find.textContaining('are full right now'), findsOneWidget);
      expect(tester.widget<Switch>(rowSwitch).value, isFalse);
    });

    testWidgets('a retry reuses the idempotency key of the same intent', (
      tester,
    ) async {
      await failWith(tester, const NetworkException('offline'));
      expect(find.textContaining('No connection'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await turnOn(tester);
      expect(fake.calls, hasLength(2));
      expect(fake.calls[0].key, fake.calls[1].key);
    });

    testWidgets('FEATURE_DISABLED on turn-on hides the switch and refreshes '
        'GetMe', (tester) async {
      await failWith(
        tester,
        const FeatureDisabledException('x', feature: kFeaturePrivateAccounts),
      );
      expect(find.text(kProtectPostsTitle), findsNothing);
      verify(() => onboarding.add(any(that: isA<OnboardingRefreshRequested>())))
          .called(1);
    });
  });

  test('every failure maps to a fixed message', () {
    expect(
      protectPostsErrorMessage(const DegradedModeException('x')),
      contains('limited mode'),
    );
    expect(
      protectPostsErrorMessage(const UnknownApiException('boom')),
      "Couldn't change this setting. Please try again.",
    );
  });
}
