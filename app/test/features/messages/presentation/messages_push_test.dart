import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/network/rate_limit_hold.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/messages/data/messaging_repository.dart';
import 'package:dzeroth/features/messages/data/messaging_store.dart';
import 'package:dzeroth/features/messages/data/timer_thread_poller.dart';
import 'package:dzeroth/features/messages/domain/thread_poller.dart';
import 'package:dzeroth/features/messages/presentation/conversations_screen.dart';
import 'package:dzeroth/features/messages/presentation/thread_screen.dart';
import 'package:dzeroth/features/notifications/data/push_messaging.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:dzeroth/gen/dzeroth/notifications/v1/notifications.pbenum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/messaging_fixtures.dart';
import '../../../support/messaging_shell_rig.dart';
import '../../../support/thread_test_support.dart';

class _MockMessagingRepository extends Mock implements MessagingRepository {}

class _MockGraphRepository extends Mock implements GraphRepository {}

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

/// W7-19: how the open conversation and the open inbox react to a foreground
/// direct-message push, what the Messages badge does meanwhile, and the
/// thread's hot poll interval (30 s with push registered on Android, ADR-0027
/// D7).
void main() {
  late _MockMessagingRepository repo;
  late _MockGraphRepository graphRepo;
  late _MockOnboardingBloc onboarding;
  late MessagingShellRig rig;
  late FakeThreadPoller poller;
  late ThreadSnapshot current;
  var polls = 0;
  var features = const {'messaging', 'graph', 'notifications'};

  final other = hexId(0xd2);

  setUpAll(() {
    registerFallbackValue(Folder.FOLDER_INBOX);
  });

  setUp(() {
    rig = MessagingShellRig();
    repo = _MockMessagingRepository();
    graphRepo = _MockGraphRepository();
    onboarding = _MockOnboardingBloc();
    poller = FakeThreadPoller();
    current = ThreadSnapshot(
      messages: msgs(1, 3),
      conversation: threadConv(),
      sinceToken: 's',
    );
    when(() => repo.rateLimitedFor()).thenReturn(null);
    when(() => repo.rateLimitHold).thenReturn(RateLimitHold());
    when(() => repo.cachedThread(any())).thenAnswer((_) async => current);
    when(() => repo.refreshThread(any())).thenAnswer((_) async => current);
    polls = 0;
    features = const {'messaging', 'graph', 'notifications'};
    when(() => repo.pollThread(any())).thenAnswer((_) async {
      polls++;
      return const PollResult(newMessages: false);
    });
    when(
      () => repo.markConversationRead(
        idempotencyKey: any(named: 'idempotencyKey'),
        conversationId: any(named: 'conversationId'),
      ),
    ).thenAnswer((_) async {});
    when(() => repo.cachedConversations(any())).thenAnswer(
      (_) async => ConversationsSnapshot(conversations: [conv(kThreadId)]),
    );
    when(() => repo.refreshConversations(any())).thenAnswer(
      (_) async => ConversationsResult(
        ConversationsSnapshot(conversations: [conv(kThreadId)]),
      ),
    );
    when(() => graphRepo.cached(any())).thenReturn(null);
  });

  Future<void> pumpScreen(WidgetTester tester, Widget screen) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(enabledFeatures: features),
    );
    final router = GoRouter(
      routes: [GoRoute(path: '/', builder: (context, state) => screen)],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<MessagingRepository>.value(value: repo),
          RepositoryProvider<GraphRepository>.value(value: graphRepo),
          RepositoryProvider<UnexpectedErrorReporter>.value(value: (_, _) {}),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<OnboardingBloc>.value(value: onboarding),
            ...rig.providers,
          ],
          child: MaterialApp.router(theme: appLightTheme, routerConfig: router),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openThread(
    WidgetTester tester, {
    ThreadPollerBuilder? pollerBuilder,
  }) => pumpScreen(
    tester,
    ThreadScreen(
      conversationId: kThreadId,
      now: kMsgBase.add(const Duration(minutes: 1)),
      pollerBuilder: pollerBuilder ?? (pull, _) => poller,
    ),
  );

  Future<void> leave(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  group('the open conversation', () {
    testWidgets('a push for it pulls at once, with no banner', (tester) async {
      await rig.start();
      await openThread(tester);
      expect(poller.pushes, 0);

      rig.messagePush(kThreadId);
      await tester.pumpAndSettle();

      expect(poller.pushes, 1);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.byType(MaterialBanner), findsNothing);
      await leave(tester);
    });

    testWidgets('each push pulls: the counter, not the id, is the trigger', (
      tester,
    ) async {
      await rig.start();
      await openThread(tester);

      rig.messagePush(kThreadId);
      await tester.pumpAndSettle();
      rig.messagePush(kThreadId);
      await tester.pumpAndSettle();

      expect(poller.pushes, 2);
      await leave(tester);
    });

    testWidgets('a push for another conversation does not pull this one', (
      tester,
    ) async {
      await rig.start();
      await openThread(tester);

      rig.messagePush(other);
      await tester.pumpAndSettle();

      expect(poller.pushes, 0);
      await leave(tester);
    });

    testWidgets('other kinds of push do not pull it', (tester) async {
      await rig.start();
      await openThread(tester);

      rig.messaging.foreground.add(
        const PushMessage(type: 'like', postId: '5'),
      );
      await tester.pumpAndSettle();

      expect(poller.pushes, 0);
      await leave(tester);
    });

    testWidgets('a hidden app is never pulled by a push (the poller decides)', (
      tester,
    ) async {
      // The screen forwards every nudge; ThreadPoller.onPush ignores it while
      // not visible (covered in timer_thread_poller_test). Here: the forward.
      await rig.start();
      await openThread(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();

      rig.messagePush(kThreadId);
      await tester.pumpAndSettle();

      expect(poller.visibility.last, isFalse);
      expect(poller.pushes, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await leave(tester);
    });
  });

  group('the Messages badge while a thread is open', () {
    testWidgets('does not count a push for the open conversation, counts '
        'another, and counts it again once the thread is closed', (
      tester,
    ) async {
      rig.badge.seed(2);
      await openThread(tester);

      expect(rig.badge.onMessagePush(kThreadId), isFalse);
      expect(rig.badge.state, 2);
      expect(rig.badge.onMessagePush(other), isTrue);
      expect(rig.badge.state, 3);

      await leave(tester);
      expect(rig.badge.onMessagePush(kThreadId), isTrue);
      expect(rig.badge.state, 4);
    });

    testWidgets('opening an unread conversation takes it out of the count', (
      tester,
    ) async {
      current = ThreadSnapshot(
        messages: msgs(1, 3),
        conversation: threadConv(unread: 3),
        sinceToken: 's',
      );
      rig.badge.seed(2);

      await openThread(tester);

      expect(rig.badge.state, 1);
      await leave(tester);
    });

    testWidgets('opening a read conversation leaves the count alone', (
      tester,
    ) async {
      rig.badge.seed(2);

      await openThread(tester);

      expect(rig.badge.state, 2);
      await leave(tester);
    });

    testWidgets('three unread conversations opened in turn clear the badge', (
      tester,
    ) async {
      rig.badge.seed(3);
      final ids = [hexId(0xc1), hexId(0xc2), hexId(0xc3)];
      for (final id in ids) {
        current = ThreadSnapshot(
          messages: msgs(1, 2),
          conversation: threadConv(id: id, unread: 1),
          sinceToken: 's',
        );
        await pumpScreen(
          tester,
          ThreadScreen(
            conversationId: id,
            now: kMsgBase.add(const Duration(minutes: 1)),
            pollerBuilder: (pull, _) => FakeThreadPoller(),
          ),
        );
        await leave(tester);
      }

      expect(rig.badge.state, 0);
    });

    testWidgets('a conversation a push counted is cleared by opening it', (
      tester,
    ) async {
      rig.badge.seed(1);
      expect(rig.badge.onMessagePush(kThreadId), isTrue);
      expect(rig.badge.state, 2);

      await openThread(tester);

      expect(rig.badge.state, 1);
      await leave(tester);
    });

    testWidgets('a request opened unread never lowers it: requests do not '
        'count (S1)', (tester) async {
      current = ThreadSnapshot(
        messages: msgs(1, 3),
        conversation: threadConv(
          unread: 2,
          state: ConversationState.CONVERSATION_STATE_REQUEST,
          folder: Folder.FOLDER_REQUESTS,
        ),
        sinceToken: 's',
      );
      rig.badge.seed(2);

      await openThread(tester);

      expect(rig.badge.state, 2);
      // It is still marked read.
      verify(
        () => repo.markConversationRead(
          idempotencyKey: any(named: 'idempotencyKey'),
          conversationId: kThreadId,
        ),
      ).called(1);
      await leave(tester);
    });

    testWidgets('messages that arrive while it is open never lower it', (
      tester,
    ) async {
      rig.badge.seed(2);
      late Future<PollResult> Function() pull;
      await openThread(
        tester,
        pollerBuilder: (p, _) {
          pull = p;
          return poller;
        },
      );
      expect(rig.badge.state, 2);

      // The peer writes while the thread is open: the header says unread 1,
      // the thread marks it read, and the badge (which never counted it) holds.
      current = ThreadSnapshot(
        messages: [msg(4, secondsAgo: 1), ...msgs(1, 3)],
        conversation: threadConv(unread: 1),
        sinceToken: 's2',
      );
      when(() => repo.pollThread(any()))
          .thenAnswer((_) async => const PollResult(newMessages: true));
      await pull();
      await tester.pumpAndSettle();

      verify(
        () => repo.markConversationRead(
          idempotencyKey: any(named: 'idempotencyKey'),
          conversationId: kThreadId,
        ),
      ).called(1);
      expect(rig.badge.state, 2);
      await leave(tester);
    });
  });

  group('hot poll interval (ADR-0027 D7)', () {
    // The default poller is a TimerThreadPoller on the repository's hold. Its
    // timers run on the test clock, so the interval is visible as the time of
    // the first poll.
    Future<int> pollsAfter(WidgetTester tester, Duration wait) async {
      polls = 0;
      await tester.pump(wait);
      return polls;
    }

    testWidgets('Android with push registered: 30 s', (tester) async {
      await rig.start();
      expect(rig.push.pushCoversThreads, isTrue);
      await openThread(tester, pollerBuilder: _timerBuilder(repo, rig));

      expect(await pollsAfter(tester, const Duration(seconds: 16)), 0);
      expect(await pollsAfter(tester, const Duration(seconds: 15)), 1);
      await leave(tester);
    });

    testWidgets('push not registered (not started): 15 s', (tester) async {
      expect(rig.push.pushCoversThreads, isFalse);
      await openThread(tester, pollerBuilder: _timerBuilder(repo, rig));

      expect(await pollsAfter(tester, const Duration(seconds: 16)), 1);
      await leave(tester);
    });

    testWidgets('iOS: 15 s even with the device registered', (tester) async {
      final ios = MessagingShellRig(
        platform: DevicePlatform.DEVICE_PLATFORM_IOS,
      );
      await ios.start();
      expect(ios.push.state.registered, isTrue);
      expect(ios.push.pushCoversThreads, isFalse);
      await openThread(tester, pollerBuilder: _timerBuilder(repo, ios));

      expect(await pollsAfter(tester, const Duration(seconds: 16)), 1);
      await leave(tester);
    });

    Future<void> openDefault(WidgetTester tester) => pumpScreen(
      tester,
      ThreadScreen(
        conversationId: kThreadId,
        now: kMsgBase.add(const Duration(minutes: 1)),
      ),
    );

    void thread(pb.Conversation? conversation) {
      current = ThreadSnapshot(
        messages: msgs(1, 3),
        conversation: conversation,
        sinceToken: 's',
      );
    }

    testWidgets('the default builder reads the push cubit', (tester) async {
      await rig.start();
      await openDefault(tester);

      expect(await pollsAfter(tester, const Duration(seconds: 16)), 0);
      expect(await pollsAfter(tester, const Duration(seconds: 15)), 1);
      await leave(tester);
    });

    // F-2: only a push that can reach the thread buys the slower interval.
    testWidgets('a muted conversation polls at 15 s', (tester) async {
      thread(threadConv(silent: true));
      await rig.start();
      await openDefault(tester);

      expect(await pollsAfter(tester, const Duration(seconds: 16)), 1);
      await leave(tester);
    });

    testWidgets('a request (Message requests folder) polls at 15 s', (
      tester,
    ) async {
      thread(
        threadConv(
          state: ConversationState.CONVERSATION_STATE_REQUEST,
          folder: Folder.FOLDER_REQUESTS,
        ),
      );
      await rig.start();
      await openDefault(tester);

      expect(await pollsAfter(tester, const Duration(seconds: 16)), 1);
      await leave(tester);
    });

    testWidgets('a request the caller sent (state REQUEST) polls at 15 s', (
      tester,
    ) async {
      thread(threadConv(state: ConversationState.CONVERSATION_STATE_REQUEST));
      await rig.start();
      await openDefault(tester);

      expect(await pollsAfter(tester, const Duration(seconds: 16)), 1);
      await leave(tester);
    });

    testWidgets('the notifications flag off polls at 15 s', (tester) async {
      features = const {'messaging', 'graph'};
      await rig.start();
      await openDefault(tester);

      expect(await pollsAfter(tester, const Duration(seconds: 16)), 1);
      await leave(tester);
    });

    testWidgets('a header that is not known yet polls at 15 s', (tester) async {
      thread(null);
      await rig.start();
      await openDefault(tester);

      expect(await pollsAfter(tester, const Duration(seconds: 16)), 1);
      await leave(tester);
    });
  });

  group('the Inbox re-syncs the badge (F-1 d)', () {
    testWidgets('a first page load rebuilds the count from its rows', (
      tester,
    ) async {
      final a = hexId(0xa1);
      final b = hexId(0xb2);
      final c = hexId(0xc3);
      when(() => repo.refreshConversations(any())).thenAnswer(
        (_) async => ConversationsResult(
          ConversationsSnapshot(
            conversations: [
              conv(a, unread: 2),
              conv(b, unread: 1, silent: true),
              conv(c),
            ],
          ),
        ),
      );
      rig.badge.seed(5);

      await pumpScreen(tester, const ConversationsScreen());

      expect(rig.badge.state, 1);
      await leave(tester);
    });

    testWidgets('the requests folder never touches it', (tester) async {
      when(() => repo.refreshConversations(any())).thenAnswer(
        (_) async => ConversationsResult(
          ConversationsSnapshot(conversations: [conv(hexId(0xa1), unread: 2)]),
        ),
      );
      rig.badge.seed(5);

      await pumpScreen(
        tester,
        const ConversationsScreen(folder: Folder.FOLDER_REQUESTS),
      );

      expect(rig.badge.state, 5);
      await leave(tester);
    });

    testWidgets('with older pages behind it the rows only raise it', (
      tester,
    ) async {
      when(() => repo.refreshConversations(any())).thenAnswer(
        (_) async => ConversationsResult(
          ConversationsSnapshot(
            conversations: [conv(hexId(0xa1), unread: 2)],
            olderPageToken: 'older',
          ),
        ),
      );
      rig.badge.seed(5);

      await pumpScreen(tester, const ConversationsScreen());

      expect(rig.badge.state, 5);
      await leave(tester);
    });
  });

  group('the inbox under an open conversation (M1)', () {
    late GoRouter router;
    var clock = kMsgBase;

    setUp(() => clock = kMsgBase);

    Future<void> pumpInboxWithThreadRoute(WidgetTester tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      whenListen(
        onboarding,
        const Stream<OnboardingState>.empty(),
        initialState: OnboardingState(enabledFeatures: features),
      );
      router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) =>
                ConversationsScreen(refreshClock: () => clock),
          ),
          GoRoute(
            path: '/t',
            builder: (context, state) => ThreadScreen(
              conversationId: kThreadId,
              now: kMsgBase.add(const Duration(minutes: 1)),
              pollerBuilder: (pull, _) => poller,
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: [
            RepositoryProvider<MessagingRepository>.value(value: repo),
            RepositoryProvider<GraphRepository>.value(value: graphRepo),
            RepositoryProvider<UnexpectedErrorReporter>.value(value: (_, _) {}),
          ],
          child: MultiBlocProvider(
            providers: [
              BlocProvider<OnboardingBloc>.value(value: onboarding),
              ...rig.providers,
            ],
            child: MaterialApp.router(
              theme: appLightTheme,
              routerConfig: router,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> openThreadOverInbox(WidgetTester tester) async {
      unawaited(router.push('/t'));
      await tester.pumpAndSettle();
      expect(find.byType(ThreadScreen), findsOneWidget);
    }

    Future<void> back(WidgetTester tester) async {
      router.pop();
      await tester.pumpAndSettle();
    }

    testWidgets('a push for the open conversation refreshes nothing, now or '
        'on return', (tester) async {
      await rig.start();
      await pumpInboxWithThreadRoute(tester);
      await openThreadOverInbox(tester);
      clearInteractions(repo);

      rig.messagePush(kThreadId);
      await tester.pumpAndSettle();
      verifyNever(() => repo.rateLimitedFor());
      verifyNever(() => repo.refreshConversations(any()));

      await back(tester);
      verifyNever(() => repo.rateLimitedFor());
      verifyNever(() => repo.refreshConversations(any()));
      await leave(tester);
    });

    testWidgets('a push for another conversation while the inbox is covered '
        'waits, and refreshes once on return', (tester) async {
      await rig.start();
      await pumpInboxWithThreadRoute(tester);
      await openThreadOverInbox(tester);
      clearInteractions(repo);

      rig.messagePush(other);
      rig.messagePush(other);
      await tester.pumpAndSettle();
      verifyNever(() => repo.rateLimitedFor());

      // Back after more than the 60 s throttle window: the one refresh runs.
      clock = clock.add(const Duration(seconds: 90));
      await back(tester);
      await tester.pump();

      verify(() => repo.refreshConversations(Folder.FOLDER_INBOX)).called(1);
      await leave(tester);
    });

    testWidgets('inside the throttle window the return refresh is scheduled '
        'for its end, once', (tester) async {
      await rig.start();
      await pumpInboxWithThreadRoute(tester);
      await openThreadOverInbox(tester);
      clearInteractions(repo);

      rig.messagePush(other);
      await tester.pumpAndSettle();
      await back(tester);

      verify(() => repo.rateLimitedFor()).called(1);
      verifyNever(() => repo.refreshConversations(any()));
      clock = clock.add(const Duration(seconds: 61));
      await tester.pump(const Duration(seconds: 61));
      verify(() => repo.refreshConversations(Folder.FOLDER_INBOX)).called(1);
      await leave(tester);
    });

    testWidgets('no push while covered, nothing on return', (tester) async {
      await rig.start();
      await pumpInboxWithThreadRoute(tester);
      await openThreadOverInbox(tester);
      clearInteractions(repo);

      await back(tester);

      verifyNever(() => repo.rateLimitedFor());
      verifyNever(() => repo.refreshConversations(any()));
      await leave(tester);
    });

    testWidgets('an inbox that is on top still refreshes on a push', (
      tester,
    ) async {
      await rig.start();
      await pumpInboxWithThreadRoute(tester);
      clearInteractions(repo);

      rig.messagePush(other);
      await tester.pump();
      await tester.pump();

      verify(() => repo.rateLimitedFor()).called(1);
      await leave(tester);
    });
  });

  group('the open inbox', () {
    testWidgets('a push asks for a throttled refresh, never an immediate one', (
      tester,
    ) async {
      await rig.start();
      await pumpScreen(tester, const ConversationsScreen());
      verify(() => repo.refreshConversations(Folder.FOLDER_INBOX)).called(1);
      clearInteractions(repo);

      rig.messagePush(kThreadId);
      await tester.pump();
      await tester.pump();

      // refreshIfStale checks the rate-limit hold first; inside the 60 s
      // window it schedules one refresh instead of making it now.
      verify(() => repo.rateLimitedFor()).called(1);
      verifyNever(() => repo.refreshConversations(any()));
      await leave(tester);
    });

    testWidgets('other kinds of push leave the inbox alone', (tester) async {
      await rig.start();
      await pumpScreen(tester, const ConversationsScreen());
      clearInteractions(repo);

      rig.messaging.foreground.add(
        const PushMessage(type: 'like', postId: '5'),
      );
      await tester.pump();
      await tester.pump();

      verifyNever(() => repo.rateLimitedFor());
      await leave(tester);
    });
  });
}

/// The real timer-based poller, as the default builder makes it, with
/// `pushRegistered` taken from [rig]'s push cubit.
ThreadPollerBuilder _timerBuilder(
  MessagingRepository repo,
  MessagingShellRig rig,
) {
  return (pull, repository) => TimerThreadPoller(
    pull: pull,
    rateLimitHold: repository.rateLimitHold,
    pushRegistered: rig.push.pushCoversThreads,
  );
}
