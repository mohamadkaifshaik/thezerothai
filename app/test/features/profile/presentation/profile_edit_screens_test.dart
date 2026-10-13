import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/profile/domain/profile_edit_feature_flag.dart';
import 'package:dzeroth/features/profile/presentation/change_handle_screen.dart';
import 'package:dzeroth/features/profile/presentation/edit_profile_screen.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

class MockIdentityRepository extends Mock implements IdentityRepository {}

class MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

identity.Profile _profile({
  String handle = 'kaif',
  String name = 'Kaif',
  String bio = 'hello there',
}) =>
    identity.Profile(userId: 'me', handle: handle, displayName: name, bio: bio);

void main() {
  setUpAll(() {
    registerFallbackValue(const OnboardingRefreshRequested());
  });

  late MockIdentityRepository repo;
  late MockOnboardingBloc onboardingBloc;

  setUp(() {
    repo = MockIdentityRepository();
    onboardingBloc = MockOnboardingBloc();
    when(() => onboardingBloc.add(any())).thenReturn(null);
    whenListen(
      onboardingBloc,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        profile: _profile(),
        enabledFeatures: const {kFeatureProfileSnapshot},
      ),
    );
  });

  /// Opens [path] on top of a settings page so a successful save can pop.
  Future<void> open(
    WidgetTester tester,
    String path, {
    ThemeData? theme,
    double textScale = 1,
  }) async {
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
        GoRoute(
          path: '/profile/:handle',
          builder: (context, state) => Scaffold(
            body: Text('profile of ${state.pathParameters['handle']}'),
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      RepositoryProvider<IdentityRepository>.value(
        value: repo,
        child: BlocProvider<OnboardingBloc>.value(
          value: onboardingBloc,
          child: MaterialApp.router(
            routerConfig: router,
            theme: theme ?? appLightTheme,
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

  group('EditProfileScreen', () {
    void stubUpdate(Future<identity.Profile> Function() answer) {
      when(
        () => repo.updateProfile(
          idempotencyKey: any(named: 'idempotencyKey'),
          displayName: any(named: 'displayName'),
          bio: any(named: 'bio'),
        ),
      ).thenAnswer((_) => answer());
    }

    FilledButton save(WidgetTester tester) =>
        tester.widget(find.widgetWithText(FilledButton, 'Save'));

    testWidgets('shows the current values with Save disabled', (tester) async {
      await open(tester, '/settings/profile');

      expect(find.text('Edit profile'), findsOneWidget);
      expect(find.text('Kaif'), findsOneWidget);
      expect(find.text('hello there'), findsOneWidget);
      expect(save(tester).onPressed, isNull);
      // Avatar is not editable until P4.
      expect(find.textContaining('photo'), findsNothing);
    });

    testWidgets('saving sends the change, updates the app profile and pops', (
      tester,
    ) async {
      final done = Completer<identity.Profile>();
      stubUpdate(() => done.future);
      await open(tester, '/settings/profile');

      await tester.enterText(find.widgetWithText(TextField, 'Kaif'), 'Kaif S');
      await tester.pump();
      expect(save(tester).onPressed, isNotNull);
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      final updated = _profile(name: 'Kaif S');
      done.complete(updated);
      await tester.pumpAndSettle();

      expect(find.text('settings'), findsOneWidget);
      verify(
        () => repo.updateProfile(
          idempotencyKey: any(named: 'idempotencyKey'),
          displayName: 'Kaif S',
          bio: null,
        ),
      ).called(1);
      verify(
        () => onboardingBloc.add(
          any(
            that: isA<OnboardingProfileUpdated>().having(
              (e) => e.profile.displayName,
              'displayName',
              'Kaif S',
            ),
          ),
        ),
      ).called(1);
    });

    testWidgets('an empty name shows an error and keeps Save off', (
      tester,
    ) async {
      await open(tester, '/settings/profile');

      await tester.enterText(find.widgetWithText(TextField, 'Kaif'), '  ');
      await tester.pump();

      expect(find.text('Your name cannot be empty.'), findsOneWidget);
      expect(save(tester).onPressed, isNull);
    });

    testWidgets('51 characters: counter goes negative, Save disabled', (
      tester,
    ) async {
      await open(tester, '/settings/profile');

      await tester.enterText(find.widgetWithText(TextField, 'Kaif'), 'a' * 51);
      await tester.pump();

      expect(find.text('-1'), findsOneWidget);
      expect(find.text('At most 50 characters.'), findsOneWidget);
      expect(save(tester).onPressed, isNull);
    });

    testWidgets('the daily name-change quota shows a friendly message', (
      tester,
    ) async {
      stubUpdate(
        () async => throw const QuotaExceededException(
          'quota',
          quota: 'snapshot_edits',
        ),
      );
      await open(tester, '/settings/profile');

      await tester.enterText(find.widgetWithText(TextField, 'Kaif'), 'Kaif S');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          "You've changed your name too many times today. Try again tomorrow.",
        ),
        findsOneWidget,
      );
      // Still editable, text kept.
      expect(find.text('Kaif S'), findsOneWidget);
      expect(save(tester).onPressed, isNotNull);
    });

    testWidgets('FEATURE_DISABLED degrades: friendly text and a flag refresh', (
      tester,
    ) async {
      stubUpdate(() async => throw const FeatureDisabledException('off'));
      await open(tester, '/settings/profile');

      await tester.enterText(find.widgetWithText(TextField, 'Kaif'), 'Kaif S');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(
        find.text("Editing your profile isn't available right now."),
        findsOneWidget,
      );
      verify(() => onboardingBloc.add(const OnboardingRefreshRequested()))
          .called(1);
    });

    testWidgets('leaving with unsaved edits asks to discard', (tester) async {
      await open(tester, '/settings/profile');
      await tester.enterText(find.widgetWithText(TextField, 'Kaif'), 'Kaif S');
      await tester.pump();

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsOneWidget);

      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(find.text('Edit profile'), findsOneWidget);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(find.text('settings'), findsOneWidget);
    });

    testWidgets('dark mode, text scale 2.0, narrow: no overflow', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await open(
        tester,
        '/settings/profile',
        theme: appDarkTheme,
        textScale: 2,
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Edit profile'), findsOneWidget);
    });
  });

  group('ChangeHandleScreen', () {
    void stubCheck(bool available, {String reason = ''}) {
      when(() => repo.checkHandleAvailability(any())).thenAnswer(
        (_) async => identity.CheckHandleAvailabilityResponse(
          available: available,
          reason: reason,
        ),
      );
    }

    FilledButton change(WidgetTester tester) =>
        tester.widget(find.widgetWithText(FilledButton, 'Change handle').first);

    Future<void> type(WidgetTester tester, String value) async {
      await tester.enterText(find.byType(TextField), value);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
    }

    testWidgets('shows the current handle and the cooldown notice', (
      tester,
    ) async {
      await open(tester, '/settings/handle');

      expect(find.text('Current handle: @kaif'), findsOneWidget);
      expect(find.textContaining('once every 7 days'), findsOneWidget);
      expect(change(tester).onPressed, isNull);
    });

    testWidgets('checks availability, confirms, saves and lands on the new '
        'profile', (tester) async {
      stubCheck(true);
      when(
        () => repo.changeHandle(
          idempotencyKey: any(named: 'idempotencyKey'),
          newHandle: any(named: 'newHandle'),
        ),
      ).thenAnswer((_) async => _profile(handle: 'new_one'));
      await open(tester, '/settings/handle');

      await type(tester, 'New_One');
      expect(find.bySemanticsLabel('Handle is available'), findsOneWidget);
      expect(change(tester).onPressed, isNotNull);

      await tester.tap(find.widgetWithText(FilledButton, 'Change handle'));
      await tester.pumpAndSettle();
      expect(find.text('Change your handle to @new_one?'), findsOneWidget);
      expect(
        find.textContaining("won't be able to change it again"),
        findsOneWidget,
      );

      await tester.tap(find.widgetWithText(FilledButton, 'Change handle').last);
      await tester.pumpAndSettle();

      verify(
        () => repo.changeHandle(
          idempotencyKey: any(named: 'idempotencyKey'),
          newHandle: 'new_one',
        ),
      ).called(1);
      expect(find.text('profile of new_one'), findsOneWidget);
      verify(
        () => onboardingBloc.add(any(that: isA<OnboardingProfileUpdated>())),
      ).called(1);
    });

    testWidgets('cancelling the confirmation sends nothing', (tester) async {
      stubCheck(true);
      await open(tester, '/settings/handle');
      await type(tester, 'new_one');

      await tester.tap(find.widgetWithText(FilledButton, 'Change handle'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      verifyNever(
        () => repo.changeHandle(
          idempotencyKey: any(named: 'idempotencyKey'),
          newHandle: any(named: 'newHandle'),
        ),
      );
    });

    testWidgets('a taken handle is explained and cannot be saved', (
      tester,
    ) async {
      stubCheck(false);
      await open(tester, '/settings/handle');

      await type(tester, 'taken_one');

      expect(find.text('That handle is taken.'), findsOneWidget);
      expect(change(tester).onPressed, isNull);
    });

    testWidgets('too short is rejected locally, with no request', (
      tester,
    ) async {
      await open(tester, '/settings/handle');

      await type(tester, 'ab');

      expect(
        find.text('3-15 characters: lowercase letters, numbers, underscore.'),
        findsOneWidget,
      );
      verifyNever(() => repo.checkHandleAvailability(any()));
    });

    testWidgets('the 7-day cooldown reports how long is left', (tester) async {
      stubCheck(true);
      when(
        () => repo.changeHandle(
          idempotencyKey: any(named: 'idempotencyKey'),
          newHandle: any(named: 'newHandle'),
        ),
      ).thenAnswer(
        (_) async => throw const LimitReachedException(
          'cooldown',
          quota: 'handle_change',
          retryAfter: Duration(days: 4, hours: 3),
        ),
      );
      await open(tester, '/settings/handle');
      await type(tester, 'new_one');

      await tester.tap(find.widgetWithText(FilledButton, 'Change handle'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Change handle').last);
      await tester.pumpAndSettle();

      expect(
        find.text(
          'You changed your handle recently. You can change it again in '
          '5 days.',
        ),
        findsOneWidget,
      );
      expect(find.text('Current handle: @kaif'), findsOneWidget);
    });

    testWidgets('FEATURE_DISABLED degrades: friendly text and a flag refresh', (
      tester,
    ) async {
      stubCheck(true);
      when(
        () => repo.changeHandle(
          idempotencyKey: any(named: 'idempotencyKey'),
          newHandle: any(named: 'newHandle'),
        ),
      ).thenAnswer((_) async => throw const FeatureDisabledException('off'));
      await open(tester, '/settings/handle');
      await type(tester, 'new_one');

      await tester.tap(find.widgetWithText(FilledButton, 'Change handle'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Change handle').last);
      await tester.pumpAndSettle();

      expect(
        find.text("Changing your handle isn't available right now."),
        findsOneWidget,
      );
      verify(() => onboardingBloc.add(const OnboardingRefreshRequested()))
          .called(1);
    });

    testWidgets('dark mode, text scale 2.0, narrow: no overflow', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await open(tester, '/settings/handle', theme: appDarkTheme, textScale: 2);

      expect(tester.takeException(), isNull);
      expect(find.text('Change handle'), findsWidgets);
    });
  });
}
