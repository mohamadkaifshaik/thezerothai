import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart';
import 'package:dzeroth/core/network/rate_limit_hold.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/messages/data/message_outbox.dart';
import 'package:dzeroth/features/messages/data/messaging_repository.dart';
import 'package:dzeroth/features/messages/data/messaging_store.dart';
import 'package:dzeroth/features/messages/domain/thread_poller.dart';
import 'package:dzeroth/features/messages/presentation/thread_screen.dart';
import 'package:dzeroth/features/messages/presentation/widgets/message_bubble.dart';
import 'package:dzeroth/features/moderation/data/moderation_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as posts;
import 'package:dzeroth/shared/widgets/post/embedded_post_card.dart';
import 'package:dzeroth/shared/widgets/post/unavailable_post_box.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/messaging_fixtures.dart';
import '../../../support/messaging_shell_rig.dart';
import '../../../support/theme_harness.dart';
import '../../../support/thread_test_support.dart';

class _MockMessaging extends Mock implements MessagingRepository {
  @override
  final MessageOutbox outbox = MessageOutbox();
}

class _MockGraph extends Mock implements GraphRepository {}

class _MockModeration extends Mock implements ModerationRepository {}

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

const _postId = '1234567890123456789';
const _url = 'https://dzeroth.com/post/$_postId';

posts.EmbeddedPost _card({bool unavailable = false}) => unavailable
    ? posts.EmbeddedPost(postId: _postId, unavailable: true)
    : posts.EmbeddedPost(
        postId: _postId,
        text: 'the original words',
        author: common.AuthorSnapshot(
          userId: 'u9',
          handle: 'writer',
          displayName: 'Wren Writer',
        ),
      );

pb.Message _shared(
  int n, {
  String text = _url,
  bool fromSelf = false,
  bool unavailable = false,
  int secondsAgo = 0,
}) =>
    msg(n, text: text, fromSelf: fromSelf, secondsAgo: secondsAgo)
      ..sharedPost = _card(unavailable: unavailable);

void main() {
  late _MockMessaging repo;
  late _MockOnboarding onboarding;
  late MessagingShellRig rig;
  late FakeThreadPoller poller;
  late ThreadSnapshot current;
  late List<String> visited;

  ThreadSnapshot snap(List<pb.Message> messages, {pb.Conversation? header}) =>
      ThreadSnapshot(
        messages: messages,
        conversation: header ?? threadConv(),
        sinceToken: 's',
      );

  setUp(() {
    rig = MessagingShellRig();
    repo = _MockMessaging();
    onboarding = _MockOnboarding();
    poller = FakeThreadPoller();
    current = snap([_shared(1)]);
    when(() => repo.rateLimitedFor()).thenReturn(null);
    when(() => repo.conversationsChanged)
        .thenAnswer((_) => const Stream<void>.empty());
    when(() => repo.cachedConversation(any())).thenAnswer((_) async => null);
    when(() => repo.noteSentRequestAnswered(any())).thenAnswer((_) async {});
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
    when(() => repo.dropBlockedRequest(any())).thenAnswer((_) async {});
  });

  /// The thread screen, with [features] from `GetMe` and a `/post/:id` route
  /// that records what a tapped card opens.
  Future<void> open(
    WidgetTester tester, {
    Set<String> features = const {'messaging'},
    Size size = const Size(390, 800),
    Brightness brightness = Brightness.light,
    double textScale = 1,
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
            conversationId: kThreadId,
            now: kMsgBase.add(const Duration(minutes: 1)),
            onOpenLink: (uri) => visited.add('link:$uri'),
            pollerBuilder: (p, _) => poller,
          ),
        ),
        GoRoute(
          path: '/post/:id',
          builder: (context, state) {
            visited.add('post:${state.pathParameters['id']}');
            return const Scaffold(body: Text('post page'));
          },
        ),
        GoRoute(
          path: '/messages',
          builder: (context, state) => const Scaffold(body: Text('inbox')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<MessagingRepository>.value(value: repo),
          RepositoryProvider<GraphRepository>.value(value: _MockGraph()),
          RepositoryProvider<ModerationRepository>.value(
            value: _MockModeration(),
          ),
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
    await tester.pumpAndSettle();
  }

  group('by flag mode: the card comes from the message, not from a flag', () {
    // A recipient outside the dm_post_share rollout still sees the card; only
    // sending needs the flag. Nothing here reads share_count either.
    final modes = <String, Set<String>>{
      'messaging only': {'messaging'},
      'messaging + dm_post_share': {'messaging', 'dm_post_share'},
      'messaging + share_count': {'messaging', 'share_count'},
      'all three': {'messaging', 'dm_post_share', 'share_count'},
    };
    for (final entry in modes.entries) {
      testWidgets(entry.key, (tester) async {
        current = snap([_shared(2, text: 'you will like this'), _shared(1)]);
        await open(tester, features: entry.value);

        expect(find.byKey(kSharedPostCardKey), findsNWidgets(2));
        expect(find.text('you will like this'), findsOneWidget);
        // The post link is hidden behind each card.
        expect(find.textContaining('dzeroth.com'), findsNothing);
      });
    }
  });

  group('at 390 / 1024 / 1440 dp, light and dark, text x1 and x2', () {
    forEachThemeAndWidth(
      'cards, captions, the unavailable form and an old-client link fit',
      (tester, env) async {
        current = snap([
          msg(5, secondsAgo: 10, text: _url, fromSelf: true),
          _shared(4, fromSelf: true, unavailable: true, secondsAgo: 20),
          _shared(3, text: 'a caption that is a little longer', secondsAgo: 30),
          _shared(2, secondsAgo: 40),
          msg(1, secondsAgo: 50, text: 'plain'),
        ]);
        await open(
          tester,
          // Tall enough that the lazy list builds every row at text x2.
          size: Size(env.size.width, 2400),
          brightness: env.brightness,
          textScale: env.textScale,
        );

        expect(tester.takeException(), isNull);
        // Two live cards and one unavailable form; the old-client message is
        // the only place the link text is still drawn.
        expect(find.byType(EmbeddedPostCard), findsNWidgets(3));
        expect(find.byType(UnavailablePostBox), findsOneWidget);
        expect(find.text(_url), findsOneWidget);
      },
      widths: const [390, 1024, 1440],
      textScales: const [1.0, 2.0],
    );
  });

  group('a message that only carries a link (an older client sent it)', () {
    testWidgets('renders as a tappable link, with no card', (tester) async {
      current = snap([msg(1, text: _url)]);
      await open(tester);

      expect(find.byKey(kSharedPostCardKey), findsNothing);
      expect(find.text(_url), findsOneWidget);
      expect(find.byType(MessageText), findsOneWidget);
    });

    testWidgets('in a request not yet accepted the link is plain text', (
      tester,
    ) async {
      current = snap(
        [msg(1, text: _url)],
        header: threadConv(
          state: ConversationState.CONVERSATION_STATE_REQUEST,
          folder: Folder.FOLDER_REQUESTS,
        ),
      );
      await open(tester);

      final rich = tester.widget<RichText>(
        find
            .descendant(
              of: find.byType(MessageText),
              matching: find.byType(RichText),
            )
            .first,
      );
      var linked = 0;
      rich.text.visitChildren((s) {
        if (s is TextSpan && s.recognizer != null) linked++;
        return true;
      });
      expect(linked, 0);
    });

    testWidgets('a new client with the card in a request still opens the post '
        'in the app', (tester) async {
      current = snap(
        [_shared(1)],
        header: threadConv(
          state: ConversationState.CONVERSATION_STATE_REQUEST,
          folder: Folder.FOLDER_REQUESTS,
        ),
      );
      await open(tester);

      await tester.tap(find.byType(EmbeddedPostCard));
      await tester.pumpAndSettle();
      expect(visited, ['post:$_postId']);
    });
  });

  testWidgets('tapping a card opens /post/<id>', (tester) async {
    await open(tester);
    await tester.tap(find.byType(EmbeddedPostCard));
    await tester.pumpAndSettle();

    expect(visited, ['post:$_postId']);
    expect(find.text('post page'), findsOneWidget);
  });

  testWidgets('an unavailable card opens nothing', (tester) async {
    current = snap([_shared(1, unavailable: true)]);
    await open(tester);
    await tester.tap(find.byType(UnavailablePostBox));
    await tester.pumpAndSettle();
    expect(visited, isEmpty);
  });

  testWidgets('a removed message has no card', (tester) async {
    final tomb = _shared(1, text: '')
      ..state = MessageState.MESSAGE_STATE_REMOVED;
    current = snap([tomb]);
    await open(tester);

    expect(find.byKey(kSharedPostCardKey), findsNothing);
    expect(find.text('This message was removed'), findsOneWidget);
  });
}
