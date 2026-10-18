import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:drift/native.dart';
import 'package:dzeroth/app/app_widget.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/account/data/account_repository.dart';
import 'package:dzeroth/features/auth/data/auth_repository.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/moderation/data/moderation_repository.dart';
import 'package:dzeroth/features/notifications/data/notifications_repository.dart';
import 'package:dzeroth/features/notifications/data/push_messaging.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/push_cubit.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/unread_badge_cubit.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/domain/posts_feature_flag.dart';
import 'package:dzeroth/features/timeline/data/timeline_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../support/fake_push_messaging.dart';
import '../support/media_fixtures.dart' show MockMediaRepository;
import '../support/notifications_fixtures.dart';

class MockAuthBloc extends MockBloc<AuthEvent, AuthState> implements AuthBloc {}

class MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class MockIdentityRepository extends Mock implements IdentityRepository {}

class MockGraphRepository extends Mock implements GraphRepository {}

class MockAccountRepository extends Mock implements AccountRepository {}

class MockAuthRepository extends Mock implements AuthRepository {}

class MockPostsRepository extends Mock implements PostsRepository {}

class MockTimelineRepository extends Mock implements TimelineRepository {}

class MockNotificationsRepository extends Mock
    implements NotificationsRepository {}

class MockModerationRepository extends Mock implements ModerationRepository {}

void main() {
  late MockAuthBloc authBloc;
  late MockOnboardingBloc onboardingBloc;
  late MockNotificationsRepository notifications;
  late FakePushMessaging messaging;
  late PushCubit push;
  late UnreadBadgeCubit badge;
  late AppDatabase database;
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
        accountRepository: MockAccountRepository(),
        authRepository: MockAuthRepository(),
        database: database,
        postsRepository: MockPostsRepository(),
        timelineRepository: MockTimelineRepository(),
        postsGate: PostsFeatureGate(isPostsEnabled: () => false),
        mediaRepository: MockMediaRepository(),
        notificationsRepository: notifications,
        moderationRepository: MockModerationRepository(),
        pushCubit: push,
        unreadBadgeCubit: badge,
      ),
    );
    await tester.pump();
  }

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
}
