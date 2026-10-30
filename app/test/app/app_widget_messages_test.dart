import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:drift/native.dart';
import 'package:dzeroth/app/app_widget.dart';
import 'package:dzeroth/core/network/rate_limit_hold.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/account/data/account_repository.dart';
import 'package:dzeroth/features/auth/data/auth_repository.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/engagement/data/bookmarks_repository.dart';
import 'package:dzeroth/features/engagement/data/engagement_repository.dart';
import 'package:dzeroth/features/engagement/data/likes_repository.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/messages/data/messaging_repository.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_gate.dart';
import 'package:dzeroth/features/messages/data/messaging_store.dart';
import 'package:dzeroth/features/messages/presentation/bloc/messages_badge_cubit.dart';
import 'package:dzeroth/features/messages/presentation/thread_screen.dart';
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
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../support/fake_push_messaging.dart';
import '../support/media_fixtures.dart' show MockMediaRepository;
import '../support/messaging_fixtures.dart';
import '../support/notifications_fixtures.dart';
import '../support/suggestions_fixtures.dart';
import '../support/thread_test_support.dart';

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockIdentity extends Mock implements IdentityRepository {}

class _MockGraph extends Mock implements GraphRepository {}

class _MockAccount extends Mock implements AccountRepository {}

class _MockAuthRepository extends Mock implements AuthRepository {}

class _MockPosts extends Mock implements PostsRepository {}

class _MockTimeline extends Mock implements TimelineRepository {}

class _MockNotifications extends Mock implements NotificationsRepository {}

class _MockMessaging extends Mock implements MessagingRepository {
  _MockMessaging() {
    // W7-26: the router listens to the gate; app_widget runs the probe.
    when(() => gate)
        .thenReturn(MessagingFeatureGate(isMessagingEnabled: () => false));
    when(probeAccess).thenAnswer((_) async {});
  }
}

class _MockModeration extends Mock implements ModerationRepository {}

class _MockEngagement extends Mock implements EngagementRepository {}

class _MockLikes extends Mock implements LikesRepository {}

class _MockBookmarks extends Mock implements BookmarksRepository {}

/// W7-19: the app-level wiring of the Messages badge and the message push:
/// the seed from `GetMe`, the foreground rules, sign-out, and the tap that
/// opens a conversation.
void main() {
  late _MockAuthBloc authBloc;
  late _MockOnboardingBloc onboardingBloc;
  late _MockNotifications notifications;
  late _MockMessaging messagingRepo;
  late FakePushMessaging messaging;
  late PushCubit push;
  late UnreadBadgeCubit unreadBadge;
  late AppDatabase database;
  late StreamController<OnboardingState> onboardingStates;
  late StreamController<AuthState> authStates;

  final conv = hexId(0xc1);
  const user = AppUser(
    uid: 'uid-1',
    email: 'a@example.com',
    emailVerified: true,
    isPasswordProvider: true,
  );
  const authed = AuthState(status: AuthStatus.authenticated, user: user);

  OnboardingState ready({
    Set<String> flags = const {},
    int unread = 0,
    int unreadConversations = 0,
  }) => OnboardingState(
    status: OnboardingStatus.ready,
    enabledFeatures: flags,
    unreadNotificationCount: unread,
    unreadConversationCount: unreadConversations,
  );

  setUpAll(() {
    registerFallbackValue(const OnboardingRefreshRequested());
  });

  setUp(() {
    authBloc = _MockAuthBloc();
    onboardingBloc = _MockOnboardingBloc();
    notifications = _MockNotifications();
    messagingRepo = _MockMessaging();
    messaging = FakePushMessaging(
      currentPermission: PushPermission.notDetermined,
    );
    unreadBadge = UnreadBadgeCubit();
    database = AppDatabase.forTesting(NativeDatabase.memory());
    onboardingStates = StreamController<OnboardingState>.broadcast();
    authStates = StreamController<AuthState>.broadcast();
    when(() => notifications.enabled).thenReturn(true);
    push = PushCubit(messaging: messaging, repository: notifications);
    // No cached Inbox row unless a test says so.
    when(() => messagingRepo.cachedConversation(any()))
        .thenAnswer((_) async => null);
    // The conversation a tapped push opens.
    when(() => messagingRepo.rateLimitedFor()).thenReturn(null);
    when(() => messagingRepo.rateLimitHold).thenReturn(RateLimitHold());
    when(() => messagingRepo.cachedThread(any())).thenAnswer(
      (_) async => ThreadSnapshot(
        messages: msgs(1, 2),
        conversation: threadConv(id: conv),
      ),
    );
    when(() => messagingRepo.refreshThread(any())).thenAnswer(
      (_) async => ThreadSnapshot(
        messages: msgs(1, 2),
        conversation: threadConv(id: conv),
      ),
    );
  });

  tearDown(() async {
    await push.close();
    await unreadBadge.close();
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
    final bookmarks = _MockBookmarks();
    when(() => bookmarks.events)
        .thenAnswer((_) => const Stream<BookmarkEvent>.empty());
    await tester.pumpWidget(
      AppWidget(
        authBloc: authBloc,
        onboardingBloc: onboardingBloc,
        identityRepository: _MockIdentity(),
        graphRepository: _MockGraph(),
        suggestionsRepository: FakeSuggestionsRepository(const []),
        accountRepository: _MockAccount(),
        authRepository: _MockAuthRepository(),
        database: database,
        postsRepository: _MockPosts(),
        timelineRepository: _MockTimeline(),
        postsGate: PostsFeatureGate(isPostsEnabled: () => false),
        mediaRepository: MockMediaRepository(),
        notificationsRepository: notifications,
        messagingRepository: messagingRepo,
        moderationRepository: _MockModeration(),
        engagementRepository: _MockEngagement(),
        bookmarksRepository: bookmarks,
        likesRepository: _MockLikes(),
        pushCubit: push,
        unreadBadgeCubit: unreadBadge,
      ),
    );
    await tester.pump();
  }

  pb.Conversation cachedRow({
    required int unread,
    Folder folder = Folder.FOLDER_INBOX,
  }) => threadConv(id: conv, unread: unread, folder: folder);

  /// The Messages badge the app provides.
  MessagesBadgeCubit messagesBadge(WidgetTester tester) =>
      tester.element(find.byType(Navigator).first).read<MessagesBadgeCubit>();

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }

  group('the read-only access probe (W7-26)', () {
    testWidgets('runs once at session start and when the flag set changes, '
        'never on an unread-count change', (tester) async {
      await pump(tester, onboarding: ready(flags: {'graph'}));
      verify(() => messagingRepo.probeAccess()).called(1);

      // Only the unread count moved: no probe.
      onboardingStates.add(ready(flags: {'graph'}, unreadConversations: 2));
      await tester.pump();
      verifyNever(() => messagingRepo.probeAccess());

      // The flag set changed: one probe.
      onboardingStates.add(ready(flags: {'graph', 'search'}));
      await tester.pump();
      verify(() => messagingRepo.probeAccess()).called(1);
    });
  });

  group('seeding from GetMe', () {
    testWidgets('a ready GetMe with messaging on seeds the Messages badge '
        '(notifications need not be on)', (tester) async {
      await pump(
        tester,
        onboarding: ready(flags: {'messaging'}, unreadConversations: 3),
      );

      expect(messagesBadge(tester).state, 3);
      expect(unreadBadge.state, 0);
    });

    testWidgets('with messaging off nothing is seeded', (tester) async {
      await pump(
        tester,
        onboarding: ready(flags: {'notifications'}, unreadConversations: 3),
      );

      expect(messagesBadge(tester).state, 0);
    });

    testWidgets('a fresh GetMe with only the conversation count changed '
        're-seeds it', (tester) async {
      await pump(
        tester,
        onboarding: ready(flags: {'messaging'}, unreadConversations: 3),
      );

      onboardingStates.add(ready(flags: {'messaging'}, unreadConversations: 7));
      await tester.pump();

      expect(messagesBadge(tester).state, 7);
    });

    testWidgets('the notifications count and the conversation count are '
        'seeded apart', (tester) async {
      await pump(
        tester,
        onboarding: ready(
          flags: {'notifications', 'messaging'},
          unread: 4,
          unreadConversations: 2,
        ),
      );

      expect(unreadBadge.state, 4);
      expect(messagesBadge(tester).state, 2);
    });

    testWidgets('messaging turning off mid-session resets it', (tester) async {
      await pump(
        tester,
        onboarding: ready(flags: {'messaging'}, unreadConversations: 3),
      );

      onboardingStates.add(ready(unreadConversations: 3));
      await tester.pump();

      expect(messagesBadge(tester).state, 0);
    });

    testWidgets('sign-out resets it', (tester) async {
      await pump(
        tester,
        auth: authed,
        onboarding: ready(
          flags: {'notifications', 'messaging'},
          unreadConversations: 3,
        ),
      );
      expect(messagesBadge(tester).state, 3);

      authStates.add(const AuthState(status: AuthStatus.unauthenticated));
      await settle(tester);

      expect(messagesBadge(tester).state, 0);
    });
  });

  group('each badge is seeded when its own number changes (S6)', () {
    final flags = {'notifications', 'messaging'};

    testWidgets('a new conversation count does not undo a local mark-seen of '
        'the notifications badge', (tester) async {
      await pump(
        tester,
        onboarding: ready(flags: flags, unread: 4, unreadConversations: 2),
      );
      await tester.pump();
      unreadBadge.clear(); // the user opened Notifications
      expect(unreadBadge.state, 0);

      onboardingStates.add(
        ready(flags: flags, unread: 4, unreadConversations: 5),
      );
      await tester.pump();

      expect(messagesBadge(tester).state, 5);
      expect(unreadBadge.state, 0);
    });

    testWidgets('a new notifications count does not undo a local clear of the '
        'Messages badge', (tester) async {
      await pump(
        tester,
        onboarding: ready(flags: flags, unread: 4, unreadConversations: 2),
      );
      await tester.pump();
      messagesBadge(tester).clearUnread(conv); // a thread opened unread
      expect(messagesBadge(tester).state, 1);

      onboardingStates.add(
        ready(flags: flags, unread: 6, unreadConversations: 2),
      );
      await tester.pump();

      expect(unreadBadge.state, 6);
      expect(messagesBadge(tester).state, 1);
    });

    testWidgets('a flag-set change seeds both', (tester) async {
      await pump(
        tester,
        onboarding: ready(flags: flags, unread: 4, unreadConversations: 2),
      );
      await tester.pump();
      unreadBadge.clear();
      messagesBadge(tester).clearUnread(conv);

      onboardingStates.add(
        ready(flags: {...flags, 'graph'}, unread: 4, unreadConversations: 2),
      );
      await tester.pump();

      expect(unreadBadge.state, 4);
      expect(messagesBadge(tester).state, 2);
    });

    testWidgets('the same GetMe again changes nothing', (tester) async {
      await pump(
        tester,
        onboarding: ready(flags: flags, unread: 4, unreadConversations: 2),
      );
      await tester.pump();
      unreadBadge.clear();
      messagesBadge(tester).clearUnread(conv);

      onboardingStates.add(
        ready(flags: flags, unread: 4, unreadConversations: 2),
      );
      await tester.pump();

      expect(unreadBadge.state, 0);
      expect(messagesBadge(tester).state, 1);
    });
  });

  group('a foreground message push', () {
    final flags = {'notifications', 'messaging'};

    testWidgets('adds one to the Messages badge and leaves the notifications '
        'badge alone', (tester) async {
      await pump(
        tester,
        onboarding: ready(flags: flags, unread: 4, unreadConversations: 2),
      );
      await tester.pump();

      messaging.foreground.add(
        PushMessage(type: 'message', conversationId: conv),
      );
      await tester.pump();

      expect(messagesBadge(tester).state, 3);
      expect(unreadBadge.state, 4);
    });

    testWidgets('a cached Inbox row that already shows unread adds nothing: '
        'the seed counted it (F-1 c)', (tester) async {
      when(() => messagingRepo.cachedConversation(conv))
          .thenAnswer((_) async => cachedRow(unread: 2));
      await pump(
        tester,
        onboarding: ready(flags: flags, unreadConversations: 1),
      );
      await tester.pump();

      messaging.foreground.add(
        PushMessage(type: 'message', conversationId: conv),
      );
      await settle(tester);

      expect(messagesBadge(tester).state, 1);
    });

    testWidgets('seed 1, push with the unread row, then open it: 0, not 1 '
        'left behind (S2 a)', (tester) async {
      when(() => messagingRepo.cachedConversation(conv))
          .thenAnswer((_) async => cachedRow(unread: 1));
      final unreadThread = ThreadSnapshot(
        messages: msgs(1, 2),
        conversation: threadConv(id: conv, unread: 1),
      );
      when(() => messagingRepo.cachedThread(any()))
          .thenAnswer((_) async => unreadThread);
      when(() => messagingRepo.refreshThread(any()))
          .thenAnswer((_) async => unreadThread);
      when(
        () => messagingRepo.markConversationRead(
          idempotencyKey: any(named: 'idempotencyKey'),
          conversationId: any(named: 'conversationId'),
        ),
      ).thenAnswer((_) async {});
      await pump(
        tester,
        auth: authed,
        onboarding: ready(flags: flags, unreadConversations: 1),
      );
      await settle(tester);

      messaging.foreground.add(
        PushMessage(type: 'message', conversationId: conv),
      );
      await settle(tester);
      expect(messagesBadge(tester).state, 1);

      messaging.opened.add(PushMessage(type: 'message', conversationId: conv));
      await tester.pumpAndSettle();

      expect(find.byType(ThreadScreen), findsOneWidget);
      expect(messagesBadge(tester).state, 0);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a cached row that is read, or no cached row: the push '
        'counts', (tester) async {
      when(() => messagingRepo.cachedConversation(conv))
          .thenAnswer((_) async => cachedRow(unread: 0));
      await pump(
        tester,
        onboarding: ready(flags: flags, unreadConversations: 1),
      );
      await tester.pump();

      messaging.foreground.add(
        PushMessage(type: 'message', conversationId: conv),
      );
      messaging.foreground.add(
        PushMessage(type: 'message', conversationId: hexId(0xc2)),
      );
      await settle(tester);

      expect(messagesBadge(tester).state, 3);
    });

    testWidgets('a request is never counted (D10)', (tester) async {
      when(() => messagingRepo.cachedConversation(conv)).thenAnswer(
        (_) async => cachedRow(unread: 1, folder: Folder.FOLDER_REQUESTS),
      );
      await pump(
        tester,
        onboarding: ready(flags: flags, unreadConversations: 1),
      );
      await tester.pump();

      messaging.foreground.add(
        PushMessage(type: 'message', conversationId: conv),
      );
      await settle(tester);

      expect(messagesBadge(tester).state, 1);
    });

    testWidgets('a cache that cannot be read counts it: the next Inbox load '
        'or GetMe reconciles', (tester) async {
      when(() => messagingRepo.cachedConversation(conv))
          .thenAnswer((_) async => throw StateError('db closed'));
      await pump(
        tester,
        onboarding: ready(flags: flags, unreadConversations: 1),
      );
      await tester.pump();

      messaging.foreground.add(
        PushMessage(type: 'message', conversationId: conv),
      );
      await settle(tester);

      expect(messagesBadge(tester).state, 2);
    });

    testWidgets('on the Notifications screen: notifications badge unchanged, '
        'Messages badge +1', (tester) async {
      when(
        () => notifications.cached(),
      ).thenAnswer((_) async => snapshotOfNotifs([notif('a', minutesAgo: 1)]));
      when(() => notifications.sinceRefresh).thenReturn(const Duration());
      when(() => notifications.sinceRefreshAttempt)
          .thenReturn(const Duration());
      when(() => notifications.rateLimitedFor()).thenReturn(null);
      when(() => notifications.markSeen(any())).thenAnswer((_) async => null);
      await pump(
        tester,
        auth: authed,
        onboarding: ready(flags: flags, unreadConversations: 1),
      );
      final router = GoRouter.of(tester.element(find.byType(Navigator).first));
      router.go(AppRouter.notificationsPath);
      await tester.pump();
      await tester.pump();
      expect(
        router.routeInformationProvider.value.uri.path,
        AppRouter.notificationsPath,
      );

      messaging.foreground.add(
        PushMessage(type: 'message', conversationId: conv),
      );
      await tester.pump();

      expect(unreadBadge.state, 0);
      expect(messagesBadge(tester).state, 2);
    });

    testWidgets('counts a conversation once, however many pushes', (
      tester,
    ) async {
      await pump(tester, onboarding: ready(flags: flags));
      await tester.pump();

      for (var i = 0; i < 3; i++) {
        messaging.foreground.add(
          PushMessage(type: 'message', conversationId: conv),
        );
        await tester.pump();
      }
      messaging.foreground.add(
        PushMessage(type: 'message', conversationId: hexId(0xc2)),
      );
      await tester.pump();

      expect(messagesBadge(tester).state, 2);
    });

    testWidgets('other pushes do not move the Messages badge', (tester) async {
      await pump(
        tester,
        onboarding: ready(flags: flags, unread: 4, unreadConversations: 2),
      );
      await tester.pump();

      messaging.foreground.add(const PushMessage(type: 'like', postId: '5'));
      await tester.pump();

      expect(messagesBadge(tester).state, 2);
      expect(unreadBadge.state, 5);
    });

    testWidgets('is not counted for a caller without messaging', (
      tester,
    ) async {
      await pump(
        tester,
        onboarding: ready(flags: {'notifications'}, unread: 4),
      );
      await tester.pump();

      messaging.foreground.add(
        PushMessage(type: 'message', conversationId: conv),
      );
      await tester.pump();

      expect(messagesBadge(tester).state, 0);
      expect(unreadBadge.state, 4);
    });
  });

  group('a tapped message push', () {
    testWidgets('from a cold start lands in the conversation once signed in', (
      tester,
    ) async {
      // The app starts signed out; push only starts once GetMe is ready, so
      // the launch message is handed over after the sign-in.
      messaging.launch = PushMessage(type: 'message', conversationId: conv);
      await pump(tester, onboarding: const OnboardingState());
      await tester.pump();
      final router = GoRouter.of(tester.element(find.byType(Navigator).first));
      expect(
        router.routeInformationProvider.value.uri.path,
        AppRouter.signInPath,
      );

      final signedIn = ready(flags: {'notifications', 'messaging'});
      when(() => authBloc.state).thenReturn(authed);
      when(() => onboardingBloc.state).thenReturn(signedIn);
      authStates.add(authed);
      onboardingStates.add(signedIn);
      await settle(tester);
      await tester.pumpAndSettle();

      // A push does not move the route information; the stack has it on top.
      expect(
        router.routerDelegate.currentConfiguration.matches.last.matchedLocation,
        '/messages/$conv',
      );
      expect(find.byType(ThreadScreen), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('from a cold start while already signed in (GetMe ready on the '
        'first frame) opens it too', (tester) async {
      messaging.launch = PushMessage(type: 'message', conversationId: conv);
      await pump(
        tester,
        auth: authed,
        onboarding: ready(flags: {'notifications', 'messaging'}),
      );
      await settle(tester);
      await tester.pumpAndSettle();

      final router = GoRouter.of(tester.element(find.byType(Navigator).first));
      expect(
        router.routerDelegate.currentConfiguration.matches.last.matchedLocation,
        '/messages/$conv',
      );
      expect(find.byType(ThreadScreen), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('from the background opens it too', (tester) async {
      await pump(
        tester,
        auth: authed,
        onboarding: ready(flags: {'notifications', 'messaging'}),
      );
      await settle(tester);

      messaging.opened.add(PushMessage(type: 'message', conversationId: conv));
      await tester.pumpAndSettle();

      expect(find.byType(ThreadScreen), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('with messaging off for the caller it lands Home (flag-off '
        'redirect)', (tester) async {
      messaging.launch = PushMessage(type: 'message', conversationId: conv);
      await pump(
        tester,
        auth: authed,
        onboarding: ready(flags: {'notifications'}),
      );
      await settle(tester);
      await tester.pumpAndSettle();

      final router = GoRouter.of(tester.element(find.byType(Navigator).first));
      expect(
        router.routerDelegate.currentConfiguration.matches.last.matchedLocation,
        AppRouter.homePath,
      );
      expect(find.byType(ThreadScreen), findsNothing);
    });

    testWidgets('a malformed conversation id opens nothing', (tester) async {
      await pump(
        tester,
        auth: authed,
        onboarding: ready(flags: {'notifications', 'messaging'}),
      );
      await settle(tester);

      messaging.opened.add(
        const PushMessage(type: 'message', conversationId: '../x'),
      );
      await tester.pumpAndSettle();

      final router = GoRouter.of(tester.element(find.byType(Navigator).first));
      expect(
        router.routerDelegate.currentConfiguration.matches.last.matchedLocation,
        AppRouter.homePath,
      );
      expect(find.byType(ThreadScreen), findsNothing);
    });
  });
}
