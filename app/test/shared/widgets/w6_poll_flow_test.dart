import 'package:bloc_test/bloc_test.dart';
import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/feature_flags/service_feature_gate.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/engagement/data/engagement_repository.dart';
import 'package:dzeroth/features/engagement/data/poll_repository.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/engagement_cubit.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/poll_cubit.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/domain/composer_draft.dart';
import 'package:dzeroth/features/posts/domain/poll_rules.dart';
import 'package:dzeroth/features/posts/presentation/widgets/composer_extras_buttons.dart';
import 'package:dzeroth/features/posts/presentation/widgets/composer_poll_builder.dart';
import 'package:dzeroth/features/timeline/presentation/widgets/feed_post_row.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/engagement/v1/engagement.pb.dart' as eng;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart'
    show ReplyPolicy;
import 'package:dzeroth/shared/widgets/app_pill_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/fake_drafts_repository.dart';
import '../../support/fake_transport.dart';
import '../../support/media_fixtures.dart';
import '../../support/poll_fixtures.dart';
import '../../support/posts_fixtures.dart';
import '../../support/theme_harness.dart';
import '../../support/w6_composer_rig.dart';

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockGraph extends Mock implements GraphRepository {}

class _MockPosts extends Mock implements PostsRepository {}

class _MockEngagement extends Mock implements EngagementRepository {}

/// W6-19: the poll card inside real feed rows (`FeedPostRow` -> `PostCard` ->
/// `PostPoll` -> `PollCubit` -> `PollRepository` -> transport), the error
/// paths the unit tests leave out, and the cross-screen flow compose -> post
/// -> card -> vote -> results.
void main() {
  late FakeTransport transport;
  late List<eng.VotePollRequest> votes;
  late Object Function() answer;
  late PollCubit cubit;
  late PollRepository repo;

  setUpAll(() {
    registerFallbackValue(const OnboardingUserSignedOut());
    registerMediaFallbacks();
    registerFallbackValue(newDraftPoll());
    registerFallbackValue(ReplyPolicy.REPLY_POLICY_UNSPECIFIED);
  });

  setUp(() {
    votes = [];
    answer = () => throw StateError('unscripted');
    transport = FakeTransport((procedure, input) async {
      if (input is eng.VotePollRequest) votes.add(input);
      final r = answer();
      if (r is Exception) throw r;
      return r;
    });
    repo = PollRepository(
      apiClient: ApiClient.withTransport(transport),
      gate: ServiceFeatureGate(isEnabled: () => true),
      readPost: (_) async {
        return pollPostView(
          1,
          poll: pollOf(votes: [2, 1, 0], total: 3, visible: true, closed: true),
        );
      },
    );
    cubit = PollCubit(repository: repo);
  });

  late EngagementCubit engagement;
  setUp(() => engagement = EngagementCubit(repository: _MockEngagement()));
  tearDown(() async {
    await cubit.close();
    await engagement.close();
  });

  OnboardingBloc onboarding({Set<String> features = const {'engagement'}}) {
    final b = _MockOnboarding();
    whenListen(
      b,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        enabledFeatures: features,
      ),
    );
    return b;
  }

  GraphRepository graph() {
    final g = _MockGraph();
    when(() => g.cached(any())).thenReturn(null);
    return g;
  }

  /// A feed of real rows. A tap on a row opens `/post/:id` (a stub page).
  Future<void> pumpFeed(
    WidgetTester tester,
    List<pb.PostView> views, {
    String viewer = 'viewer',
    Size size = const Size(390, 900),
    Brightness brightness = Brightness.light,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => Scaffold(
            body: ListView(
              children: [
                for (final v in views)
                  FeedPostRow(
                    view: v,
                    viewerUserId: viewer,
                    now: kPollNow,
                    graphEnabled: false,
                    reportsEnabled: false,
                    engagementEnabled: true,
                  ),
              ],
            ),
          ),
        ),
        GoRoute(
          path: '/post/:id',
          builder: (context, state) =>
              const Scaffold(body: Text('post detail page')),
        ),
      ],
    );
    await tester.pumpWidget(
      RepositoryProvider<GraphRepository>.value(
        value: graph(),
        child: MultiBlocProvider(
          providers: [
            BlocProvider<OnboardingBloc>.value(value: onboarding()),
            BlocProvider<PollCubit>.value(value: cubit),
            BlocProvider<EngagementCubit>.value(value: engagement),
          ],
          child: MaterialApp.router(
            routerConfig: router,
            theme: buildAppTheme(brightness: brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder choice(int i) => find.byKey(ValueKey('poll-choice-$i'));
  pb.PostView open({int n = 1, String authorId = 'u1'}) => pollPostView(
    n,
    poll: pollOf(labels: const ['Red', 'Green', 'Blue'], total: 5),
    authorId: authorId,
  );
  eng.VotePollResponse committed({int total = 6, int chosen = 2}) =>
      eng.VotePollResponse(
        post: pollPostView(
          1,
          poll: pollOf(votes: [3, 2, 1], total: total, visible: true),
          choice: chosen,
        ),
      );

  group('in a real feed row', () {
    testWidgets('a poll row between plain rows: a tap votes once and does '
        'not open the post', (tester) async {
      answer = () => committed();
      await pumpFeed(tester, [
        postView(5, text: 'plain above'),
        open(),
        postView(6, text: 'plain below'),
      ]);
      expect(choice(0), findsOneWidget);
      expect(find.text('5 votes · 2 days left'), findsOneWidget);

      await tester.tap(choice(1));
      await tester.pumpAndSettle();

      expect(votes, hasLength(1));
      expect(votes.single.choiceIndex, 1);
      expect(votes.single.postId, postId(1));
      expect(votes.single.idempotencyKey, isNotEmpty);
      expect(find.text('post detail page'), findsNothing);
      expect(find.text('6 votes · 2 days left'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(
        find.byKey(const ValueKey('poll-change-vote')),
        findsOneWidget,
        reason: 'a vote is no longer final (Amendment 1)',
      );
      expect(find.text('plain above'), findsOneWidget);
      expect(find.text('plain below'), findsOneWidget);
    });

    testWidgets('the question text still opens the post', (tester) async {
      await pumpFeed(tester, [open()]);
      await tester.tap(find.text('Pick one'));
      await tester.pumpAndSettle();
      expect(find.text('post detail page'), findsOneWidget);
      expect(votes, isEmpty);
    });

    testWidgets('the author sees the card without buttons in the feed', (
      tester,
    ) async {
      await pumpFeed(tester, [open(authorId: 'viewer')]);
      expect(choice(0), findsOneWidget);
      expect(
        find.descendant(of: choice(0), matching: find.byType(OutlinedButton)),
        findsNothing,
      );
      await tester.tap(choice(0), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(votes, isEmpty);
      expect(find.text('post detail page'), findsOneWidget);
    });

    testWidgets('two cards of one poll (feed and a second list) show the new '
        'total after one vote', (tester) async {
      // The footer total is the poll's "member count": the same poll in two
      // places must not disagree after a vote.
      answer = () => committed(total: 9);
      await pumpFeed(tester, [open(), open()]);
      expect(find.text('5 votes · 2 days left'), findsNWidgets(2));

      await tester.tap(choice(0).first);
      await tester.pumpAndSettle();

      expect(votes, hasLength(1));
      expect(find.text('9 votes · 2 days left'), findsNWidgets(2));
      expect(find.byIcon(Icons.check_circle), findsNWidgets(2));
      expect(
        find.byKey(const ValueKey('poll-change-vote')),
        findsNWidgets(2),
        reason: 'a vote is no longer final: both cards offer Change vote',
      );
    });
  });

  group('error paths in the feed row', () {
    testWidgets('VALIDATION: the fallback line, the buttons come back, the '
        'same choice keeps its key and another choice gets its own', (
      tester,
    ) async {
      answer = () => rejectedToken('choice_index');
      await pumpFeed(tester, [open()]);

      await tester.tap(choice(0));
      await tester.pumpAndSettle();
      expect(
        find.text("Couldn't register your vote. Please try again."),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.check_circle), findsNothing);

      await tester.tap(choice(0));
      await tester.pumpAndSettle();
      await tester.tap(choice(1));
      await tester.pumpAndSettle();

      expect(votes, hasLength(3));
      expect(votes[0].idempotencyKey, votes[1].idempotencyKey);
      expect(votes[2].idempotencyKey, isNot(votes[0].idempotencyKey));
      expect(votes[2].choiceIndex, 1);
    });

    testWidgets('UNAVAILABLE: a retry reuses the key, then the vote lands', (
      tester,
    ) async {
      answer = () => connect.ConnectException(connect.Code.unavailable, 'x');
      await pumpFeed(tester, [open()]);
      await tester.tap(choice(2));
      await tester.pumpAndSettle();
      expect(
        find.text('No connection. Check your network and try again.'),
        findsOneWidget,
      );

      answer = () => committed();
      await tester.tap(choice(2));
      await tester.pumpAndSettle();

      expect(votes, hasLength(2));
      expect(votes[1].idempotencyKey, votes[0].idempotencyKey);
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
    });

    testWidgets('UNAVAILABLE carrying DEGRADED_MODE reads as paused voting', (
      tester,
    ) async {
      answer = () => serverError(
        connect.Code.unavailable,
        common.ErrorReason.ERROR_REASON_DEGRADED_MODE,
      );
      await pumpFeed(tester, [open()]);
      await tester.tap(choice(0));
      await tester.pumpAndSettle();
      expect(find.textContaining('limited mode'), findsOneWidget);
      expect(find.textContaining('voting is paused'), findsOneWidget);
      // Voting is not switched off for the session: the buttons stay.
      expect(choice(0), findsOneWidget);
    });

    testWidgets('UNIMPLEMENTED (VotePoll not deployed): no buttons and one '
        'line; after flagsChanged and a deploy the vote works', (tester) async {
      answer = () => connect.ConnectException(connect.Code.unimplemented, 'no');
      await pumpFeed(tester, [open()]);
      await tester.tap(choice(0));
      await tester.pumpAndSettle();
      expect(find.text("Voting isn't available right now."), findsOneWidget);
      expect(cubit.votingOff, isTrue);
      expect(
        find.descendant(of: choice(0), matching: find.byType(OutlinedButton)),
        findsNothing,
      );
      await tester.tap(choice(0), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(votes, hasLength(1), reason: 'nothing more is sent');
      // A tap on a read-only choice opens the post, like any row tap.
      expect(find.text('post detail page'), findsOneWidget);
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await tester.pumpAndSettle();

      // The next GetMe changes the flag set: the server decides again.
      cubit.flagsChanged();
      await tester.pumpAndSettle();
      answer = () => committed();
      await tester.pumpAndSettle();
      await tester.tap(choice(0));
      await tester.pumpAndSettle();
      expect(votes, hasLength(2));
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(find.text('6 votes · 2 days left'), findsOneWidget);
    });
  });

  group('responsive matrix: real feed rows with a poll', () {
    forEachThemeAndWidth('vote, results and sending states fit', (
      tester,
      env,
    ) async {
      await pumpFeed(
        tester,
        [
          pollPostView(
            1,
            poll: pollOf(
              labels: ['A' * 25, '😀' * 25, 'مرحبا بالعالم الجميل', 'D'],
              total: 123456789,
            ),
          ),
          pollPostView(
            2,
            poll: pollOf(
              labels: ['A' * 25, 'B', 'C'],
              votes: const [123456, 99999, 1],
              total: 223456,
              visible: true,
            ),
            choice: 2,
          ),
        ],
        size: env.size,
        brightness: env.brightness,
        textScale: env.textScale,
      );
      expect(tester.takeException(), isNull);
      expect(find.textContaining('123M votes'), findsOneWidget);
    }, textScales: kMatrixTextScalesLarge);
  });

  group('compose a poll -> post -> card -> vote -> results', () {
    testWidgets('the whole flow over real repositories', (tester) async {
      final posts = _MockPosts();
      when(() => posts.subFeatureEnabled(any())).thenReturn(true);
      DraftPoll? sentPoll;
      String? sentText;
      final created = ValueNotifier<pb.PostView?>(null);
      final viewer = ValueNotifier<String>('uid-1');
      when(
        () => posts.createPost(
          idempotencyKey: any(named: 'idempotencyKey'),
          text: any(named: 'text'),
          replyToPostId: any(named: 'replyToPostId'),
          quoteOfPostId: any(named: 'quoteOfPostId'),
          mediaIds: any(named: 'mediaIds'),
          mediaAltTexts: any(named: 'mediaAltTexts'),
          replyPolicy: any(named: 'replyPolicy'),
          poll: any(named: 'poll'),
        ),
      ).thenAnswer((invocation) async {
        sentPoll = invocation.namedArguments[#poll] as DraftPoll?;
        sentText = invocation.namedArguments[#text] as String;
        final view = pollPostView(
          1,
          poll: pollOf(labels: const ['Red', 'Blue'], total: 0),
          authorId: 'uid-1',
        );
        view.post.text = sentText!;
        created.value = view;
        return view;
      });

      final rig = await pumpW6Composer(
        tester,
        posts: posts,
        drafts: FakeDraftsRepository(),
        home: (context) => Scaffold(
          body: ValueListenableBuilder<pb.PostView?>(
            valueListenable: created,
            builder: (context, view, _) => view == null
                ? const Text('home page')
                : ValueListenableBuilder<String>(
                    valueListenable: viewer,
                    builder: (context, who, _) => SingleChildScrollView(
                      child: FeedPostRow(
                        view: view,
                        viewerUserId: who,
                        now: kPollNow,
                        graphEnabled: false,
                        reportsEnabled: false,
                        engagementEnabled: true,
                      ),
                    ),
                  ),
          ),
        ),
        wrapApp: (app) => RepositoryProvider<GraphRepository>.value(
          value: graph(),
          child: MultiBlocProvider(
            providers: [
              BlocProvider<PollCubit>.value(value: cubit),
              BlocProvider<EngagementCubit>.value(value: engagement),
            ],
            child: app,
          ),
        ),
      );
      expect(rig.drafts, isNotNull);

      // Compose: open the builder, fill it, post.
      await tester.tap(
        find.descendant(
          of: find.byType(ComposerPollButton),
          matching: find.byType(IconButton),
        ),
      );
      await tester.pumpAndSettle();
      Finder field(String label) => find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == label,
      );
      await tester.enterText(
        find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.hintText == kPollQuestionHint,
        ),
        'Best colour?',
      );
      await tester.enterText(field('Choice 1'), 'Red');
      await tester.enterText(field('Choice 2'), 'Blue');
      await tester.pump();
      await tester.tap(find.widgetWithText(AppPillButton, 'Post'));
      await tester.pumpAndSettle();

      expect(sentText, 'Best colour?');
      expect(sentPoll?.choices, ['Red', 'Blue']);
      expect(sentPoll?.durationMinutes, 1440);

      // The card appears; the author sees it without vote buttons.
      expect(find.text('Best colour?'), findsOneWidget);
      expect(choice(0), findsOneWidget);
      expect(
        find.descendant(of: choice(0), matching: find.byType(OutlinedButton)),
        findsNothing,
      );
      expect(find.text('0 votes · 2 days left'), findsOneWidget);

      // A follower sees the same post: buttons. VotePoll is not deployed yet.
      viewer.value = 'follower';
      await tester.pumpAndSettle();
      answer = () => connect.ConnectException(connect.Code.unimplemented, 'x');
      await tester.tap(choice(1));
      await tester.pumpAndSettle();
      expect(find.text("Voting isn't available right now."), findsOneWidget);
      expect(
        find.descendant(of: choice(1), matching: find.byType(OutlinedButton)),
        findsNothing,
      );

      // VotePoll ships; the next GetMe resets the memory; the vote lands.
      cubit.flagsChanged();
      answer = () => eng.VotePollResponse(
        post: pollPostView(
          1,
          poll: pollOf(
            labels: const ['Red', 'Blue'],
            votes: const [0, 1],
            total: 1,
            visible: true,
          ),
          choice: 2,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(choice(1));
      await tester.pumpAndSettle();

      expect(votes.last.choiceIndex, 1);
      expect(find.text('100%'), findsOneWidget);
      expect(find.text('0%'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(find.text('1 vote · 2 days left'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
