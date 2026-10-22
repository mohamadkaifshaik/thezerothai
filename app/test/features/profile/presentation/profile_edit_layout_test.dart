import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/features/onboarding/domain/handle_rules.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/profile/domain/profile_edit_feature_flag.dart';
import 'package:dzeroth/features/profile/presentation/change_handle_screen.dart';
import 'package:dzeroth/features/profile/presentation/edit_profile_screen.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/shared/widgets/app_gradient_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

class _MockRepo extends Mock implements IdentityRepository {}

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

identity.Profile _profile() => identity.Profile(
  userId: 'me',
  handle: 'kaif',
  displayName: 'Kaif',
  bio: 'hello there',
);

/// Layout and state coverage of the restyled Edit profile and Change handle
/// (UI slice profile + onboarding). What they DO is owned by
/// profile_edit_screens_test.dart; the Save-disabled and validation cases are
/// repeated here against the new header so a layout change cannot loosen them.
void main() {
  setUpAll(() {
    registerFallbackValue(const OnboardingRefreshRequested());
  });

  late _MockRepo repo;
  late _MockOnboarding onboarding;

  setUp(() {
    repo = _MockRepo();
    onboarding = _MockOnboarding();
    when(() => onboarding.add(any())).thenReturn(null);
  });

  Future<void> open(
    WidgetTester tester,
    String path, {
    Size size = const Size(390, 844),
    Brightness brightness = Brightness.light,
    double textScale = 1,
    identity.Profile? profile,
    bool withProfile = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        profile: withProfile ? (profile ?? _profile()) : null,
        enabledFeatures: const {kFeatureProfileSnapshot},
      ),
    );
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(body: Text('settings')),
        ),
        GoRoute(
          path: '/settings/profile',
          builder: (context, state) => const EditProfileScreen(),
        ),
        GoRoute(
          path: '/settings/handle',
          builder: (context, state) => const ChangeHandleScreen(),
        ),
      ],
    );
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<IdentityRepository>.value(value: repo),
          RepositoryProvider<UnexpectedErrorReporter>.value(
            value: (error, _) {},
          ),
        ],
        child: BlocProvider<OnboardingBloc>.value(
          value: onboarding,
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
    );
    unawaited(router.push(path));
    await tester.pumpAndSettle();
  }

  AppGradientButton gradient(WidgetTester tester) =>
      tester.widget(find.byType(AppGradientButton));

  TextButton cancel(WidgetTester tester) =>
      tester.widget(find.widgetWithText(TextButton, 'Cancel'));

  void stubUpdate(Future<identity.Profile> Function() answer) {
    when(
      () => repo.updateProfile(
        idempotencyKey: any(named: 'idempotencyKey'),
        displayName: any(named: 'displayName'),
        bio: any(named: 'bio'),
      ),
    ).thenAnswer((_) => answer());
  }

  void stubCheck(bool available) {
    when(() => repo.checkHandleAvailability(any())).thenAnswer(
      (_) async =>
          identity.CheckHandleAvailabilityResponse(available: available),
    );
  }

  group('Edit profile', () {
    for (final size in const [Size(390, 844), Size(1440, 900)]) {
      for (final brightness in Brightness.values) {
        for (final textScale in const [1.0, 2.0]) {
          testWidgets(
            '${size.width.toInt()}x${size.height.toInt()} ${brightness.name} '
            'text x$textScale: no overflow, header, fields',
            (tester) async {
              await open(
                tester,
                '/settings/profile',
                size: size,
                brightness: brightness,
                textScale: textScale,
                profile: identity.Profile(
                  userId: 'me',
                  handle: 'kaif',
                  displayName: 'A long display name for the layout',
                  bio: 'A long bio ' * 12,
                ),
              );
              expect(tester.takeException(), isNull);
              expect(find.text('Edit profile'), findsOneWidget);
              expect(find.text('Cancel'), findsOneWidget);
              expect(find.text('Save'), findsOneWidget);
              expect(find.text('Display name'), findsOneWidget);
              expect(find.text('Bio'), findsOneWidget);
            },
          );
        }
      }
    }

    testWidgets('wide: header and fields stay in the main column', (
      tester,
    ) async {
      await open(tester, '/settings/profile', size: const Size(1440, 900));
      const gutter = (1440 - AppLayout.mainColumnMaxWidth) / 2;
      expect(
        tester.getTopLeft(find.text('Cancel')).dx,
        greaterThanOrEqualTo(gutter),
      );
      expect(
        tester.getTopRight(find.byType(AppGradientButton)).dx,
        lessThanOrEqualTo(1440 - gutter),
      );
      expect(
        tester.getSize(find.widgetWithText(TextField, 'Kaif')).width,
        lessThanOrEqualTo(AppLayout.mainColumnMaxWidth),
      );
    });

    testWidgets('data, unchanged: Save is disabled, Cancel leaves at once', (
      tester,
    ) async {
      await open(tester, '/settings/profile');
      expect(gradient(tester).onPressed, isNull);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('settings'), findsOneWidget);
    });

    testWidgets('a changed name enables Save; Cancel then asks to discard', (
      tester,
    ) async {
      await open(tester, '/settings/profile');
      await tester.enterText(find.widgetWithText(TextField, 'Kaif'), 'Kaif S');
      await tester.pump();
      expect(gradient(tester).onPressed, isNotNull);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(find.text('Edit profile'), findsOneWidget);
    });

    testWidgets('error text and disabled Save are unchanged: empty and '
        '51-character names, 161-character bio', (tester) async {
      await open(tester, '/settings/profile');

      await tester.enterText(find.widgetWithText(TextField, 'Kaif'), '  ');
      await tester.pump();
      expect(find.text('Your name cannot be empty.'), findsOneWidget);
      expect(gradient(tester).onPressed, isNull);

      await tester.enterText(find.byType(TextField).first, 'a' * 51);
      await tester.pump();
      expect(find.text('At most 50 characters.'), findsOneWidget);
      expect(find.text('-1'), findsOneWidget);
      expect(gradient(tester).onPressed, isNull);

      await tester.enterText(find.byType(TextField).first, 'Kaif');
      await tester.enterText(find.byType(TextField).last, 'b' * 161);
      await tester.pump();
      expect(find.text('At most 160 characters.'), findsOneWidget);
      expect(gradient(tester).onPressed, isNull);
    });

    testWidgets('saving: Save busy and announced, Cancel and fields off', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final done = Completer<identity.Profile>();
      stubUpdate(() => done.future);
      await open(tester, '/settings/profile');
      await tester.enterText(find.widgetWithText(TextField, 'Kaif'), 'Kaif S');
      await tester.pump();
      await tester.tap(find.byType(AppGradientButton));
      await tester.pump();

      expect(gradient(tester).busy, isTrue);
      expect(gradient(tester).onPressed, isNull);
      expect(cancel(tester).onPressed, isNull);
      expect(
        tester
            .widgetList<TextField>(find.byType(TextField))
            .map((f) => f.enabled),
        everyElement(isFalse),
      );
      expect(find.bySemanticsLabel('Saving'), findsOneWidget);
      expect(tester.takeException(), isNull);

      done.complete(_profile());
      await tester.pumpAndSettle();
      expect(find.text('settings'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('error: a snackbar explains and Save is back', (tester) async {
      stubUpdate(() async => throw const NetworkException('offline'));
      await open(tester, '/settings/profile');
      await tester.enterText(find.widgetWithText(TextField, 'Kaif'), 'Kaif S');
      await tester.pump();
      await tester.tap(find.byType(AppGradientButton));
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsOneWidget);
      expect(gradient(tester).onPressed, isNotNull);
      expect(gradient(tester).busy, isFalse);
      expect(cancel(tester).onPressed, isNotNull);
      expect(find.text('Kaif S'), findsOneWidget);
    });

    testWidgets('no profile: the friendly unavailable state', (tester) async {
      await open(tester, '/settings/profile', withProfile: false);
      expect(
        find.text("Your profile isn't available right now."),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('semantics: Cancel and Save are buttons, the title a header, '
        'the avatar a labelled image', (tester) async {
      final handle = tester.ensureSemantics();
      await open(tester, '/settings/profile');
      expect(
        tester.getSemantics(find.widgetWithText(TextButton, 'Cancel')),
        isSemantics(label: 'Cancel', isButton: true, isEnabled: true),
      );
      expect(
        tester.getSemantics(find.byType(AppGradientButton)),
        isSemantics(label: 'Save', isButton: true, isEnabled: false),
      );
      expect(
        tester.getSemantics(find.text('Edit profile')),
        isSemantics(label: 'Edit profile', isHeader: true),
      );
      expect(find.bySemanticsLabel('Profile photo'), findsOneWidget);
      handle.dispose();
    });
  });

  group('Change handle', () {
    for (final size in const [Size(390, 844), Size(1440, 900)]) {
      for (final brightness in Brightness.values) {
        for (final textScale in const [1.0, 2.0]) {
          testWidgets(
            '${size.width.toInt()}x${size.height.toInt()} ${brightness.name} '
            'text x$textScale: no overflow, header, field, action',
            (tester) async {
              await open(
                tester,
                '/settings/handle',
                size: size,
                brightness: brightness,
                textScale: textScale,
              );
              expect(tester.takeException(), isNull);
              expect(find.text('Cancel'), findsOneWidget);
              expect(find.text('New handle'), findsOneWidget);
              // At large text the action sits below the fold of the list.
              await tester.scrollUntilVisible(
                find.widgetWithText(AppGradientButton, 'Change handle'),
                100,
                scrollable: find.byType(Scrollable).first,
              );
              expect(
                find.widgetWithText(AppGradientButton, 'Change handle'),
                findsOneWidget,
              );
              expect(tester.takeException(), isNull);
            },
          );
        }
      }
    }

    testWidgets('wide: the screen stays in the main column', (tester) async {
      await open(tester, '/settings/handle', size: const Size(1440, 900));
      const gutter = (1440 - AppLayout.mainColumnMaxWidth) / 2;
      expect(
        tester.getTopLeft(find.text('Cancel')).dx,
        greaterThanOrEqualTo(gutter),
      );
      expect(
        tester.getSize(find.byType(AppGradientButton)).width,
        lessThanOrEqualTo(AppLayout.mainColumnMaxWidth),
      );
    });

    testWidgets('idle: the format hint and the cooldown note, action off', (
      tester,
    ) async {
      await open(tester, '/settings/handle');
      expect(find.text('Current handle: @kaif'), findsOneWidget);
      expect(find.textContaining('once every 7 days'), findsOneWidget);
      expect(find.text(kHandleFormatMessage), findsOneWidget);
      expect(gradient(tester).onPressed, isNull);
    });

    testWidgets('validation text is unchanged: too short is rejected locally '
        'with the format message and no request', (tester) async {
      await open(tester, '/settings/handle');
      await tester.enterText(find.byType(TextField), 'ab');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text(kHandleFormatMessage), findsOneWidget);
      expect(gradient(tester).onPressed, isNull);
      verifyNever(() => repo.checkHandleAvailability(any()));
    });

    testWidgets('available enables the action; taken explains and keeps it '
        'off', (tester) async {
      final handle = tester.ensureSemantics();
      stubCheck(true);
      await open(tester, '/settings/handle');
      await tester.enterText(find.byType(TextField), 'new_one');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Handle is available'), findsOneWidget);
      expect(gradient(tester).onPressed, isNotNull);

      stubCheck(false);
      await tester.enterText(find.byType(TextField), 'taken_one');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('That handle is taken.'), findsOneWidget);
      expect(find.bySemanticsLabel('Handle is not available'), findsOneWidget);
      expect(gradient(tester).onPressed, isNull);
      handle.dispose();
    });

    testWidgets('saving: the action is busy and announced, Cancel and the '
        'field are off', (tester) async {
      final handle = tester.ensureSemantics();
      stubCheck(true);
      final done = Completer<identity.Profile>();
      when(
        () => repo.changeHandle(
          idempotencyKey: any(named: 'idempotencyKey'),
          newHandle: any(named: 'newHandle'),
        ),
      ).thenAnswer((_) => done.future);
      await open(tester, '/settings/handle');
      await tester.enterText(find.byType(TextField), 'new_one');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(AppGradientButton));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Change handle'));
      // Let the confirmation close; the spinner never settles, so frames
      // are pumped by hand instead of pumpAndSettle.
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }

      expect(gradient(tester).busy, isTrue);
      expect(cancel(tester).onPressed, isNull);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      expect(find.bySemanticsLabel('Saving'), findsOneWidget);

      done.complete(
        identity.Profile(userId: 'me', handle: 'new_one', displayName: 'Kaif'),
      );
      await tester.pumpAndSettle();
      handle.dispose();
    });

    testWidgets('error: a snackbar explains and the action is back', (
      tester,
    ) async {
      stubCheck(true);
      when(
        () => repo.changeHandle(
          idempotencyKey: any(named: 'idempotencyKey'),
          newHandle: any(named: 'newHandle'),
        ),
      ).thenAnswer((_) async => throw const NetworkException('offline'));
      await open(tester, '/settings/handle');
      await tester.enterText(find.byType(TextField), 'new_one');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(AppGradientButton));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Change handle'));
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsOneWidget);
      expect(gradient(tester).busy, isFalse);
      expect(cancel(tester).onPressed, isNotNull);
    });

    testWidgets('Cancel leaves; no profile shows the unavailable state', (
      tester,
    ) async {
      await open(tester, '/settings/handle');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('settings'), findsOneWidget);

      await open(tester, '/settings/handle', withProfile: false);
      expect(
        find.text("Your profile isn't available right now."),
        findsOneWidget,
      );
    });

    testWidgets('semantics: Cancel is a button, the title a header', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await open(tester, '/settings/handle');
      expect(
        tester.getSemantics(find.widgetWithText(TextButton, 'Cancel')),
        isSemantics(label: 'Cancel', isButton: true, isEnabled: true),
      );
      expect(
        tester.getSemantics(find.text('Change handle').first),
        isSemantics(label: 'Change handle', isHeader: true),
      );
      handle.dispose();
    });
  });
}
