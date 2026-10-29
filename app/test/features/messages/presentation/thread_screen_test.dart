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
import 'package:dzeroth/features/messages/presentation/report_conversation.dart';
import 'package:dzeroth/features/messages/presentation/widgets/request_banner.dart';
import 'package:dzeroth/features/moderation/data/moderation_repository.dart';
import 'package:dzeroth/gen/dzeroth/moderation/v1/moderation.pbenum.dart';
import 'package:dzeroth/features/messages/presentation/thread_screen.dart';
import 'package:dzeroth/features/messages/presentation/widgets/message_bubble.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/messaging_fixtures.dart';
import '../../../support/messaging_shell_rig.dart';
import '../../../support/theme_harness.dart';
import '../../../support/thread_test_support.dart';

class MockMessagingRepository extends Mock implements MessagingRepository {}

class MockGraphRepository extends Mock implements GraphRepository {}

class MockModerationRepository extends Mock implements ModerationRepository {}

class MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

void main() {
  late MockMessagingRepository repo;
  late MockGraphRepository graphRepo;
  late MockModerationRepository moderation;
  late MockOnboardingBloc onboarding;
  late MessagingShellRig rig;
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
    registerFallbackValue(ReportTargetType.REPORT_TARGET_TYPE_POST);
    registerFallbackValue(ReportReason.REPORT_REASON_SPAM);
  });

  setUp(() {
    rig = MessagingShellRig();
    repo = MockMessagingRepository();
    graphRepo = MockGraphRepository();
    moderation = MockModerationRepository();
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
    when(() => repo.dropBlockedRequest(any())).thenAnswer((_) async {});
  });

  late List<String> visited;

  Future<void> open(
    WidgetTester tester, {
    String? id,
    Set<String> features = const {'messaging', 'graph', 'reports'},
    Brightness brightness = Brightness.light,
    Size size = const Size(400, 800),
    double textScale = 1,
    ThreadPollerBuilder? pollerBuilder,
    Widget Function(BuildContext, pb.Conversation?)? composerBuilder,
    ThreadBannerBuilder? bannerBuilder,
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
            bannerBuilder: bannerBuilder,
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
          RepositoryProvider<ModerationRepository>.value(value: moderation),
          RepositoryProvider<UnexpectedErrorReporter>.value(value: (_, _) {}),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<OnboardingBloc>.value(value: onboarding),
            ...rig.providers,
          ],
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
  group('request actions (W7-18)', () {
    pb.Conversation received() =>
        threadConv(state: ConversationState.CONVERSATION_STATE_REQUEST)
            .deepCopy()
          ..folder = Folder.FOLDER_REQUESTS;

    Widget composerStub(BuildContext context, pb.Conversation? conversation) =>
        const SizedBox(key: ValueKey('composer-stub'), height: 48);

    Finder composer() => find.byKey(const ValueKey('composer-stub'));

    Future<void> openRequest(
      WidgetTester tester, {
      pb.Conversation? conversation,
      Set<String> features = const {'messaging', 'graph', 'reports'},
      Brightness brightness = Brightness.light,
      Size size = const Size(400, 800),
      double textScale = 1,
    }) async {
      current = snap(run(1, 3), conversation: conversation ?? received());
      await open(
        tester,
        features: features,
        brightness: brightness,
        size: size,
        textScale: textScale,
        composerBuilder: composerStub,
        bannerBuilder: buildRequestBanner,
      );
    }

    void stubAccept([Future<void> Function()? answer]) => when(
      () => repo.acceptMessageRequest(
        idempotencyKey: any(named: 'idempotencyKey'),
        conversationId: any(named: 'conversationId'),
      ),
    ).thenAnswer((_) => (answer ?? () async {})());

    void stubDelete([Future<void> Function()? answer]) => when(
      () => repo.deleteConversation(
        idempotencyKey: any(named: 'idempotencyKey'),
        conversationId: any(named: 'conversationId'),
      ),
    ).thenAnswer((_) => (answer ?? () async {})());

    forEachThemeAndWidth('the banner lays out without overflow', (
      tester,
      env,
    ) async {
      await openRequest(
        tester,
        brightness: env.brightness,
        size: env.size,
        textScale: env.textScale,
      );

      expect(tester.takeException(), isNull);
      for (final key in [
        RequestBanner.acceptKey,
        RequestBanner.deleteKey,
        RequestBanner.blockKey,
      ]) {
        final box = tester.getRect(find.byKey(key));
        expect(box.height, greaterThanOrEqualTo(48));
        expect(box.right, lessThanOrEqualTo(env.size.width));
      }
      expect(find.text('Sam Rivera wants to message you'), findsOneWidget);
    }, textScales: kMatrixTextScalesLarge);

    testWidgets('a received request shows the banner instead of the composer', (
      tester,
    ) async {
      await openRequest(tester);

      expect(find.text('Sam Rivera wants to message you'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Accept'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Delete'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Block'), findsOneWidget);
      expect(composer(), findsNothing);
    });

    testWidgets('the banner names a peer without a display name by handle', (
      tester,
    ) async {
      final c = received()..peer.displayName = '';
      await openRequest(tester, conversation: c);

      expect(find.text('@sam wants to message you'), findsOneWidget);
    });

    testWidgets('an accepted conversation has no banner and its composer', (
      tester,
    ) async {
      await openRequest(tester, conversation: threadConv());

      expect(find.textContaining('wants to message you'), findsNothing);
      expect(find.text(kSentRequestText), findsNothing);
      expect(composer(), findsOneWidget);
    });

    testWidgets('the sender sees the waiting note above the composer', (
      tester,
    ) async {
      await openRequest(
        tester,
        conversation: threadConv(
          state: ConversationState.CONVERSATION_STATE_REQUEST,
        ),
      );

      expect(
        find.text('Waiting for them to accept. You can send up to 3 messages.'),
        findsOneWidget,
      );
      expect(composer(), findsOneWidget);
      expect(find.text('Accept'), findsNothing);
      expect(
        tester.getBottomLeft(find.text(kSentRequestText)).dy,
        lessThan(tester.getTopLeft(composer()).dy),
      );
    });

    testWidgets('a request thread that cannot be replied to is read-only', (
      tester,
    ) async {
      final c = received()..canReply = false;
      await openRequest(tester, conversation: c);

      expect(find.text(kThreadReadOnlyText), findsOneWidget);
      expect(find.textContaining('wants to message you'), findsNothing);
    });

    testWidgets('with messaging off for the caller there is no banner and '
        'no call', (tester) async {
      await openRequest(tester, features: const {});

      expect(find.textContaining('wants to message you'), findsNothing);
      expect(find.text("Messages aren't available yet"), findsOneWidget);
      verifyNever(
        () => repo.acceptMessageRequest(
          idempotencyKey: any(named: 'idempotencyKey'),
          conversationId: any(named: 'conversationId'),
        ),
      );
    });

    group('Accept', () {
      testWidgets('calls AcceptMessageRequest; the composer appears', (
        tester,
      ) async {
        stubAccept();
        await openRequest(tester);

        await tester.tap(find.widgetWithText(FilledButton, 'Accept'));
        await tester.pumpAndSettle();

        verify(
          () => repo.acceptMessageRequest(
            idempotencyKey: any(named: 'idempotencyKey'),
            conversationId: kThreadId,
          ),
        ).called(1);
        expect(find.textContaining('wants to message you'), findsNothing);
        expect(composer(), findsOneWidget);
        // The composer appearing is the answer: no toast on top of it.
        expect(find.byType(SnackBar), findsNothing);
        expect(find.byType(MessageBubble), findsWidgets);
      });

      testWidgets('NOT_FOUND makes the thread unavailable (the W7-15 rule)', (
        tester,
      ) async {
        stubAccept(() async => throw const NotFoundException('raw-not-found'));
        await openRequest(tester);

        await tester.tap(find.widgetWithText(FilledButton, 'Accept'));
        await tester.pumpAndSettle();

        expect(find.text(kThreadUnavailableText), findsOneWidget);
        expect(find.textContaining('wants to message you'), findsNothing);
        expect(find.byKey(RequestBanner.acceptKey), findsNothing);
        expect(composer(), findsNothing);
        expect(poller.stops, greaterThan(0));
      });

      testWidgets('buttons are off and Accept spins while it runs', (
        tester,
      ) async {
        final gate = Completer<void>();
        stubAccept(() => gate.future);
        await openRequest(tester);

        await tester.tap(find.widgetWithText(FilledButton, 'Accept'));
        await tester.pump();

        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(
          tester
              .widget<OutlinedButton>(find.byKey(RequestBanner.deleteKey))
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<OutlinedButton>(find.byKey(RequestBanner.blockKey))
              .onPressed,
          isNull,
        );
        gate.complete();
        await tester.pumpAndSettle();
        expect(composer(), findsOneWidget);
      });

      for (final (name, error, text) in <(String, AppException, String)>[
        (
          'offline',
          const NetworkException('raw-socket'),
          'No connection. Check your network and try again.',
        ),
        (
          'rate limited',
          const RateLimitedException('raw-rate-limited'),
          "You're doing that a bit too fast. Give it a moment and try again.",
        ),
        (
          'cannot message',
          const CannotMessageException(),
          CannotMessageException.userMessage,
        ),
        (
          'flag off',
          const FeatureDisabledException('raw-flag-off'),
          "Messages aren't available right now.",
        ),
        (
          'degraded',
          const DegradedModeException('raw-degraded-detail'),
          'dZeroth is in a limited mode right now. You can read your '
              'messages, but sending and changes are paused. Try again '
              'shortly.',
        ),
        (
          'unexpected',
          const UnknownApiException('raw-boom'),
          "Couldn't complete that. Please try again.",
        ),
      ]) {
        testWidgets('$name: a friendly snackbar, the banner stays', (
          tester,
        ) async {
          stubAccept(() async => throw error);
          await openRequest(tester);

          await tester.tap(find.widgetWithText(FilledButton, 'Accept'));
          await tester.pumpAndSettle();

          expect(find.text(text), findsOneWidget);
          // The raw detail never reaches the user (unless the friendly text
          // is the message itself, as for CANNOT_MESSAGE).
          if (!text.contains(error.message)) {
            expect(find.textContaining(error.message), findsNothing);
          }
          expect(find.text('Sam Rivera wants to message you'), findsOneWidget);
          expect(composer(), findsNothing);
          expect(
            tester
                .widget<FilledButton>(find.byKey(RequestBanner.acceptKey))
                .onPressed,
            isNotNull,
          );
        });
      }

      testWidgets('a retry after a failure reuses the idempotency key', (
        tester,
      ) async {
        var fail = true;
        stubAccept(() async {
          if (fail) throw const NetworkException('raw-socket');
        });
        await openRequest(tester);

        await tester.tap(find.widgetWithText(FilledButton, 'Accept'));
        await tester.pumpAndSettle();
        fail = false;
        // The error snackbar floats over the banner for a few seconds.
        ScaffoldMessenger.of(tester.element(find.byType(ThreadScreen)))
            .hideCurrentSnackBar();
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Accept'));
        await tester.pumpAndSettle();

        final keys = verify(
          () => repo.acceptMessageRequest(
            idempotencyKey: captureAny(named: 'idempotencyKey'),
            conversationId: kThreadId,
          ),
        ).captured;
        expect(keys, hasLength(2));
        expect(keys.first, keys.last);
        expect(composer(), findsOneWidget);
      });
    });

    group('Delete', () {
      testWidgets('confirms, deletes, says so and returns to the list', (
        tester,
      ) async {
        stubDelete();
        await openRequest(tester);

        await tester.tap(find.widgetWithText(OutlinedButton, 'Delete'));
        await tester.pumpAndSettle();
        expect(find.text('Delete this request?'), findsOneWidget);
        await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
        await tester.pumpAndSettle();

        verify(
          () => repo.deleteConversation(
            idempotencyKey: any(named: 'idempotencyKey'),
            conversationId: kThreadId,
          ),
        ).called(1);
        expect(find.text(kRequestDeletedText), findsOneWidget);
        expect(find.text('inbox page'), findsOneWidget);
      });

      testWidgets('Cancel sends nothing', (tester) async {
        await openRequest(tester);

        await tester.tap(find.widgetWithText(OutlinedButton, 'Delete'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        verifyNever(
          () => repo.deleteConversation(
            idempotencyKey: any(named: 'idempotencyKey'),
            conversationId: any(named: 'conversationId'),
          ),
        );
        expect(find.text('Sam Rivera wants to message you'), findsOneWidget);
      });

      testWidgets('a failure says why and stays on the request', (
        tester,
      ) async {
        stubDelete(() async => throw const NetworkException('raw-socket'));
        await openRequest(tester);

        await tester.tap(find.widgetWithText(OutlinedButton, 'Delete'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
        await tester.pumpAndSettle();

        expect(
          find.text('No connection. Check your network and try again.'),
          findsOneWidget,
        );
        expect(find.text('inbox page'), findsNothing);
        expect(find.text('Sam Rivera wants to message you'), findsOneWidget);
        expect(
          tester
              .widget<OutlinedButton>(find.byKey(RequestBanner.deleteKey))
              .onPressed,
          isNotNull,
        );
      });

      for (final (name, error, text) in <(String, AppException, String)>[
        (
          'rate limited',
          const RateLimitedException('raw-rate-limited'),
          "You're doing that a bit too fast. Give it a moment and try again.",
        ),
        (
          'flag off',
          const FeatureDisabledException('raw-flag-off'),
          "Messages aren't available right now.",
        ),
        (
          'degraded',
          const DegradedModeException('raw-degraded-detail'),
          'dZeroth is in a limited mode right now. You can read your '
              'messages, but sending and changes are paused. Try again '
              'shortly.',
        ),
        (
          'unexpected',
          const UnknownApiException('raw-boom'),
          "Couldn't complete that. Please try again.",
        ),
      ]) {
        testWidgets('$name: a friendly snackbar, the request stays', (
          tester,
        ) async {
          stubDelete(() async => throw error);
          await openRequest(tester);

          await tester.tap(find.widgetWithText(OutlinedButton, 'Delete'));
          await tester.pumpAndSettle();
          await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
          await tester.pumpAndSettle();

          expect(find.text(text), findsOneWidget);
          expect(find.textContaining(error.message), findsNothing);
          expect(find.text('inbox page'), findsNothing);
          expect(find.text('Sam Rivera wants to message you'), findsOneWidget);
        });
      }

      testWidgets('the dialog says they are not told (founder wording)', (
        tester,
      ) async {
        await openRequest(tester);

        await tester.tap(find.widgetWithText(OutlinedButton, 'Delete'));
        await tester.pumpAndSettle();

        expect(find.text('Delete this request?'), findsOneWidget);
        expect(
          find.text(
            "They won't be told. If they still can, they may message you "
            'again.',
          ),
          findsOneWidget,
        );
        expect(kDeleteRequestDetail, isNot(contains('can show up again')));
      });

      testWidgets("the info menu's Delete on a received request asks about "
          'the request', (tester) async {
        await openRequest(tester);

        await openMenu(tester);
        await tester.tap(find.text('Delete conversation'));
        await tester.pumpAndSettle();

        expect(find.text('Delete this request?'), findsOneWidget);
      });

      testWidgets("the info menu's Delete on an accepted conversation asks "
          'about the conversation', (tester) async {
        await openRequest(tester, conversation: threadConv());

        await openMenu(tester);
        await tester.tap(find.text('Delete conversation'));
        await tester.pumpAndSettle();

        expect(find.text('Delete this conversation?'), findsOneWidget);
      });
    });

    group('Block', () {
      void stubBlock([Future<graph.Relationship> Function()? answer]) =>
          when(
            () => graphRepo.block(
              userId: any(named: 'userId'),
              idempotencyKey: any(named: 'idempotencyKey'),
            ),
          ).thenAnswer(
            (_) =>
                (answer ??
                () async =>
                    graph.Relationship(userId: 'u-sam', blocking: true))(),
          );

      testWidgets('confirms, blocks through the graph flow, read-only', (
        tester,
      ) async {
        stubBlock();
        await openRequest(tester);

        await tester.tap(find.widgetWithText(OutlinedButton, 'Block'));
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
        expect(find.text('Blocked @sam'), findsOneWidget);
        expect(find.text(kThreadReadOnlyText), findsOneWidget);
        expect(find.textContaining('wants to message you'), findsNothing);
        verifyNever(
          () => repo.deleteConversation(
            idempotencyKey: any(named: 'idempotencyKey'),
            conversationId: any(named: 'conversationId'),
          ),
        );
      });

      testWidgets('while a block runs Accept, Delete and Block stay but are '
          'off', (tester) async {
        final gate = Completer<graph.Relationship>();
        stubBlock(() => gate.future);
        await openRequest(tester);

        await tester.tap(find.widgetWithText(OutlinedButton, 'Block'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Block'));
        await tester.pump();

        // All three are still drawn, none can be pressed.
        expect(find.byKey(RequestBanner.blockKey), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(find.byKey(RequestBanner.acceptKey))
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<OutlinedButton>(find.byKey(RequestBanner.deleteKey))
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<OutlinedButton>(find.byKey(RequestBanner.blockKey))
              .onPressed,
          isNull,
        );
        await tester.tap(
          find.byKey(RequestBanner.acceptKey),
          warnIfMissed: false,
        );
        await tester.pump();
        verifyNever(
          () => repo.acceptMessageRequest(
            idempotencyKey: any(named: 'idempotencyKey'),
            conversationId: any(named: 'conversationId'),
          ),
        );

        gate.complete(graph.Relationship(userId: 'u-sam', blocking: true));
        await tester.pumpAndSettle();
        expect(find.text(kThreadReadOnlyText), findsOneWidget);
      });

      testWidgets('after a failed block the three are on again', (
        tester,
      ) async {
        stubBlock(() async => throw const NetworkException('raw-socket'));
        await openRequest(tester);

        await tester.tap(find.widgetWithText(OutlinedButton, 'Block'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Block'));
        await tester.pumpAndSettle();

        for (final key in [
          RequestBanner.acceptKey,
          RequestBanner.deleteKey,
          RequestBanner.blockKey,
        ]) {
          final button = tester.widget<ButtonStyleButton>(find.byKey(key));
          expect(button.onPressed, isNotNull);
        }
      });

      testWidgets("blocking a requester drops its row from the cached "
          'lists, with no other call', (tester) async {
        stubBlock();
        await openRequest(tester);

        await tester.tap(find.widgetWithText(OutlinedButton, 'Block'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Block'));
        await tester.pumpAndSettle();

        verify(() => repo.dropBlockedRequest(kThreadId)).called(1);
        verifyNever(
          () => repo.deleteConversation(
            idempotencyKey: any(named: 'idempotencyKey'),
            conversationId: any(named: 'conversationId'),
          ),
        );
      });

      testWidgets('a failed block drops nothing', (tester) async {
        stubBlock(() async => throw const NetworkException('raw-socket'));
        await openRequest(tester);

        await tester.tap(find.widgetWithText(OutlinedButton, 'Block'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Block'));
        await tester.pumpAndSettle();

        verifyNever(() => repo.dropBlockedRequest(any()));
      });

      testWidgets('Cancel blocks nobody', (tester) async {
        await openRequest(tester);

        await tester.tap(find.widgetWithText(OutlinedButton, 'Block'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        verifyNever(
          () => graphRepo.block(
            userId: any(named: 'userId'),
            idempotencyKey: any(named: 'idempotencyKey'),
          ),
        );
        expect(find.text('Sam Rivera wants to message you'), findsOneWidget);
      });

      testWidgets('a failure says why; the banner stays', (tester) async {
        stubBlock(() async => throw const NetworkException('raw-socket'));
        await openRequest(tester);

        await tester.tap(find.widgetWithText(OutlinedButton, 'Block'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Block'));
        await tester.pumpAndSettle();

        expect(
          find.text('No connection. Check your network and try again.'),
          findsOneWidget,
        );
        expect(find.text('Sam Rivera wants to message you'), findsOneWidget);
        expect(find.text(kThreadReadOnlyText), findsNothing);
      });

      testWidgets('there is no Block with the graph flag off', (tester) async {
        await openRequest(tester, features: const {'messaging', 'reports'});

        expect(find.byKey(RequestBanner.blockKey), findsNothing);
        expect(find.byKey(RequestBanner.acceptKey), findsOneWidget);
        expect(find.byKey(RequestBanner.deleteKey), findsOneWidget);
      });
    });

    testWidgets('semantics: the banner is a live region; buttons in order', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await openRequest(tester);

      final accept = tester.getSemantics(find.byKey(RequestBanner.acceptKey));
      final delete = tester.getSemantics(find.byKey(RequestBanner.deleteKey));
      final block = tester.getSemantics(find.byKey(RequestBanner.blockKey));
      expect(accept.label, 'Accept');
      expect(delete.label, 'Delete');
      expect(block.label, 'Block');
      expect(
        tester.getRect(find.byKey(RequestBanner.acceptKey)).left,
        lessThan(tester.getRect(find.byKey(RequestBanner.deleteKey)).left),
      );
      expect(
        find.bySemanticsLabel('Sam Rivera wants to message you'),
        findsOneWidget,
      );
      handle.dispose();
    });
  });

  group('report a message (W7-18)', () {
    final peerMessageId = hexId(2);

    List<pb.Message> mixed() => [
      msg(3, secondsAgo: 5, text: 'my own words', fromSelf: true),
      msg(2, secondsAgo: 10, text: 'peer words'),
      msg(1, secondsAgo: 20, text: 'removed one').deepCopy()
        ..state = MessageState.MESSAGE_STATE_REMOVED
        ..text = '',
    ];

    Finder bubble(String id) => find.byKey(ValueKey('bubble-$id'));

    void stubReport([Future<ReportReceipt> Function()? answer]) =>
        when(
          () => moderation.report(
            idempotencyKey: any(named: 'idempotencyKey'),
            targetType: any(named: 'targetType'),
            targetId: any(named: 'targetId'),
            reason: any(named: 'reason'),
            note: any(named: 'note'),
          ),
        ).thenAnswer(
          (_) =>
              (answer ??
              () async =>
                  const ReportReceipt(reportId: 'r', alreadyReported: false))(),
        );

    Future<void> openMixed(
      WidgetTester tester, {
      Set<String> features = const {'messaging', 'graph', 'reports'},
      Brightness brightness = Brightness.light,
      Size size = const Size(400, 800),
      double textScale = 1,
    }) async {
      current = snap(mixed());
      await open(
        tester,
        features: features,
        brightness: brightness,
        size: size,
        textScale: textScale,
        onReport: reportConversationPeer,
      );
    }

    Future<void> longPressPeer(WidgetTester tester) async {
      await tester.longPress(bubble(peerMessageId));
      await tester.pumpAndSettle();
    }

    Finder sendButton() => find.widgetWithText(FilledButton, 'Send report');

    forEachThemeAndWidth('the menu and the sheet fit', (tester, env) async {
      stubReport();
      await openMixed(
        tester,
        brightness: env.brightness,
        size: env.size,
        textScale: env.textScale,
      );

      await longPressPeer(tester);
      expect(find.text(kReportMessageLabel), findsOneWidget);
      await tester.tap(find.text(kReportMessageLabel));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text("Report @sam's message"), findsOneWidget);
      expect(
        find.textContaining('Only this message is shared'),
        findsOneWidget,
      );
      expect(find.text("It's spam"), findsOneWidget);
    }, textScales: kMatrixTextScalesLarge);

    testWidgets('a long press on the peer\'s message reports it: type '
        'MESSAGE, id "<convId>:<msgId>", then a toast', (tester) async {
      stubReport();
      await openMixed(tester);
      final before = cubitOf(tester).state.messages;

      await longPressPeer(tester);
      await tester.tap(find.text(kReportMessageLabel));
      await tester.pumpAndSettle();
      await tester.tap(find.text("It's spam"));
      await tester.pump();
      await tester.ensureVisible(sendButton());
      await tester.pumpAndSettle();
      await tester.tap(sendButton());
      await tester.pumpAndSettle();

      final call = verify(
        () => moderation.report(
          idempotencyKey: any(named: 'idempotencyKey'),
          targetType: captureAny(named: 'targetType'),
          targetId: captureAny(named: 'targetId'),
          reason: ReportReason.REPORT_REASON_SPAM,
          note: any(named: 'note'),
        ),
      )..called(1);
      final type = call.captured[0] as ReportTargetType;
      expect(type, ReportTargetType.REPORT_TARGET_TYPE_MESSAGE);
      expect(type.value, 3);
      expect(call.captured[1], '$kThreadId:$peerMessageId');

      expect(find.text('Thanks for reporting'), findsOneWidget);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.text(kReportSentText), findsOneWidget);
      // The thread is as it was: same messages, nothing removed or refetched.
      expect(cubitOf(tester).state.messages, before);
      verifyNever(
        () => repo.deleteConversation(
          idempotencyKey: any(named: 'idempotencyKey'),
          conversationId: any(named: 'conversationId'),
        ),
      );
    });

    testWidgets('a secondary click opens the same menu', (tester) async {
      await openMixed(tester);

      final gesture = await tester.startGesture(
        tester.getCenter(bubble(peerMessageId)),
        buttons: kSecondaryButton,
      );
      await gesture.up();
      await tester.pumpAndSettle();

      expect(find.text(kReportMessageLabel), findsOneWidget);
    });

    testWidgets('your own message cannot be reported', (tester) async {
      await openMixed(tester);

      await tester.longPress(bubble(hexId(3)));
      await tester.pumpAndSettle();

      expect(find.text(kReportMessageLabel), findsNothing);
      verifyNever(
        () => moderation.report(
          idempotencyKey: any(named: 'idempotencyKey'),
          targetType: any(named: 'targetType'),
          targetId: any(named: 'targetId'),
          reason: any(named: 'reason'),
          note: any(named: 'note'),
        ),
      );
    });

    testWidgets('a removed message cannot be reported', (tester) async {
      await openMixed(tester);

      await tester.longPress(bubble(hexId(1)));
      await tester.pumpAndSettle();

      expect(find.text(kReportMessageLabel), findsNothing);
    });

    testWidgets('with reports off: no menu on a bubble and no Report item', (
      tester,
    ) async {
      await openMixed(tester, features: const {'messaging', 'graph'});

      await longPressPeer(tester);
      expect(find.text(kReportMessageLabel), findsNothing);

      await openMenu(tester);
      expect(find.textContaining('Report'), findsNothing);
      expect(find.text('Delete conversation'), findsOneWidget);
    });

    testWidgets('a conversation nobody can reply to can still be reported', (
      tester,
    ) async {
      current = snap(mixed(), conversation: threadConv(canReply: false));
      await open(tester);

      await longPressPeer(tester);

      expect(find.text(kReportMessageLabel), findsOneWidget);
    });

    testWidgets('dismissing the menu or the sheet sends nothing and says '
        'nothing', (tester) async {
      await openMixed(tester);

      await longPressPeer(tester);
      await tester.tapAt(const Offset(2, 2));
      await tester.pumpAndSettle();
      expect(find.text("Report @sam's message"), findsNothing);

      await longPressPeer(tester);
      await tester.tap(find.text(kReportMessageLabel));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(2, 2));
      await tester.pumpAndSettle();

      verifyNever(
        () => moderation.report(
          idempotencyKey: any(named: 'idempotencyKey'),
          targetType: any(named: 'targetType'),
          targetId: any(named: 'targetId'),
          reason: any(named: 'reason'),
          note: any(named: 'note'),
        ),
      );
      expect(find.text(kReportSentText), findsNothing);
    });

    testWidgets('a failed report keeps the sheet with a friendly line', (
      tester,
    ) async {
      stubReport(() async => throw const NotFoundException('raw-not-found'));
      await openMixed(tester);

      await longPressPeer(tester);
      await tester.tap(find.text(kReportMessageLabel));
      await tester.pumpAndSettle();
      await tester.tap(find.text("It's spam"));
      await tester.pump();
      await tester.ensureVisible(sendButton());
      await tester.pumpAndSettle();
      await tester.tap(sendButton());
      await tester.pumpAndSettle();

      expect(
        find.text("This isn't available to report any more."),
        findsOneWidget,
      );
      expect(sendButton(), findsOneWidget);
      expect(find.text(kReportSentText), findsNothing);
    });

    testWidgets('assistive tech gets a Report message action on a peer\'s '
        'bubble only', (tester) async {
      final handle = tester.ensureSemantics();
      await openMixed(tester);

      Set<String> actionsOf(String id) {
        final data = tester.getSemantics(bubble(id)).getSemanticsData();
        return {
          for (final id in data.customSemanticsActionIds ?? <int>[])
            CustomSemanticsAction.getAction(id)!.label!,
        };
      }

      expect(actionsOf(peerMessageId), contains(kReportMessageLabel));
      expect(actionsOf(hexId(3)), isNot(contains(kReportMessageLabel)));
      handle.dispose();
    });

    testWidgets('the info menu\'s Report reports the peer\'s account', (
      tester,
    ) async {
      stubReport();
      await openMixed(tester);

      await openMenu(tester);
      await tester.tap(find.text('Report @sam'));
      await tester.pumpAndSettle();
      expect(find.text('Report @sam'), findsOneWidget);
      await tester.tap(find.text("It's spam"));
      await tester.pump();
      await tester.ensureVisible(sendButton());
      await tester.pumpAndSettle();
      await tester.tap(sendButton());
      await tester.pumpAndSettle();

      final call = verify(
        () => moderation.report(
          idempotencyKey: any(named: 'idempotencyKey'),
          targetType: captureAny(named: 'targetType'),
          targetId: captureAny(named: 'targetId'),
          reason: any(named: 'reason'),
          note: any(named: 'note'),
        ),
      )..called(1);
      expect(call.captured[0], ReportTargetType.REPORT_TARGET_TYPE_ACCOUNT);
      expect(call.captured[1], 'u-sam');
    });

    testWidgets('a deleted-account peer has no user id: Report is off in the '
        'info menu', (tester) async {
      stubReport();
      final gone = threadConv().deepCopy()
        ..peer.userId = ''
        ..peer.handle = ''
        ..peer.displayName = 'Deleted account'
        ..canReply = false;
      current = snap(mixed(), conversation: gone);
      await open(tester, onReport: reportConversationPeer);

      await openMenu(tester);
      expect(find.text('Report'), findsOneWidget);
      await tester.tap(find.text('Report'), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(find.text('Send report'), findsNothing);
      verifyNever(
        () => moderation.report(
          idempotencyKey: any(named: 'idempotencyKey'),
          targetType: any(named: 'targetType'),
          targetId: any(named: 'targetId'),
          reason: any(named: 'reason'),
          note: any(named: 'note'),
        ),
      );
    });

    testWidgets('already reported: the sheet says so and no toast follows', (
      tester,
    ) async {
      stubReport(
        () async => const ReportReceipt(reportId: 'r', alreadyReported: true),
      );
      await openMixed(tester);

      await longPressPeer(tester);
      await tester.tap(find.text(kReportMessageLabel));
      await tester.pumpAndSettle();
      await tester.tap(find.text("It's spam"));
      await tester.pump();
      await tester.ensureVisible(sendButton());
      await tester.pumpAndSettle();
      await tester.tap(sendButton());
      await tester.pumpAndSettle();
      expect(find.text("You've already reported this"), findsOneWidget);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      expect(find.text(kReportSentText), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
    });

    group('keyboard', () {
      Finder ring() => find.byWidgetPredicate(
        (w) =>
            w is DecoratedBox &&
            w.position == DecorationPosition.foreground &&
            (w.decoration as BoxDecoration).border != null,
      );

      Future<void> tabToPeerBubble(WidgetTester tester) async {
        for (var i = 0; i < 40 && ring().evaluate().isEmpty; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
        }
        expect(ring(), findsOneWidget, reason: 'Tab reaches the bubble');
      }

      testWidgets('only the peer\'s visible message is a tab stop, with a '
          'visible ring', (tester) async {
        await openMixed(tester);

        // The caller's own message and the tombstone are not reportable.
        expect(find.byType(FocusableActionDetector), findsOneWidget);
        expect(ring(), findsNothing);

        await tabToPeerBubble(tester);
        final border =
            (tester.widget<DecoratedBox>(ring()).decoration as BoxDecoration)
                .border!
                .top;
        expect(
          border.color,
          Theme.of(tester.element(bubble(peerMessageId))).colorScheme.primary,
        );
        expect(border.width, 2);
      });

      for (final (name, send)
          in <(String, Future<void> Function(WidgetTester))>[
            (
              'Shift+F10',
              (tester) async {
                await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
                await tester.sendKeyEvent(LogicalKeyboardKey.f10);
                await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
              },
            ),
            (
              'the context-menu key',
              (tester) => tester.sendKeyEvent(LogicalKeyboardKey.contextMenu),
            ),
            (
              'Enter',
              (tester) => tester.sendKeyEvent(LogicalKeyboardKey.enter),
            ),
          ]) {
        testWidgets('$name on the focused bubble opens the report menu and '
            'the sheet', (tester) async {
          stubReport();
          await openMixed(tester);
          await tabToPeerBubble(tester);

          await send(tester);
          await tester.pumpAndSettle();
          expect(find.text(kReportMessageLabel), findsOneWidget);

          // The menu opens at the bubble, not at a corner of the screen.
          final item = tester.getRect(find.text(kReportMessageLabel));
          final target = tester.getRect(bubble(peerMessageId));
          expect((item.center.dy - target.center.dy).abs(), lessThan(200));

          await tester.tap(find.text(kReportMessageLabel));
          await tester.pumpAndSettle();
          expect(find.text("Report @sam's message"), findsOneWidget);
        });
      }

      testWidgets('with reports off the bubble is not a tab stop and the '
          'keys do nothing', (tester) async {
        await openMixed(tester, features: const {'messaging', 'graph'});

        expect(find.byType(FocusableActionDetector), findsNothing);
        for (var i = 0; i < 10; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
        await tester.pumpAndSettle();
        expect(find.text(kReportMessageLabel), findsNothing);
      });
    });
  });

  group('report message ids', () {
    test('the target is "<convId>:<msgId>" (32 hex each)', () {
      final m = msg(7);
      expect(messageReportTargetId(kThreadId, m), '$kThreadId:${hexId(7)}');
      expect(messageReportTargetId(kThreadId, m), hasLength(65));
    });

    test('your own, removed and badly-shaped ones are refused', () {
      expect(
        () => messageReportTargetId(kThreadId, msg(7, fromSelf: true)),
        throwsArgumentError,
      );
      expect(canReportMessage(msg(7, fromSelf: true)), isFalse);
      final removed = msg(7).deepCopy()
        ..state = MessageState.MESSAGE_STATE_REMOVED;
      expect(canReportMessage(removed), isFalse);
      final deleted = msg(7).deepCopy()
        ..state = MessageState.MESSAGE_STATE_DELETED_ACCOUNT;
      expect(canReportMessage(deleted), isFalse);
      expect(() => messageReportTargetId('c1', msg(7)), throwsArgumentError);
      final odd = msg(7).deepCopy()..id = 'ABC';
      expect(() => messageReportTargetId(kThreadId, odd), throwsArgumentError);
      expect(canReportMessage(msg(7)), isTrue);
    });
  });
}
