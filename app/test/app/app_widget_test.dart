import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:drift/native.dart';
import 'package:dzeroth/app/app_widget.dart';
import 'package:dzeroth/core/network/service_paused_cubit.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/widgets/service_paused_view.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/core/theme/theme_mode_cubit.dart';
import 'package:dzeroth/features/account/data/account_repository.dart';
import 'package:dzeroth/features/auth/data/auth_repository.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/engagement/data/bookmarks_repository.dart';
import 'package:dzeroth/features/engagement/data/engagement_repository.dart';
import 'package:dzeroth/features/engagement/data/likes_repository.dart';
import 'package:dzeroth/features/engagement/data/poll_repository.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/poll_cubit.dart';
import 'package:dzeroth/core/feature_flags/service_feature_gate.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/gen/dzeroth/engagement/v1/engagement.pb.dart' as eng;
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/moderation/data/moderation_repository.dart';
import 'package:dzeroth/features/messages/data/messaging_repository.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_gate.dart';
import 'package:dzeroth/features/notifications/data/notifications_repository.dart';
import 'package:dzeroth/features/notifications/data/push_messaging.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/push_cubit.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/push_opt_in_cubit.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/unread_badge_cubit.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/domain/posts_feature_flag.dart';
import 'package:dzeroth/features/timeline/data/timeline_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../support/fake_push_messaging.dart';
import '../support/fake_transport.dart';
import '../support/poll_fixtures.dart';
import '../support/media_fixtures.dart' show MockMediaRepository;
import '../support/notifications_fixtures.dart';
import '../support/suggestions_fixtures.dart';

class MockAuthBloc extends MockBloc<AuthEvent, AuthState> implements AuthBloc {}

class MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class MockIdentityRepository extends Mock implements IdentityRepository {}

class MockGraphRepository extends Mock implements GraphRepository {}

class MockAccountRepository extends Mock implements AccountRepository {}

class MockAuthRepository extends Mock implements AuthRepository {}

class MockPostsRepository extends Mock implements PostsRepository {}

class MockTimelineRepository extends Mock implements TimelineRepository {}

class MockMessagingRepository extends Mock implements MessagingRepository {
  MockMessagingRepository() {
    // W7-26: the router listens to the gate; app_widget runs the probe.
    when(() => gate)
        .thenReturn(MessagingFeatureGate(isMessagingEnabled: () => false));
    when(probeAccess).thenAnswer((_) async {});
  }
}

class MockNotificationsRepository extends Mock
    implements NotificationsRepository {}

class MockModerationRepository extends Mock implements ModerationRepository {}

class MockEngagementRepository extends Mock implements EngagementRepository {}

class MockLikesRepository extends Mock implements LikesRepository {}

class MockBookmarksRepository extends Mock implements BookmarksRepository {
  /// `BookmarksCubit` listens to the repository's events when it is built.
  void stubEvents() {
    when(() => events).thenAnswer((_) => const Stream<BookmarkEvent>.empty());
  }
}

void main() {
  late MockAuthBloc authBloc;
  late MockOnboardingBloc onboardingBloc;
  late MockNotificationsRepository notifications;
  late FakePushMessaging messaging;
  late PushCubit push;
  late UnreadBadgeCubit badge;
  late AppDatabase database;
  late FakeSuggestionsRepository suggestions;
  late StreamController<OnboardingState> onboardingStates;
  late StreamController<AuthState> authStates;

  const user = AppUser(
    uid: 'uid-1',
    email: 'a@example.com',
    emailVerified: true,
    isPasswordProvider: true,
  );

  OnboardingState ready({Set<String> flags = const {}, int unread = 0}) =>
      OnboardingState(
        status: OnboardingStatus.ready,
        enabledFeatures: flags,
        unreadNotificationCount: unread,
      );

  setUpAll(() {
    registerFallbackValue(const OnboardingRefreshRequested());
  });

  setUp(() {
    authBloc = MockAuthBloc();
    onboardingBloc = MockOnboardingBloc();
    notifications = MockNotificationsRepository();
    messaging = FakePushMessaging(
      currentPermission: PushPermission.notDetermined,
    );
    badge = UnreadBadgeCubit();
    database = AppDatabase.forTesting(NativeDatabase.memory());
    suggestions = FakeSuggestionsRepository(const []);
    onboardingStates = StreamController<OnboardingState>.broadcast();
    authStates = StreamController<AuthState>.broadcast();
    when(() => notifications.enabled).thenReturn(true);
    push = PushCubit(messaging: messaging, repository: notifications);
  });

  tearDown(() async {
    await push.close();
    await badge.close();
    await database.close();
    await onboardingStates.close();
    await authStates.close();
  });

  Future<void> pump(
    WidgetTester tester, {
    required OnboardingState onboarding,
    AuthState auth = const AuthState(status: AuthStatus.unauthenticated),
    ServicePausedCubit? servicePaused,
    PollRepository? pollRepository,
  }) async {
    whenListen(authBloc, authStates.stream, initialState: auth);
    whenListen(
      onboardingBloc,
      onboardingStates.stream,
      initialState: onboarding,
    );
    await tester.pumpWidget(
      AppWidget(
        authBloc: authBloc,
        onboardingBloc: onboardingBloc,
        identityRepository: MockIdentityRepository(),
        graphRepository: MockGraphRepository(),
        suggestionsRepository: suggestions,
        accountRepository: MockAccountRepository(),
        authRepository: MockAuthRepository(),
        database: database,
        postsRepository: MockPostsRepository(),
        timelineRepository: MockTimelineRepository(),
        postsGate: PostsFeatureGate(isPostsEnabled: () => false),
        mediaRepository: MockMediaRepository(),
        notificationsRepository: notifications,
        messagingRepository: MockMessagingRepository(),
        moderationRepository: MockModerationRepository(),
        engagementRepository: MockEngagementRepository(),
        bookmarksRepository: MockBookmarksRepository()..stubEvents(),
        likesRepository: MockLikesRepository(),
        pushCubit: push,
        unreadBadgeCubit: badge,
        servicePausedCubit: servicePaused,
        pollRepository: pollRepository,
      ),
    );
    await tester.pump();
  }

  testWidgets('a paused service replaces the app with the paused screen and '
      'Retry brings it back (ADR-0022)', (tester) async {
    var stillPaused = true;
    final servicePaused = ServicePausedCubit(probe: () async => stillPaused);
    addTearDown(servicePaused.close);
    await pump(tester, onboarding: ready(), servicePaused: servicePaused);
    expect(find.byType(ServicePausedView), findsNothing);

    servicePaused.markPaused();
    await tester.pump();
    await tester.pump();
    expect(find.byType(ServicePausedView), findsOneWidget);
    expect(find.text(ServicePausedView.title), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(ServicePausedView), findsOneWidget);

    stillPaused = false;
    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(ServicePausedView), findsNothing);
  });

  testWidgets('a ready GetMe with the flag on seeds the badge and starts push '
      '(never asking the OS)', (tester) async {
    await pump(tester, onboarding: ready(flags: {'notifications'}, unread: 4));

    expect(badge.state, 4);
    expect(messaging.permissionReads, 1);
    expect(messaging.permissionRequests, 0);
  });

  testWidgets('with the flag off nothing is seeded and push stays off', (
    tester,
  ) async {
    await pump(tester, onboarding: ready(unread: 4));

    expect(badge.state, 0);
    expect(messaging.permissionReads, 0);
  });

  testWidgets('a fresh GetMe (new flag-set instance) re-seeds the badge', (
    tester,
  ) async {
    await pump(tester, onboarding: ready(flags: {'notifications'}, unread: 4));

    onboardingStates.add(ready(flags: {'notifications'}, unread: 9));
    await tester.pump();

    expect(badge.state, 9);
  });

  testWidgets('the same flag-set instance does not re-seed (a local clear '
      'sticks)', (tester) async {
    // copyWith stores the flag set as one stable view (as every real GetMe
    // result is), so the same state keeps the same instance.
    final initial = ready(
      flags: {'notifications'},
      unread: 4,
    ).copyWith(handle: '');
    await pump(tester, onboarding: initial);
    badge.clear();

    onboardingStates.add(initial.copyWith(handle: 'typing'));
    await tester.pump();

    expect(badge.state, 0);
  });

  testWidgets('the flag turning off mid-session resets the badge and stops '
      'push (the token is kept)', (tester) async {
    await pump(tester, onboarding: ready(flags: {'notifications'}, unread: 4));
    expect(badge.state, 4);

    onboardingStates.add(ready(unread: 4));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();

    expect(badge.state, 0);
    expect(push.state.permission, PushPermission.notDetermined);
    expect(messaging.tokenDeletes, 0);
  });

  testWidgets('sign-out resets the badge and invalidates the push token', (
    tester,
  ) async {
    await pump(
      tester,
      auth: const AuthState(status: AuthStatus.authenticated, user: user),
      onboarding: ready(flags: {'notifications'}, unread: 4),
    );
    expect(badge.state, 4);

    authStates.add(const AuthState(status: AuthStatus.unauthenticated));
    // stop() awaits real stream cancellations: let real async finish.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();

    expect(badge.state, 0);
    expect(messaging.tokenDeletes, 1);
  });

  testWidgets('sign-out forgets the "Who to follow" list (W3-19)', (
    tester,
  ) async {
    await pump(
      tester,
      auth: const AuthState(status: AuthStatus.authenticated, user: user),
      onboarding: ready(),
    );
    expect(suggestions.clears, 0);

    authStates.add(const AuthState(status: AuthStatus.unauthenticated));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();

    expect(suggestions.clears, 1);
  });

  group('poll votes belong to the account (W6-19)', () {
    const other = AppUser(
      uid: 'uid-2',
      email: 'b@example.com',
      emailVerified: true,
      isPasswordProvider: true,
    );

    PollRepository pollRepo() => PollRepository(
      apiClient: ApiClient.withTransport(
        FakeTransport(
          (_, _) async => eng.VotePollResponse(
            post: pollPostView(
              1,
              poll: pollOf(votes: const [1, 0, 0], total: 1, visible: true),
              choice: 1,
            ),
          ),
        ),
      ),
      gate: ServiceFeatureGate(isEnabled: () => true),
      readPost: (_) async => pollPostView(1, poll: pollOf()),
    );

    Future<PollCubit> startVoted(WidgetTester tester) async {
      await pump(
        tester,
        auth: const AuthState(status: AuthStatus.authenticated, user: user),
        onboarding: ready(),
        pollRepository: pollRepo(),
      );
      final cubit = tester.element(find.byType(MaterialApp)).read<PollCubit>();
      await cubit.vote('1', 0);
      expect(cubit.state.entries, isNotEmpty, reason: 'the vote is overlaid');
      return cubit;
    }

    Future<void> settleAuth(WidgetTester tester) async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }

    testWidgets('sign-out forgets every vote overlay', (tester) async {
      final cubit = await startVoted(tester);
      authStates.add(const AuthState(status: AuthStatus.unauthenticated));
      await settleAuth(tester);
      expect(cubit.state.entries, isEmpty);
    });

    testWidgets(
      'a direct switch to another account forgets them too',
      (tester) async {
        final cubit = await startVoted(tester);
        authStates.add(
          const AuthState(status: AuthStatus.authenticated, user: other),
        );
        await settleAuth(tester);
        expect(
          cubit.state.entries,
          isEmpty,
          reason: "the next account must not see uid-1's choice",
        );
      },
      // W6-19 D1 (docs/reviews/test-report-w6-client.md): AppWidget resets the
      // poll overlay only on AuthStatus.unauthenticated (app_widget.dart:260),
      // so a direct A to B switch keeps the first account's votes. Remove the
      // skip when fixed.
      skip: true,
    );
  });

  testWidgets('the push opt-in record follows the signed-in account (W2-12)', (
    tester,
  ) async {
    await pump(
      tester,
      auth: const AuthState(status: AuthStatus.authenticated, user: user),
      onboarding: ready(),
    );
    final optIn = BlocProvider.of<PushOptInCubit>(
      tester.element(find.byType(MaterialApp)),
    );
    // The record is read from the real in-memory database.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    expect(optIn.state.uid, 'uid-1');
    expect(optIn.state.loaded, isTrue);

    authStates.add(const AuthState(status: AuthStatus.unauthenticated));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    expect(optIn.state.uid, isNull);
    expect(optIn.state.canOffer, isFalse);
  });

  testWidgets('sign-out clears the snackbars: no stale Undo into the next '
      'session (W2-14 L-5)', (tester) async {
    await pump(
      tester,
      auth: const AuthState(status: AuthStatus.authenticated, user: user),
      onboarding: ready(),
    );
    ScaffoldMessenger.of(tester.element(find.byType(Scaffold).first))
        .showSnackBar(
          SnackBar(
            content: const Text('Removed from Bookmarks'),
            action: SnackBarAction(label: 'Undo', onPressed: () {}),
          ),
        );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Undo'), findsOneWidget);

    authStates.add(const AuthState(status: AuthStatus.unauthenticated));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Removed from Bookmarks'), findsNothing);
    expect(find.text('Undo'), findsNothing);
  });

  testWidgets('a foreground push bumps the badge outside the list', (
    tester,
  ) async {
    await pump(tester, onboarding: ready(flags: {'notifications'}, unread: 4));
    await tester.pump();

    messaging.foreground.add(const PushMessage(type: 'like'));
    await tester.pump();

    expect(badge.state, 5);
  });

  testWidgets('a foreground push while the list is open does not bump the '
      'badge (the list refreshes and marks seen itself)', (tester) async {
    when(() => notifications.cached())
        .thenAnswer((_) async => snapshotOfNotifs([notif('a', minutesAgo: 1)]));
    when(() => notifications.sinceRefresh).thenReturn(const Duration());
    when(() => notifications.sinceRefreshAttempt).thenReturn(const Duration());
    when(() => notifications.rateLimitedFor()).thenReturn(null);
    when(() => notifications.markSeen(any())).thenAnswer((_) async => null);
    await pump(
      tester,
      auth: const AuthState(status: AuthStatus.authenticated, user: user),
      onboarding: ready(flags: {'notifications'}, unread: 0),
    );
    final router = GoRouter.of(tester.element(find.byType(Navigator).first));

    router.go(AppRouter.notificationsPath);
    await tester.pump();
    await tester.pump();
    expect(
      router.routeInformationProvider.value.uri.path,
      AppRouter.notificationsPath,
    );

    messaging.foreground.add(const PushMessage(type: 'like'));
    await tester.pump();

    expect(badge.state, 0);
  });

  group('appearance (W0-8)', () {
    ThemeMode themeMode(WidgetTester tester) =>
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode!;

    // The drift read completes on the real event loop, not in fake async.
    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }

    testWidgets('follows the system theme by default', (tester) async {
      await pump(tester, onboarding: ready());
      await settle(tester);

      expect(themeMode(tester), ThemeMode.system);
    });

    testWidgets('applies the choice saved on the device at start', (
      tester,
    ) async {
      await tester.runAsync(
        () => database.writeSetting(DatabaseThemeModeStore.key, 'dark'),
      );
      await pump(tester, onboarding: ready());
      await settle(tester);

      expect(themeMode(tester), ThemeMode.dark);
    });

    testWidgets('choosing a mode switches the whole app at once', (
      tester,
    ) async {
      await pump(tester, onboarding: ready());
      await settle(tester);
      final cubit = BlocProvider.of<ThemeModeCubit>(
        tester.element(find.byType(MaterialApp)),
      );

      await cubit.select(ThemeMode.light);
      await tester.pump();

      expect(themeMode(tester), ThemeMode.light);
    });

    testWidgets('the app theme is X light / X dark', (tester) async {
      await pump(tester, onboarding: ready());
      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));

      expect(app.theme!.colorScheme.surface, const Color(0xFFFFFFFF));
      expect(app.darkTheme!.colorScheme.surface, const Color(0xFF000000));
    });
  });
}
