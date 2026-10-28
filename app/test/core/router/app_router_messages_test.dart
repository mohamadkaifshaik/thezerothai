import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/theme_mode_cubit.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/messages/data/messaging_repository.dart';
import 'package:dzeroth/features/messages/data/messaging_store.dart';
import 'package:dzeroth/features/messages/presentation/conversations_screen.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/unread_badge_cubit.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/messaging_fixtures.dart';

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockMessagingRepository extends Mock implements MessagingRepository {}

class _NoThemeStore implements ThemeModeStore {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) async {}
}

/// `/messages` and `/messages/requests` on the real router (W7-14): behind the
/// `messaging` flag, redirecting Home without it.
void main() {
  const user = AppUser(
    uid: 'uid-1',
    email: 'a@example.com',
    emailVerified: true,
    isPasswordProvider: true,
  );

  setUpAll(() {
    registerFallbackValue(Folder.FOLDER_INBOX);
  });

  Future<(String, _MockMessagingRepository)> openAt(
    WidgetTester tester,
    Set<String> flags, {
    String location = AppRouter.messagesPath,
  }) async {
    final repo = _MockMessagingRepository();
    when(() => repo.rateLimitedFor()).thenReturn(null);
    when(() => repo.cachedConversations(any())).thenAnswer(
      (_) async => ConversationsSnapshot(
        conversations: [conv('a', snippet: 'hello from a')],
      ),
    );
    when(() => repo.refreshConversations(any())).thenAnswer(
      (_) async => ConversationsResult(
        ConversationsSnapshot(
          conversations: [conv('a', snippet: 'hello from a')],
        ),
        requestCount: 2,
      ),
    );
    final auth = _MockAuthBloc();
    final onboarding = _MockOnboardingBloc();
    final badge = UnreadBadgeCubit();
    addTearDown(badge.close);
    whenListen(
      auth,
      const Stream<AuthState>.empty(),
      initialState: const AuthState(
        status: AuthStatus.authenticated,
        user: user,
      ),
    );
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        profile: identity.Profile(userId: 'uid-1', handle: 'me'),
        enabledFeatures: flags,
      ),
    );
    final appRouter = AppRouter(authBloc: auth, onboardingBloc: onboarding);
    appRouter.router.go(location);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<MessagingRepository>.value(value: repo),
          RepositoryProvider<UnexpectedErrorReporter>.value(value: (_, _) {}),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<AuthBloc>.value(value: auth),
            BlocProvider<OnboardingBloc>.value(value: onboarding),
            BlocProvider<UnreadBadgeCubit>.value(value: badge),
            BlocProvider<ThemeModeCubit>(
              create: (_) => ThemeModeCubit(_NoThemeStore()),
            ),
          ],
          child: MaterialApp.router(routerConfig: appRouter.router),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (appRouter.router.routeInformationProvider.value.uri.path, repo);
  }

  test('the paths', () {
    expect(AppRouter.messagesPath, '/messages');
    expect(AppRouter.messageRequestsPath, '/messages/requests');
  });

  testWidgets('with messaging off the inbox redirects Home, with no RPC', (
    tester,
  ) async {
    final (path, repo) = await openAt(tester, const {'notifications'});

    expect(path, AppRouter.homePath);
    expect(find.byType(ConversationsScreen), findsNothing);
    verifyNever(() => repo.cachedConversations(any()));
    verifyNever(() => repo.refreshConversations(any()));
  });

  testWidgets('with messaging off the requests folder redirects Home', (
    tester,
  ) async {
    final (path, repo) = await openAt(
      tester,
      const {},
      location: AppRouter.messageRequestsPath,
    );

    expect(path, AppRouter.homePath);
    expect(find.byType(ConversationsScreen), findsNothing);
    verifyNever(() => repo.refreshConversations(any()));
  });

  testWidgets('with messaging on the inbox opens and lists conversations', (
    tester,
  ) async {
    final (path, repo) = await openAt(tester, const {'messaging'});

    expect(path, AppRouter.messagesPath);
    expect(find.byType(ConversationsScreen), findsOneWidget);
    expect(find.text('Messages'), findsOneWidget);
    expect(find.text('hello from a'), findsOneWidget);
    expect(find.text('Message requests (2)'), findsOneWidget);
    verify(() => repo.refreshConversations(Folder.FOLDER_INBOX)).called(1);
  });

  testWidgets('the requests row opens /messages/requests in REQUESTS mode', (
    tester,
  ) async {
    final (_, repo) = await openAt(tester, const {'messaging'});

    await tester.tap(find.text('Message requests (2)'));
    await tester.pumpAndSettle();

    expect(find.text('Message requests'), findsOneWidget);
    verify(() => repo.refreshConversations(Folder.FOLDER_REQUESTS)).called(1);
  });

  testWidgets('a deep link to the requests folder opens it with the flag on', (
    tester,
  ) async {
    final (path, _) = await openAt(tester, const {
      'messaging',
    }, location: AppRouter.messageRequestsPath);

    expect(path, AppRouter.messageRequestsPath);
    expect(find.byTooltip('Back'), findsOneWidget);
  });
}
