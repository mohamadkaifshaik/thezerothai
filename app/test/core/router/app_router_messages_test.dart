import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/router/main_shell.dart';
import 'package:dzeroth/core/theme/theme_mode_cubit.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/messages/data/messaging_repository.dart';
import 'package:dzeroth/features/messages/presentation/draft_thread_screen.dart';
import 'package:dzeroth/features/messages/presentation/recipient_picker_screen.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/features/messages/data/messaging_store.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/network/rate_limit_hold.dart';
import 'package:dzeroth/features/messages/presentation/conversations_screen.dart';
import 'package:dzeroth/features/messages/presentation/report_conversation.dart';
import 'package:dzeroth/features/messages/presentation/thread_screen.dart';
import 'package:dzeroth/features/messages/presentation/widgets/message_composer.dart';
import 'package:dzeroth/features/messages/presentation/widgets/request_banner.dart';
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
import '../../support/messaging_shell_rig.dart';
import '../../support/thread_test_support.dart';

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockMessagingRepository extends Mock implements MessagingRepository {}

class _MockGraphRepository extends Mock implements GraphRepository {}

class _MockIdentityRepository extends Mock implements IdentityRepository {}

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

  late _MockGraphRepository graphRepo;
  late MessagingShellRig rig;

  setUp(() {
    rig = MessagingShellRig();
    graphRepo = _MockGraphRepository();
    when(
      () => graphRepo.listFollowing(
        userId: any(named: 'userId'),
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer(
      (_) async => GraphPage(
        items: [
          graph.UserListItem(
            user: common.AuthorSnapshot(
              userId: 'u-ada',
              handle: 'ada',
              displayName: 'Ada Lovelace',
            ),
          ),
          graph.UserListItem(
            user: common.AuthorSnapshot(
              userId: 'u-sam',
              handle: 'sam',
              displayName: 'Sam Rivera',
            ),
          ),
        ],
        nextPageToken: '',
      ),
    );
  });

  Future<(String, _MockMessagingRepository)> openAt(
    WidgetTester tester,
    Set<String> flags, {
    String location = AppRouter.messagesPath,
    bool threadNotFound = false,
    ConversationState headerState =
        ConversationState.CONVERSATION_STATE_ACCEPTED,
    Folder headerFolder = Folder.FOLDER_INBOX,
  }) async {
    final header = threadConv(state: headerState).deepCopy()
      ..folder = headerFolder;
    final repo = _MockMessagingRepository();
    when(() => repo.rateLimitedFor()).thenReturn(null);
    when(() => repo.conversationsChanged)
        .thenAnswer((_) => const Stream<void>.empty());
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
    // The cache holds a conversation with Sam only (the thread fixture's peer).
    when(() => repo.cachedConversationWith(any())).thenAnswer(
      (invocation) async =>
          invocation.positionalArguments.first == 'u-sam' ? threadConv() : null,
    );
    when(() => repo.cachedThread(any())).thenAnswer(
      (_) async => ThreadSnapshot(messages: msgs(1, 2), conversation: header),
    );
    when(() => repo.refreshThread(any())).thenAnswer(
      (_) async => ThreadSnapshot(messages: msgs(1, 2), conversation: header),
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
          RepositoryProvider<GraphRepository>.value(value: graphRepo),
          RepositoryProvider<IdentityRepository>.value(
            value: _MockIdentityRepository(),
          ),
          RepositoryProvider<UnexpectedErrorReporter>.value(value: (_, _) {}),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<AuthBloc>.value(value: auth),
            BlocProvider<OnboardingBloc>.value(value: onboarding),
            BlocProvider<UnreadBadgeCubit>.value(value: badge),
            ...rig.providers,
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
    expect(AppRouter.messageNewPath, '/messages/new');
    expect(AppRouter.messageDraftPath, '/messages/new/draft');
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

    testWidgets('the route passes the request banner and the report seam '
        '(W7-18)', (tester) async {
      await openAt(tester, const {
        'messaging',
      }, location: AppRouter.messagePath(kThreadId));

      final screen = tester.widget<ThreadScreen>(find.byType(ThreadScreen));
      expect(screen.bannerBuilder, same(buildRequestBanner));
      expect(screen.onReport, same(reportConversationPeer));
      expect(screen.composerBuilder, isNotNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a received request shows the banner on the real route, with '
        'no composer', (tester) async {
      await openAt(
        tester,
        const {'messaging', 'graph'},
        location: AppRouter.messagePath(kThreadId),
        headerState: ConversationState.CONVERSATION_STATE_REQUEST,
        headerFolder: Folder.FOLDER_REQUESTS,
      );

      expect(find.text('Sam Rivera wants to message you'), findsOneWidget);
      expect(find.byKey(RequestBanner.acceptKey), findsOneWidget);
      expect(find.byKey(RequestBanner.blockKey), findsOneWidget);
      expect(find.byType(MessageComposer), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the sender of a pending request sees the waiting note and '
        'the composer', (tester) async {
      await openAt(
        tester,
        const {'messaging'},
        location: AppRouter.messagePath(kThreadId),
        headerState: ConversationState.CONVERSATION_STATE_REQUEST,
      );

      expect(find.text(kSentRequestText), findsOneWidget);
      expect(find.byType(MessageComposer), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an accepted conversation has the composer and no banner', (
      tester,
    ) async {
      await openAt(tester, const {
        'messaging',
      }, location: AppRouter.messagePath(kThreadId));

      expect(find.byType(MessageComposer), findsOneWidget);
      expect(find.textContaining('wants to message you'), findsNothing);
      expect(find.text(kSentRequestText), findsNothing);
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

  // W7-19: re-checked. A conversation is a full-screen route outside the
  // shell (no bar or rail under a composer); the inbox and its Requests folder
  // are the shell's children, which is why the Messages tab can mark them.
  group('shell placement (W7-19)', () {
    testWidgets('/messages/:id has no MainShell above it', (tester) async {
      await openAt(tester, const {
        'messaging',
      }, location: AppRouter.messagePath(kThreadId));

      expect(find.byType(ThreadScreen), findsOneWidget);
      expect(find.byType(MainShell), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the picker is outside the shell too', (tester) async {
      await openAt(tester, const {
        'messaging',
      }, location: AppRouter.messageNewPath);

      expect(find.byType(RecipientPicker), findsOneWidget);
      expect(find.byType(MainShell), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the inbox and the Requests folder are inside it', (
      tester,
    ) async {
      await openAt(tester, const {'messaging'});
      expect(find.byType(ConversationsScreen), findsOneWidget);
      expect(find.byType(MainShell), findsOneWidget);

      await openAt(tester, const {
        'messaging',
      }, location: AppRouter.messageRequestsPath);
      expect(find.byType(ConversationsScreen), findsOneWidget);
      expect(find.byType(MainShell), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('/messages/new (W7-17)', () {
    testWidgets('with messaging off it redirects Home, no RPC', (tester) async {
      final (path, _) = await openAt(tester, const {
        'graph',
      }, location: AppRouter.messageNewPath);

      expect(path, AppRouter.homePath);
      expect(find.byType(RecipientPicker), findsNothing);
      verifyNever(
        () => graphRepo.listFollowing(
          userId: any(named: 'userId'),
          pageSize: any(named: 'pageSize'),
          pageToken: any(named: 'pageToken'),
        ),
      );
    });

    testWidgets('"new" is the picker, never a conversation id', (tester) async {
      final (path, repo) = await openAt(tester, const {
        'messaging',
        'graph',
      }, location: AppRouter.messageNewPath);

      expect(path, AppRouter.messageNewPath);
      expect(find.byType(RecipientPicker), findsOneWidget);
      expect(find.byType(ThreadScreen), findsNothing);
      verifyNever(() => repo.refreshThread(any()));
      verify(
        () => graphRepo.listFollowing(
          userId: 'uid-1',
          pageSize: 20,
          pageToken: '',
        ),
      ).called(1);
      expect(find.text('Ada Lovelace'), findsOneWidget);
    });

    testWidgets('the inbox "New message" action opens the picker', (
      tester,
    ) async {
      await openAt(tester, const {'messaging', 'graph'});

      await tester.tap(find.byTooltip('New message'));
      await tester.pumpAndSettle();

      expect(find.byType(RecipientPicker), findsOneWidget);
      expect(find.text('Sam Rivera'), findsOneWidget);
    });

    testWidgets('the draft route without a person goes back to the picker', (
      tester,
    ) async {
      final (path, _) = await openAt(tester, const {
        'messaging',
        'graph',
      }, location: AppRouter.messageDraftPath);

      expect(path, AppRouter.messageNewPath);
      expect(find.byType(DraftThreadScreen), findsNothing);
      expect(find.byType(RecipientPicker), findsOneWidget);
    });

    testWidgets('someone with no conversation opens a draft; someone with '
        'one opens that conversation', (tester) async {
      final (_, repo) = await openAt(tester, const {
        'messaging',
        'graph',
      }, location: AppRouter.messageNewPath);

      await tester.tap(find.text('Ada Lovelace'));
      await tester.pumpAndSettle();
      expect(find.byType(DraftThreadScreen), findsOneWidget);
      verifyNever(() => repo.refreshThread(any()));

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an existing conversation is opened, not duplicated', (
      tester,
    ) async {
      final (_, repo) = await openAt(tester, const {
        'messaging',
        'graph',
      }, location: AppRouter.messageNewPath);

      await tester.tap(find.text('Sam Rivera'));
      await tester.pumpAndSettle();

      expect(find.byType(DraftThreadScreen), findsNothing);
      expect(find.byType(ThreadScreen), findsOneWidget);
      verify(() => repo.refreshThread(kThreadId)).called(1);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
