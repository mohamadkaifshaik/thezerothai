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
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/network/rate_limit_hold.dart';
import 'package:dzeroth/features/messages/presentation/conversations_screen.dart';
import 'package:dzeroth/features/messages/presentation/thread_screen.dart';
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
import '../../support/thread_test_support.dart';

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

/// `/messages`, `/messages/requests` (W7-14) and `/messages/:id` (W7-15) on the
/// real router: behind the `messaging` flag, redirecting Home without it.
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
    bool threadNotFound = false,
  }) async {
    final repo = _MockMessagingRepository();
    when(() => repo.rateLimitedFor()).thenReturn(null);
    when(() => repo.cachedConversations(any())).thenAnswer(
      (_) async => ConversationsSnapshot(
        conversations: [conv(kThreadId, snippet: 'hello from a')],
      ),
    );
    when(() => repo.refreshConversations(any())).thenAnswer(
      (_) async => ConversationsResult(
        ConversationsSnapshot(
          conversations: [conv(kThreadId, snippet: 'hello from a')],
        ),
        requestCount: 2,
      ),
    );
    when(() => repo.rateLimitHold).thenReturn(RateLimitHold());
    when(() => repo.cachedThread(any())).thenAnswer(
      (_) async =>
          ThreadSnapshot(messages: msgs(1, 2), conversation: threadConv()),
    );
    when(() => repo.refreshThread(any())).thenAnswer(
      (_) async =>
          ThreadSnapshot(messages: msgs(1, 2), conversation: threadConv()),
    );
    if (threadNotFound) {
      when(() => repo.cachedThread(any()))
          .thenAnswer((_) async => const ThreadSnapshot());
      when(() => repo.refreshThread(any()))
          .thenThrow(const NotFoundException('nope'));
    }
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
    expect(AppRouter.messagePath(kThreadId), '/messages/$kThreadId');
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

  group('/messages/:id (W7-15)', () {
    testWidgets('with messaging off a thread link redirects Home, no RPC', (
      tester,
    ) async {
      final (path, repo) = await openAt(tester, const {
        'notifications',
      }, location: AppRouter.messagePath(kThreadId));

      expect(path, AppRouter.homePath);
      expect(find.byType(ThreadScreen), findsNothing);
      verifyNever(() => repo.cachedThread(any()));
      verifyNever(() => repo.refreshThread(any()));
    });

    testWidgets('with messaging on a deep link opens the conversation', (
      tester,
    ) async {
      final (path, repo) = await openAt(tester, const {
        'messaging',
      }, location: AppRouter.messagePath(kThreadId));

      expect(path, AppRouter.messagePath(kThreadId));
      expect(find.byType(ThreadScreen), findsOneWidget);
      expect(find.text('Sam Rivera'), findsOneWidget);
      verify(() => repo.refreshThread(kThreadId)).called(1);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a malformed id shows "isn\'t available" and sends nothing', (
      tester,
    ) async {
      final (_, repo) = await openAt(tester, const {
        'messaging',
      }, location: '/messages/not-a-conversation');

      expect(find.byType(ThreadScreen), findsOneWidget);
      expect(find.text("This conversation isn't available"), findsOneWidget);
      verifyNever(() => repo.refreshThread(any()));
    });

    testWidgets('NOT_FOUND (a conversation you are not in) shows "isn\'t '
        'available"', (tester) async {
      final (_, repo) = await openAt(
        tester,
        const {'messaging'},
        location: AppRouter.messagePath(hexId(0xbeef)),
        threadNotFound: true,
      );

      expect(find.text("This conversation isn't available"), findsOneWidget);
      verify(() => repo.refreshThread(hexId(0xbeef))).called(1);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('/messages/requests is still the Requests folder', (
      tester,
    ) async {
      final (path, _) = await openAt(tester, const {
        'messaging',
      }, location: AppRouter.messageRequestsPath);

      expect(path, AppRouter.messageRequestsPath);
      expect(find.byType(ThreadScreen), findsNothing);
      expect(find.byType(ConversationsScreen), findsOneWidget);
    });

    testWidgets('a row in the inbox opens its conversation', (tester) async {
      final (_, repo) = await openAt(tester, const {'messaging'});

      await tester.tap(find.text('hello from a'));
      await tester.pumpAndSettle();

      expect(find.byType(ThreadScreen), findsOneWidget);
      verify(() => repo.refreshThread(kThreadId)).called(1);

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.byType(ConversationsScreen), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
