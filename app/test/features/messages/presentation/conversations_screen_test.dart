import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/messages/data/messaging_repository.dart';
import 'package:dzeroth/features/messages/data/messaging_store.dart';
import 'package:dzeroth/features/messages/presentation/conversations_screen.dart';
import 'package:dzeroth/features/messages/presentation/widgets/conversation_row.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:dzeroth/shared/widgets/app_empty_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/messaging_fixtures.dart';
import '../../../support/messaging_shell_rig.dart';
import '../../../support/theme_harness.dart';

class MockMessagingRepository extends Mock implements MessagingRepository {}

class MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

void main() {
  late MockMessagingRepository repo;
  late MockOnboardingBloc onboarding;
  late MessagingShellRig rig;
  late List<String> visited;

  ConversationsSnapshot snap(List<pb.Conversation> rows, {bool more = false}) =>
      ConversationsSnapshot(
        conversations: rows,
        sinceToken: 's',
        olderPageToken: more ? 'older' : '',
      );

  setUpAll(() {
    registerFallbackValue(Folder.FOLDER_INBOX);
  });

  setUp(() {
    rig = MessagingShellRig();
    repo = MockMessagingRepository();
    onboarding = MockOnboardingBloc();
    visited = [];
    when(() => repo.rateLimitedFor()).thenReturn(null);
    when(() => repo.conversationsChanged)
        .thenAnswer((_) => const Stream<void>.empty());
    when(() => repo.cachedConversations(any()))
        .thenAnswer((_) async => const ConversationsSnapshot());
    when(() => repo.refreshConversations(any())).thenAnswer(
      (_) async => const ConversationsResult(ConversationsSnapshot()),
    );
  });

  /// Stubs one folder: [cached] on disk, [network] after the refresh.
  void stub({
    List<pb.Conversation>? cached,
    List<pb.Conversation>? network,
    int? requestCount,
    Folder folder = Folder.FOLDER_INBOX,
    bool more = false,
  }) {
    when(() => repo.cachedConversations(folder)).thenAnswer(
      (_) async =>
          cached == null ? const ConversationsSnapshot() : snap(cached),
    );
    when(() => repo.refreshConversations(folder)).thenAnswer(
      (_) async => ConversationsResult(
        snap(network ?? cached ?? const [], more: more),
        requestCount: requestCount,
      ),
    );
  }

  Future<void> open(
    WidgetTester tester, {
    Set<String> features = const {'messaging'},
    Folder folder = Folder.FOLDER_INBOX,
    Brightness brightness = Brightness.light,
    Size size = const Size(400, 800),
    double textScale = 1,
    void Function(String)? onOpenConversation,
    VoidCallback? onNewMessage,
    bool settle = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(enabledFeatures: features),
    );
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => ConversationsScreen(
            folder: folder,
            onOpenConversation: onOpenConversation,
            onNewMessage: onNewMessage,
          ),
        ),
        GoRoute(
          path: '/messages',
          builder: (context, state) => const Scaffold(body: Text('inbox page')),
        ),
        GoRoute(
          path: '/messages/requests',
          builder: (context, state) {
            visited.add(state.uri.path);
            return const Scaffold(body: Text('requests page'));
          },
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<MessagingRepository>.value(value: repo),
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

  group('cache first', () {
    testWidgets('cached conversations render before the network answers', (
      tester,
    ) async {
      final network = Completer<ConversationsResult>();
      when(() => repo.cachedConversations(Folder.FOLDER_INBOX))
          .thenAnswer((_) async => snap([conv('a', snippet: 'cached hello')]));
      when(() => repo.refreshConversations(Folder.FOLDER_INBOX))
          .thenAnswer((_) => network.future);

      await open(tester, settle: false);
      await tester.pump();

      expect(find.text('cached hello'), findsOneWidget);
      expect(find.byType(ConversationRow), findsOneWidget);

      network.complete(
        ConversationsResult(
          snap([
            conv('b', snippet: 'fresh hello'),
            conv('a', snippet: 'cached hello'),
          ]),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ConversationRow), findsNWidgets(2));
      expect(find.text('fresh hello'), findsOneWidget);
    });

    testWidgets('opening sends one refresh and never a periodic poll', (
      tester,
    ) async {
      stub(cached: [conv('a', snippet: 'hi')]);

      await open(tester);
      await tester.pump(const Duration(minutes: 10));

      verify(() => repo.refreshConversations(Folder.FOLDER_INBOX)).called(1);
    });

    testWidgets('a resume inside the 60 s window sends nothing', (
      tester,
    ) async {
      stub(cached: [conv('a', snippet: 'hi')]);
      await open(tester);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      verify(() => repo.refreshConversations(Folder.FOLDER_INBOX)).called(1);
    });
  });

  group('rows', () {
    testWidgets('an unread row is bold, has the dot and says "unread"', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      stub(
        cached: [
          conv('a', snippet: 'new one', unread: 3),
          conv('b', snippet: 'old one', fromSelf: true, minutesAgo: 5),
        ],
      );

      await open(tester);

      expect(find.byKey(ConversationRow.unreadDotKey), findsOneWidget);
      expect(
        tester.widget<Text>(find.text('new one')).style?.fontWeight,
        FontWeight.w700,
      );
      expect(find.text('You: old one'), findsOneWidget);
      expect(
        tester.getSemantics(find.byKey(const ValueKey('conversation-a'))).label,
        contains('unread'),
      );
      expect(
        tester.getSemantics(find.byKey(const ValueKey('conversation-b'))).label,
        isNot(contains('unread')),
      );
      handle.dispose();
    });

    testWidgets('the rows are the items of one list', (tester) async {
      final handle = tester.ensureSemantics();
      stub(
        cached: [
          conv('a', snippet: 'one'),
          conv('b', snippet: 'two'),
        ],
      );

      await open(tester);

      final list = tester.getSemantics(find.bySemanticsLabel('Conversations'));
      expect(list.getSemanticsData().role, SemanticsRole.list);
      for (final id in ['a', 'b']) {
        final item = tester.getSemantics(
          find.byKey(ValueKey('conversation-$id')),
        );
        expect(item.getSemanticsData().role, SemanticsRole.listItem);
      }
      expect(tester.takeException(), isNull);
      handle.dispose();
    });

    testWidgets('tapping a row opens its conversation when a route is wired', (
      tester,
    ) async {
      stub(cached: [conv('a', snippet: 'one')]);
      final opened = <String>[];

      await open(tester, onOpenConversation: opened.add);
      await tester.tap(find.text('one'));

      expect(opened, ['a']);
    });

    testWidgets('rows are not buttons while no conversation route exists', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      stub(cached: [conv('a', snippet: 'one')]);

      await open(tester);

      expect(
        tester
            .getSemantics(find.byKey(const ValueKey('conversation-a')))
            .getSemanticsData()
            .hasAction(SemanticsAction.tap),
        isFalse,
      );
      handle.dispose();
    });
  });

  group('Message requests row', () {
    testWidgets('shows "Message requests (2)" and opens the folder', (
      tester,
    ) async {
      stub(cached: [conv('a', snippet: 'one')], requestCount: 2);

      await open(tester);

      expect(find.text('Message requests (2)'), findsOneWidget);
      await tester.tap(find.text('Message requests (2)'));
      await tester.pumpAndSettle();

      expect(visited, ['/messages/requests']);
      expect(find.text('requests page'), findsOneWidget);
    });

    testWidgets('is a button for screen readers', (tester) async {
      final handle = tester.ensureSemantics();
      stub(cached: [conv('a', snippet: 'one')], requestCount: 2);

      await open(tester);

      final data = tester
          .getSemantics(find.bySemanticsLabel('Message requests (2)'))
          .getSemanticsData();
      expect(data.flagsCollection.isButton, isTrue);
      expect(data.hasAction(SemanticsAction.tap), isTrue);
      handle.dispose();
    });

    testWidgets('is hidden for 0 and for an unknown count', (tester) async {
      stub(cached: [conv('a', snippet: 'one')], requestCount: 0);
      await open(tester);
      expect(find.textContaining('Message requests'), findsNothing);

      stub(cached: [conv('a', snippet: 'one')]);
      await open(tester);
      expect(find.textContaining('Message requests'), findsNothing);
    });

    testWidgets('shows even when the inbox itself is empty', (tester) async {
      stub(requestCount: 4);

      await open(tester);

      expect(find.text('Message requests (4)'), findsOneWidget);
      expect(find.text('Welcome to your inbox'), findsOneWidget);
    });
  });

  group('requests folder', () {
    testWidgets('lists the REQUESTS folder under a back header', (
      tester,
    ) async {
      stub(
        folder: Folder.FOLDER_REQUESTS,
        cached: [
          conv('r1', snippet: 'hello stranger', folder: Folder.FOLDER_REQUESTS),
        ],
      );

      await open(tester, folder: Folder.FOLDER_REQUESTS);

      expect(find.text('Message requests'), findsOneWidget);
      expect(find.text('hello stranger'), findsOneWidget);
      expect(find.byTooltip('Back'), findsOneWidget);
      expect(find.byTooltip('New message'), findsNothing);
      verifyNever(() => repo.refreshConversations(Folder.FOLDER_INBOX));
    });

    testWidgets('Back goes to the inbox when nothing is below it', (
      tester,
    ) async {
      stub(folder: Folder.FOLDER_REQUESTS);

      await open(tester, folder: Folder.FOLDER_REQUESTS);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();

      expect(find.text('inbox page'), findsOneWidget);
    });

    testWidgets('empty: its own copy', (tester) async {
      stub(folder: Folder.FOLDER_REQUESTS);

      await open(tester, folder: Folder.FOLDER_REQUESTS);

      expect(find.text('No message requests'), findsOneWidget);
    });
  });

  group('New message action', () {
    testWidgets('is shown disabled until /messages/new exists (W7-17)', (
      tester,
    ) async {
      stub(cached: [conv('a', snippet: 'one')]);

      await open(tester);

      final button = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.mail_outline),
      );
      expect(button.onPressed, isNull);
      expect(find.byTooltip('New message'), findsOneWidget);
    });

    testWidgets('calls the callback once it is wired', (tester) async {
      stub(cached: [conv('a', snippet: 'one')]);
      var taps = 0;

      await open(tester, onNewMessage: () => taps++);
      await tester.tap(find.byTooltip('New message'));

      expect(taps, 1);
    });
  });

  group('states', () {
    testWidgets('empty inbox: our own welcome copy', (tester) async {
      stub();

      await open(tester);

      expect(find.byType(AppEmptyView), findsOneWidget);
      expect(find.text('Welcome to your inbox'), findsOneWidget);
      expect(find.text('Start a conversation'), findsOneWidget);
    });

    testWidgets('loading: a skeleton announced once', (tester) async {
      final handle = tester.ensureSemantics();
      final never = Completer<ConversationsResult>();
      when(() => repo.refreshConversations(Folder.FOLDER_INBOX))
          .thenAnswer((_) => never.future);

      await open(tester, settle: false);
      await tester.pump();

      expect(find.bySemanticsLabel('Loading conversations'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('offline with nothing cached: friendly text and Retry', (
      tester,
    ) async {
      when(() => repo.refreshConversations(Folder.FOLDER_INBOX))
          .thenThrow(const NetworkException('offline'));

      await open(tester);

      expect(find.textContaining('No connection'), findsOneWidget);
      expect(find.text('offline'), findsNothing);

      when(() => repo.refreshConversations(Folder.FOLDER_INBOX)).thenAnswer(
        (_) async => ConversationsResult(snap([conv('a', snippet: 'back')])),
      );
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(find.text('back'), findsOneWidget);
    });

    testWidgets('a failed refresh over cached rows keeps them under a banner', (
      tester,
    ) async {
      when(() => repo.cachedConversations(Folder.FOLDER_INBOX))
          .thenAnswer((_) async => snap([conv('a', snippet: 'saved')]));
      when(() => repo.refreshConversations(Folder.FOLDER_INBOX))
          .thenThrow(const NetworkException('offline'));

      await open(tester);

      expect(find.text('saved'), findsOneWidget);
      expect(
        find.text("You're offline. Showing saved messages."),
        findsOneWidget,
      );
    });

    testWidgets('a rate limit has no Retry', (tester) async {
      when(() => repo.refreshConversations(Folder.FOLDER_INBOX)).thenThrow(
        const RateLimitedException('x', retryAfter: Duration(minutes: 1)),
      );

      await open(tester);

      expect(find.text('Retry'), findsNothing);
    });

    testWidgets('with the flag off the screen says it is not available', (
      tester,
    ) async {
      await open(tester, features: const {});

      expect(find.text("Messages aren't available yet"), findsOneWidget);
      verifyNever(() => repo.refreshConversations(any()));
    });
  });

  group('refresh and paging', () {
    testWidgets('pull-to-refresh sends one more refresh', (tester) async {
      stub(cached: [conv('a', snippet: 'one')]);
      await open(tester);

      await tester.fling(find.text('one'), const Offset(0, 400), 1000);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();

      verify(() => repo.refreshConversations(Folder.FOLDER_INBOX)).called(2);
    });

    testWidgets('scrolling near the end loads the next page once', (
      tester,
    ) async {
      final rows = [
        for (var i = 0; i < 20; i++) conv('c$i', snippet: 's$i', minutesAgo: i),
      ];
      stub(cached: rows, more: true);
      when(() => repo.loadOlderConversations(Folder.FOLDER_INBOX)).thenAnswer(
        (_) async => snap([
          ...rows,
          for (var i = 20; i < 30; i++)
            conv('c$i', snippet: 's$i', minutesAgo: i),
        ]),
      );
      await open(tester);

      await tester.drag(find.byType(CustomScrollView), const Offset(0, -1400));
      await tester.pumpAndSettle();

      verify(() => repo.loadOlderConversations(Folder.FOLDER_INBOX)).called(1);
    });
  });

  group('responsive matrix', () {
    forEachThemeAndWidth(
      'inbox with requests row, unread, silent and tombstone fits',
      (tester, env) async {
        stub(
          cached: [
            conv('a', snippet: 'A long message ' * 12, unread: 2, silent: true),
            conv('b', snippet: 'short', fromSelf: true, minutesAgo: 90),
            conv(
              'c',
              snippet: '',
              lastState: MessageState.MESSAGE_STATE_REMOVED,
              minutesAgo: 3000,
            ),
          ],
          requestCount: 2,
        );

        await open(
          tester,
          brightness: env.brightness,
          size: env.size,
          textScale: env.textScale,
        );

        expect(tester.takeException(), isNull);
        expect(find.text('Message requests (2)'), findsOneWidget);
        expect(find.byType(ConversationRow), findsNWidgets(3));
        // The main column never grows past 600dp, also at 1200 (no
        // master-detail in v1).
        expect(
          tester.getSize(find.byType(ConversationRow).first).width,
          lessThanOrEqualTo(600),
        );
        if (env.size.width >= 1200) {
          expect(tester.getTopLeft(find.byType(ConversationRow).first).dx, 300);
        }
      },
      textScales: kMatrixTextScalesLarge,
    );
  });
}
