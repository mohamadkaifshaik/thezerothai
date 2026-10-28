import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/network/rate_limit_hold.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/messages/data/messaging_repository.dart';
import 'package:dzeroth/features/messages/data/messaging_store.dart';
import 'package:dzeroth/features/messages/data/timer_thread_poller.dart';
import 'package:dzeroth/features/messages/domain/thread_poller.dart';
import 'package:dzeroth/features/messages/presentation/bloc/thread_cubit.dart';
import 'package:dzeroth/features/messages/presentation/thread_screen.dart';
import 'package:dzeroth/features/messages/presentation/widgets/message_bubble.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/messaging_fixtures.dart';
import '../../../support/theme_harness.dart';
import '../../../support/thread_test_support.dart';

class MockMessagingRepository extends Mock implements MessagingRepository {}

class MockGraphRepository extends Mock implements GraphRepository {}

class MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

void main() {
  late MockMessagingRepository repo;
  late MockGraphRepository graphRepo;
  late MockOnboardingBloc onboarding;
  late FakeThreadPoller poller;
  late Future<PollResult> Function() pull;

  /// What the repository answers: the cache, and the network after a refresh.
  late ThreadSnapshot current;

  /// Messages [from]..[to], newest first, text "m<n>", from the peer.
  List<pb.Message> run(int from, int to, {bool alternate = false}) => [
    for (var n = to; n >= from; n--)
      msg(
        n,
        secondsAgo: 10000 - n,
        text: 'm$n',
        fromSelf: alternate && n.isEven,
      ),
  ];

  ThreadSnapshot snap(
    List<pb.Message> messages, {
    pb.Conversation? conversation,
    bool more = false,
  }) => ThreadSnapshot(
    messages: messages,
    conversation: conversation ?? threadConv(),
    sinceToken: 's',
    olderPageToken: more ? 'older' : '',
  );

  setUpAll(() {
    registerFallbackValue(const Duration());
  });

  setUp(() {
    repo = MockMessagingRepository();
    graphRepo = MockGraphRepository();
    onboarding = MockOnboardingBloc();
    poller = FakeThreadPoller();
    current = snap(run(1, 3));
    when(() => repo.rateLimitedFor()).thenReturn(null);
    when(() => repo.rateLimitHold).thenReturn(RateLimitHold());
    when(() => repo.cachedThread(any())).thenAnswer((_) async => current);
    when(() => repo.refreshThread(any())).thenAnswer((_) async => current);
    when(() => repo.pollThread(any()))
        .thenAnswer((_) async => const PollResult(newMessages: false));
    when(
      () => repo.markConversationRead(
        idempotencyKey: any(named: 'idempotencyKey'),
        conversationId: any(named: 'conversationId'),
      ),
    ).thenAnswer((_) async {});
    when(() => graphRepo.cached(any())).thenReturn(null);
  });

  late List<String> visited;

  Future<void> open(
    WidgetTester tester, {
    String? id,
    Set<String> features = const {'messaging', 'graph'},
    Brightness brightness = Brightness.light,
    Size size = const Size(400, 800),
    double textScale = 1,
    ThreadPollerBuilder? pollerBuilder,
    Widget Function(BuildContext, pb.Conversation?)? composerBuilder,
    void Function(BuildContext, pb.Conversation)? onReport,
    bool settle = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    visited = [];
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(enabledFeatures: features),
    );
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => ThreadScreen(
            conversationId: id ?? kThreadId,
            now: kMsgBase.add(const Duration(minutes: 1)),
            composerBuilder: composerBuilder,
            onReport: onReport,
            onOpenLink: (uri) => visited.add('link:$uri'),
            pollerBuilder:
                pollerBuilder ??
                (p, _) {
                  pull = p;
                  return poller;
                },
          ),
        ),
        GoRoute(
          path: '/messages',
          builder: (context, state) => const Scaffold(body: Text('inbox page')),
        ),
        GoRoute(
          path: '/profile/:handle',
          builder: (context, state) => Scaffold(
            body: Text('profile page ${state.pathParameters['handle']}'),
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
        child: BlocProvider<OnboardingBloc>.value(
          value: onboarding,
          child: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(textScale),
            ),
            child: MaterialApp.router(
              theme: brightness == Brightness.dark
                  ? appDarkTheme
                  : appLightTheme,
              routerConfig: router,
            ),
          ),
        ),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  ScrollPosition position(WidgetTester tester) =>
      tester.state<ScrollableState>(find.byType(Scrollable).first).position;

  ThreadCubit cubitOf(WidgetTester tester) =>
      BlocProvider.of<ThreadCubit>(tester.element(find.byType(Scaffold).first));

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Conversation info'));
    await tester.pumpAndSettle();
  }

  group('the matrix', () {
    forEachThemeAndWidth('a mixed conversation lays out without overflow', (
      tester,
      env,
    ) async {
      final tomb = msg(5, secondsAgo: 5).deepCopy()
        ..state = MessageState.MESSAGE_STATE_REMOVED
        ..text = '';
      current = snap([
        tomb,
        msg(
          4,
          fromSelf: true,
          secondsAgo: 20,
          text: 'see https://example.com/${'x' * 60}',
        ),
        msg(3, secondsAgo: 30, text: 'a longer message ' * 12),
        msg(2, secondsAgo: 40, text: 'hi'),
        msg(1, secondsAgo: 3 * 24 * 3600, text: 'an older day'),
      ]);

      await open(
        tester,
        brightness: env.brightness,
        size: env.size,
        textScale: env.textScale,
      );

      expect(tester.takeException(), isNull);
      expect(find.byType(MessageBubble), findsWidgets);
      expect(find.text('Sam Rivera'), findsWidgets);
      expect(find.byTooltip('Conversation info'), findsOneWidget);
      expect(find.text('This message was removed'), findsOneWidget);
      await openMenu(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('Delete conversation'), findsOneWidget);
    }, textScales: kMatrixTextScalesLarge);

    forEachThemeAndWidth('the read-only line and the unavailable state fit', (
      tester,
      env,
    ) async {
      current = snap(run(1, 3), conversation: threadConv(canReply: false));
      await open(
        tester,
        brightness: env.brightness,
        size: env.size,
        textScale: env.textScale,
      );
      expect(tester.takeException(), isNull);
      expect(find.text(kThreadReadOnlyText), findsOneWidget);
    }, textScales: kMatrixTextScalesLarge);
  });

  group('paging', () {
    testWidgets('45 messages: the newest 20 show; scrolling up loads more', (
      tester,
    ) async {
      current = snap(run(26, 45, alternate: true), more: true);
      when(() => repo.loadOlderMessages(any())).thenAnswer((_) async {
        current = snap(run(6, 45, alternate: true), more: true);
        return current;
      });

      await open(tester, size: const Size(400, 700));

      expect(cubitOf(tester).state.messages, hasLength(20));
      expect(find.text('m45'), findsOneWidget);
      expect(find.text('m5'), findsNothing);
      verifyNever(() => repo.loadOlderMessages(any()));
      expect(position(tester).maxScrollExtent, greaterThan(0));

      position(tester).jumpTo(position(tester).maxScrollExtent);
      await tester.pumpAndSettle();

      verify(() => repo.loadOlderMessages(kThreadId)).called(1);
      expect(cubitOf(tester).state.messages, hasLength(40));
      expect(cubitOf(tester).state.hasMore, isTrue);
    });

    testWidgets('the oldest page ends the list without another request', (
      tester,
    ) async {
      current = snap(run(26, 45), more: true);
      when(() => repo.loadOlderMessages(any())).thenAnswer((_) async {
        current = snap(run(1, 45));
        return current;
      });

      await open(tester, size: const Size(400, 700));
      position(tester).jumpTo(position(tester).maxScrollExtent);
      await tester.pumpAndSettle();
      position(tester).jumpTo(position(tester).maxScrollExtent);
      await tester.pumpAndSettle();

      verify(() => repo.loadOlderMessages(kThreadId)).called(1);
      expect(cubitOf(tester).state.messages, hasLength(45));
      expect(cubitOf(tester).state.hasMore, isFalse);
    });

    testWidgets('a short thread with older pages asks for them at once', (
      tester,
    ) async {
      current = snap(run(4, 5), more: true);
      when(() => repo.loadOlderMessages(any())).thenAnswer((_) async {
        current = snap(run(1, 5));
        return current;
      });

      await open(tester);

      verify(() => repo.loadOlderMessages(kThreadId)).called(1);
      expect(cubitOf(tester).state.messages, hasLength(5));
    });

    testWidgets('a failed older page shows an inline retry', (tester) async {
      current = snap(run(4, 5), more: true);
      when(() => repo.loadOlderMessages(any()))
          .thenThrow(const NetworkException('offline'));

      await open(tester);

      expect(
        find.text("Couldn't load earlier messages. Retry"),
        findsOneWidget,
      );
      when(() => repo.loadOlderMessages(any())).thenAnswer((_) async {
        current = snap(run(1, 5));
        return current;
      });
      await tester.tap(find.text("Couldn't load earlier messages. Retry"));
      await tester.pumpAndSettle();
      expect(find.text('m1'), findsOneWidget);
    });
  });

  group('polling', () {
    testWidgets('a new message at the bottom appears with no jump or pill', (
      tester,
    ) async {
      current = snap(run(1, 20));
      await open(tester, size: const Size(400, 700));
      expect(position(tester).pixels, 0);

      current = snap(run(1, 21));
      when(() => repo.pollThread(any()))
          .thenAnswer((_) async => const PollResult(newMessages: true));
      await pull();
      await tester.pumpAndSettle();

      expect(find.text('m21'), findsOneWidget);
      expect(position(tester).pixels, 0);
      expect(find.text('New messages'), findsNothing);
    });

    testWidgets('scrolled up: the list stays, a pill shows; the pill jumps', (
      tester,
    ) async {
      current = snap(run(1, 20));
      await open(tester, size: const Size(400, 700));
      position(tester).jumpTo(120);
      await tester.pumpAndSettle();
      final before = position(tester).pixels;
      expect(before, greaterThan(kThreadAtBottomSlack));
      final topLeft = tester.getTopLeft(find.text('m10'));

      current = snap(run(1, 21));
      when(() => repo.pollThread(any()))
          .thenAnswer((_) async => const PollResult(newMessages: true));
      await pull();
      await tester.pumpAndSettle();

      expect(position(tester).pixels, before);
      expect(tester.getTopLeft(find.text('m10')), topLeft);
      expect(find.text('m21'), findsNothing);
      expect(find.text('New messages'), findsOneWidget);

      await tester.tap(find.text('New messages'));
      await tester.pumpAndSettle();

      expect(find.text('New messages'), findsNothing);
      expect(find.text('m21'), findsOneWidget);
      expect(position(tester).pixels, 0);
    });

    testWidgets('scrolling back to the bottom shows them without the pill', (
      tester,
    ) async {
      current = snap(run(1, 20));
      await open(tester, size: const Size(400, 700));
      position(tester).jumpTo(120);
      await tester.pumpAndSettle();
      current = snap(run(1, 21));
      when(() => repo.pollThread(any()))
          .thenAnswer((_) async => const PollResult(newMessages: true));
      await pull();
      await tester.pumpAndSettle();
      expect(find.text('New messages'), findsOneWidget);

      position(tester).jumpTo(0);
      await tester.pumpAndSettle();

      expect(find.text('New messages'), findsNothing);
      expect(find.text('m21'), findsOneWidget);
    });

    testWidgets('a tap or a drag keeps the thread hot', (tester) async {
      await open(tester);
      final before = poller.inputs;

      await tester.tap(find.byType(MessageBubble).first, warnIfMissed: false);
      await tester.pump();

      expect(poller.inputs, greaterThan(before));
    });

    testWidgets('the poller starts on open and stops on leaving', (
      tester,
    ) async {
      await open(tester);
      expect(poller.starts, 1);

      await tester.pumpWidget(const SizedBox());
      expect(poller.disposed, isTrue);
    });

    testWidgets('app hidden: 0 polls; visible again: one at once', (
      tester,
    ) async {
      var elapsed = Duration.zero;
      Future<void> advance(Duration d) async {
        elapsed += d;
        await tester.pump(d);
      }

      await open(
        tester,
        pollerBuilder: (p, r) => TimerThreadPoller(
          pull: p,
          rateLimitHold: r.rateLimitHold,
          monotonic: () => elapsed,
        ),
      );
      await advance(const Duration(seconds: 15));
      verify(() => repo.pollThread(kThreadId)).called(1);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      await advance(const Duration(minutes: 10));
      verifyNever(() => repo.pollThread(any()));

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();
      verify(() => repo.pollThread(kThreadId)).called(1);
    });

    testWidgets('covered by the peer profile: not visible, no polling', (
      tester,
    ) async {
      await open(tester);
      expect(poller.visibility, isEmpty);

      await tester.tap(find.text('Sam Rivera').first);
      await tester.pumpAndSettle();
      expect(find.text('profile page sam'), findsOneWidget);
      expect(poller.visibility.last, isFalse);
    });

    testWidgets('a poll failure shows a notice over the messages', (
      tester,
    ) async {
      await open(tester);
      when(() => repo.pollThread(any()))
          .thenThrow(const NetworkException('offline'));

      await pull();
      await tester.pumpAndSettle();

      expect(
        find.text("You're offline. Showing saved messages."),
        findsOneWidget,
      );
      expect(find.byType(MessageBubble), findsWidgets);
    });
  });

  group('mark read', () {
    testWidgets('opens with unread: one MarkConversationRead', (tester) async {
      current = snap(run(1, 3), conversation: threadConv(unread: 2));

      await open(tester);

      verify(
        () => repo.markConversationRead(
          idempotencyKey: any(named: 'idempotencyKey'),
          conversationId: kThreadId,
        ),
      ).called(1);
    });

    testWidgets('opens with nothing unread: none', (tester) async {
      await open(tester);

      verifyNever(
        () => repo.markConversationRead(
          idempotencyKey: any(named: 'idempotencyKey'),
          conversationId: any(named: 'conversationId'),
        ),
      );
    });
  });

  group('read-only', () {
    testWidgets('can_reply false: no composer, the explanatory line', (
      tester,
    ) async {
      current = snap(run(1, 3), conversation: threadConv(canReply: false));

      await open(
        tester,
        composerBuilder: (_, _) => const SizedBox(key: Key('composer')),
      );

      expect(find.byKey(const Key('composer')), findsNothing);
      expect(find.text("You can't reply to this conversation"), findsOneWidget);
      expect(find.byType(MessageBubble), findsNWidgets(3));
    });

    testWidgets('can_reply true: the composer slot is drawn, no line', (
      tester,
    ) async {
      await open(
        tester,
        composerBuilder: (_, _) => const SizedBox(key: Key('composer')),
      );

      expect(find.byKey(const Key('composer')), findsOneWidget);
      expect(find.text(kThreadReadOnlyText), findsNothing);
    });
  });

  group('unavailable', () {
    testWidgets('a malformed id sends nothing', (tester) async {
      await open(tester, id: 'not-a-conversation');

      expect(find.text("This conversation isn't available"), findsOneWidget);
      verifyNever(() => repo.cachedThread(any()));
      verifyNever(() => repo.refreshThread(any()));
    });

    testWidgets('a deep link to a conversation you are not in (NOT_FOUND)', (
      tester,
    ) async {
      current = const ThreadSnapshot();
      when(() => repo.refreshThread(any()))
          .thenThrow(const NotFoundException('nope'));

      await open(tester, id: hexId(0xdead));

      expect(find.text("This conversation isn't available"), findsOneWidget);
      expect(find.byType(MessageBubble), findsNothing);
      expect(find.byTooltip('Conversation info'), findsNothing);
      expect(poller.running, isFalse);
    });

    testWidgets('Back still leaves the page', (tester) async {
      await open(tester, id: 'x');

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();

      expect(find.text('inbox page'), findsOneWidget);
    });
  });

  group('states', () {
    testWidgets('a failure with nothing cached: friendly error and Retry', (
      tester,
    ) async {
      current = const ThreadSnapshot();
      when(() => repo.refreshThread(any()))
          .thenThrow(const NetworkException('offline'));

      await open(tester);

      expect(
        find.text('No connection. Check your network and try again.'),
        findsOneWidget,
      );
      current = snap(run(1, 2));
      when(() => repo.refreshThread(any())).thenAnswer((_) async => current);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.byType(MessageBubble), findsNWidgets(2));
    });

    testWidgets('cache renders before the network answers', (tester) async {
      final network = Completer<ThreadSnapshot>();
      when(() => repo.refreshThread(any())).thenAnswer((_) => network.future);

      await open(tester, settle: false);
      await tester.pump();

      expect(find.text('m3'), findsOneWidget);
      network.complete(snap(run(1, 4)));
      await tester.pumpAndSettle();
      expect(find.text('m4'), findsOneWidget);
    });

    testWidgets('no messages yet', (tester) async {
      current = snap(const []);

      await open(tester);

      expect(find.text('No messages yet'), findsOneWidget);
    });

    testWidgets('tombstones are italic and muted', (tester) async {
      current = snap([
        msg(2).deepCopy()
          ..state = MessageState.MESSAGE_STATE_DELETED_ACCOUNT
          ..text = '',
        msg(1).deepCopy()
          ..state = MessageState.MESSAGE_STATE_REMOVED
          ..text = '',
      ]);

      await open(tester);

      for (final words in ['Message deleted', 'This message was removed']) {
        final text = tester.widget<Text>(find.text(words));
        expect(text.style?.fontStyle, FontStyle.italic, reason: words);
      }
    });

    testWidgets('the flag off for the caller: not available', (tester) async {
      await open(tester, features: const {});

      expect(find.text("Messages aren't available yet"), findsOneWidget);
      verifyNever(() => repo.cachedThread(any()));
    });

    testWidgets('day separators and the time under a group', (tester) async {
      current = snap([
        msg(3, secondsAgo: 0, text: 'today'),
        msg(2, secondsAgo: 5, text: 'also today'),
        msg(1, secondsAgo: 3 * 24 * 3600, text: 'older'),
      ]);

      await open(tester);

      expect(find.text('Today'), findsOneWidget);
      // One group today (one time), one on the older day.
      expect(find.byKey(MessageBubble.timeKey), findsNWidgets(2));
    });
  });

  group('header and menu', () {
    testWidgets('the header shows the peer; a tap opens the profile', (
      tester,
    ) async {
      await open(tester);

      expect(find.text('Sam Rivera'), findsOneWidget);
      expect(find.text('@sam'), findsOneWidget);
      await tester.tap(find.text('Sam Rivera'));
      await tester.pumpAndSettle();

      expect(find.text('profile page sam'), findsOneWidget);
      expect(visited, isEmpty);
    });

    testWidgets('the header is one labelled button', (tester) async {
      final handle = tester.ensureSemantics();
      await open(tester);

      final node = tester.getSemantics(
        find.bySemanticsLabel('Sam Rivera, @sam, View profile'),
      );
      expect(node.getSemanticsData().flagsCollection.isButton, isTrue);
      handle.dispose();
    });

    testWidgets('the menu: Block, Report (disabled), Delete conversation', (
      tester,
    ) async {
      await open(tester);

      await openMenu(tester);

      expect(find.text('Block @sam'), findsOneWidget);
      expect(find.text('Report @sam'), findsOneWidget);
      expect(find.text('Delete conversation'), findsOneWidget);
      final report = tester.widget<PopupMenuItem<Object?>>(
        find.ancestor(
          of: find.text('Report @sam'),
          matching: find.byWidgetPredicate((w) => w is PopupMenuItem),
        ),
      );
      expect(report.enabled, isFalse);
    });

    testWidgets('Report is live once onReport is wired', (tester) async {
      pb.Conversation? reported;
      await open(tester, onReport: (_, c) => reported = c);

      await openMenu(tester);
      await tester.tap(find.text('Report @sam'));
      await tester.pumpAndSettle();

      expect(reported?.peer.handle, 'sam');
    });

    testWidgets('Block is absent with the graph flag off', (tester) async {
      await open(tester, features: const {'messaging'});

      await openMenu(tester);

      expect(find.text('Block @sam'), findsNothing);
      expect(find.text('Delete conversation'), findsOneWidget);
    });

    testWidgets('Block confirms, calls the graph flow, makes it read-only', (
      tester,
    ) async {
      when(
        () => graphRepo.block(
          userId: any(named: 'userId'),
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenAnswer(
        (_) async => graph.Relationship(userId: 'u-sam', blocking: true),
      );
      await open(tester);

      await openMenu(tester);
      await tester.tap(find.text('Block @sam'));
      await tester.pumpAndSettle();
      expect(find.text('Block this account?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Block'));
      await tester.pumpAndSettle();

      verify(
        () => graphRepo.block(
          userId: 'u-sam',
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).called(1);
      expect(find.text(kThreadReadOnlyText), findsOneWidget);
      expect(find.text('Blocked @sam'), findsOneWidget);
    });

    testWidgets('Block cancelled sends nothing', (tester) async {
      await open(tester);

      await openMenu(tester);
      await tester.tap(find.text('Block @sam'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      verifyNever(
        () => graphRepo.block(
          userId: any(named: 'userId'),
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      );
      expect(find.text(kThreadReadOnlyText), findsNothing);
    });

    testWidgets('a failed Block says so and stays writable', (tester) async {
      when(
        () => graphRepo.block(
          userId: any(named: 'userId'),
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenThrow(const NetworkException('offline'));
      await open(tester);

      await openMenu(tester);
      await tester.tap(find.text('Block @sam'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Block'));
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.text(kThreadReadOnlyText), findsNothing);
    });

    testWidgets('Delete confirms, deletes, and leaves the page', (
      tester,
    ) async {
      when(
        () => repo.deleteConversation(
          idempotencyKey: any(named: 'idempotencyKey'),
          conversationId: any(named: 'conversationId'),
        ),
      ).thenAnswer((_) async {});
      await open(tester);

      await openMenu(tester);
      await tester.tap(find.text('Delete conversation'));
      await tester.pumpAndSettle();
      expect(find.text('Delete this conversation?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      verify(
        () => repo.deleteConversation(
          idempotencyKey: any(named: 'idempotencyKey'),
          conversationId: kThreadId,
        ),
      ).called(1);
      expect(find.text('inbox page'), findsOneWidget);
    });

    testWidgets('Delete cancelled or failed keeps the conversation', (
      tester,
    ) async {
      when(
        () => repo.deleteConversation(
          idempotencyKey: any(named: 'idempotencyKey'),
          conversationId: any(named: 'conversationId'),
        ),
      ).thenThrow(const NetworkException('offline'));
      await open(tester);

      await openMenu(tester);
      await tester.tap(find.text('Delete conversation'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      verifyNever(
        () => repo.deleteConversation(
          idempotencyKey: any(named: 'idempotencyKey'),
          conversationId: any(named: 'conversationId'),
        ),
      );

      await openMenu(tester);
      await tester.tap(find.text('Delete conversation'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(
        find.text('No connection. Check your network and try again.'),
        findsOneWidget,
      );
      expect(find.byType(MessageBubble), findsWidgets);
      expect(find.text('inbox page'), findsNothing);
    });
  });

  group('semantics', () {
    testWidgets(
      'each bubble reads "You said ..." / "<name> said ..., <time>"',
      (tester) async {
        final handle = tester.ensureSemantics();
        current = snap([
          msg(2, fromSelf: true, secondsAgo: 0, text: 'on it'),
          msg(1, secondsAgo: 10, text: 'can you check'),
        ]);

        await open(tester);

        expect(find.bySemanticsLabel('You said on it'), findsOneWidget);
        expect(
          find.bySemanticsLabel(RegExp(r'^Sam Rivera said can you check, ')),
          findsOneWidget,
        );
        final list = tester.getSemantics(find.bySemanticsLabel('Messages'));
        expect(list.getSemanticsData().role, SemanticsRole.list);
        handle.dispose();
      },
    );
  });
}
