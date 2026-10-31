import 'package:bloc_test/bloc_test.dart';
import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/feature_flags/service_feature_gate.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/engagement/data/poll_repository.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/poll_cubit.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/engagement/v1/engagement.pb.dart' as eng;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart';
import 'package:dzeroth/shared/widgets/post_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/fake_transport.dart';
import '../../support/poll_fixtures.dart';
import '../../support/posts_fixtures.dart';

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockGraph extends Mock implements GraphRepository {}

void main() {
  late FakeTransport transport;
  late PollCubit cubit;
  late _MockOnboarding onboarding;
  late Object Function() answer;
  late int reads;

  setUp(() {
    reads = 0;
    answer = () => throw StateError('unscripted');
    transport = FakeTransport((procedure, input) async {
      final r = answer();
      if (r is Exception) throw r;
      return r;
    });
    cubit = PollCubit(
      repository: PollRepository(
        apiClient: ApiClient.withTransport(transport),
        gate: ServiceFeatureGate(isEnabled: () => true),
        readPost: (_) async {
          reads++;
          return pollPostView(
            1,
            poll: pollOf(
              votes: [2, 1, 0],
              total: 3,
              visible: true,
              closed: true,
            ),
          );
        },
      ),
    );
    onboarding = _MockOnboarding();
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: const OnboardingState(
        status: OnboardingStatus.ready,
        enabledFeatures: {'engagement'},
      ),
    );
  });

  tearDown(() => cubit.close());

  Widget wrap(Widget child, {bool withCubit = true}) {
    final graph = _MockGraph();
    when(() => graph.cached(any())).thenReturn(null);
    return RepositoryProvider<GraphRepository>.value(
      value: graph,
      child: MultiBlocProvider(
        providers: [
          BlocProvider<OnboardingBloc>.value(value: onboarding),
          if (withCubit) BlocProvider<PollCubit>.value(value: cubit),
        ],
        child: MaterialApp(
          theme: appDarkTheme,
          home: Scaffold(body: SingleChildScrollView(child: child)),
        ),
      ),
    );
  }

  testWidgets('tap on choice 2: exactly one VotePoll, bars with the check', (
    tester,
  ) async {
    answer = () => eng.VotePollResponse(
      post: pollPostView(
        1,
        poll: pollOf(votes: [1, 3, 0], total: 4, visible: true),
        choice: 2,
      ),
    );
    final view = pollPostView(1, poll: pollOf(total: 1));
    await tester.pumpWidget(wrap(PostCard(view: view, now: kPollNow)));

    await tester.tap(find.byKey(const ValueKey('poll-choice-1')));
    await tester.pumpAndSettle();

    expect(transport.calledProcedures, hasLength(1));
    expect(find.text('75%'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.text('4 votes · 2 days left'), findsOneWidget);
  });

  testWidgets('a failed call brings the buttons back and says so', (
    tester,
  ) async {
    answer = () => connect.ConnectException(connect.Code.unavailable, 'x');
    await tester.pumpWidget(
      wrap(
        PostCard(
          view: pollPostView(1, poll: pollOf(total: 1)),
          now: kPollNow,
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('poll-choice-0')));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.check_circle), findsNothing);
    expect(
      find.text('No connection. Check your network and try again.'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('poll-choice-0')));
    await tester.pumpAndSettle();
    expect(transport.calledProcedures, hasLength(2));
  });

  testWidgets('the author sees no buttons', (tester) async {
    await tester.pumpWidget(
      wrap(
        PostCard(
          view: pollPostView(
            1,
            poll: pollOf(votes: [1, 0, 0], total: 1, visible: true),
          ),
          viewerUserId: 'u1',
          now: kPollNow,
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('poll-choice-0')));
    await tester.pump();
    expect(transport.calledProcedures, isEmpty);
    expect(find.text('100%'), findsOneWidget);
  });

  testWidgets('a cached closed poll: See final results is one GetPost', (
    tester,
  ) async {
    final view = pollPostView(
      1,
      poll: pollOf(total: 3, closesIn: const Duration(hours: -1)),
    );
    await tester.pumpWidget(wrap(PostCard(view: view, now: kPollNow)));

    await tester.tap(find.byKey(const ValueKey('poll-see-final')));
    await tester.pumpAndSettle();

    expect(reads, 1);
    expect(transport.calledProcedures, isEmpty);
    expect(find.text('3 votes · Final results'), findsOneWidget);
    expect(find.byKey(const ValueKey('poll-see-final')), findsNothing);
  });

  testWidgets('engagement off: read-only, no vote is possible', (tester) async {
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: const OnboardingState(status: OnboardingStatus.ready),
    );
    await tester.pumpWidget(
      wrap(
        PostCard(
          view: pollPostView(1, poll: pollOf(total: 1)),
          now: kPollNow,
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('poll-choice-0')));
    await tester.pump();
    expect(transport.calledProcedures, isEmpty);
  });

  testWidgets('no PollCubit above: read-only, no exception', (tester) async {
    await tester.pumpWidget(
      wrap(
        PostCard(
          view: pollPostView(1, poll: pollOf(total: 1)),
          now: kPollNow,
        ),
        withCubit: false,
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Red'), findsOneWidget);
  });

  testWidgets(
    'a REPOST shows the frozen poll read-only and opens the original',
    (tester) async {
      final opened = <String>[];
      final view = pb.PostView(
        post: pb.Post(
          postId: postId(2),
          kind: PostKind.POST_KIND_REPOST,
          embedded: pb.EmbeddedPost(
            postId: postId(1),
            text: 'Pick one',
            poll: pollOf(),
          ),
        ),
      );
      await tester.pumpWidget(
        wrap(PostCard(view: view, now: kPollNow, onOpenPost: opened.add)),
      );

      expect(find.text('Poll · 3 choices · ends in 2 days'), findsOneWidget);
      expect(find.byKey(const ValueKey('poll-choice-0')), findsNothing);
      await tester.tap(find.text('Green'));
      expect(opened, [postId(1)]);
      expect(transport.calledProcedures, isEmpty);
    },
  );

  group('change vote (W6-37, ADR-0029 Amendment 1)', () {
    // The viewer voted Red (index 0): counts 5 / 4 / 3, choice = 1.
    pb.PostView voted({bool blocked = false}) {
      final v = pollPostView(
        1,
        poll: pollOf(votes: [5, 4, 3], total: 12, visible: true),
        choice: 1,
      );
      v.viewerPollVoteBlocked = blocked;
      return v;
    }

    Future<void> pumpVoted(WidgetTester tester, pb.PostView view) =>
        tester.pumpWidget(wrap(PostCard(view: view, now: kPollNow)));

    Future<void> startChangeTo(WidgetTester tester, int index) async {
      await tester.tap(find.byKey(const ValueKey('poll-change-vote')));
      await tester.pump();
      await tester.tap(find.byKey(ValueKey('poll-choice-$index')));
      await tester.pumpAndSettle();
    }

    Object refusal(
      connect.Code code,
      common.ErrorReason reason, [
      Map<String, String> metadata = const {},
    ]) => serverError(code, reason, metadata: metadata);

    testWidgets(
      'Change vote, another pill: one VotePoll with expected_choice',
      (tester) async {
        final requests = <eng.VotePollRequest>[];
        transport = FakeTransport((procedure, input) async {
          requests.add(input as eng.VotePollRequest);
          return answer();
        });
        cubit = PollCubit(
          repository: PollRepository(
            apiClient: ApiClient.withTransport(transport),
            gate: ServiceFeatureGate(isEnabled: () => true),
            readPost: (_) async => voted(),
          ),
        );
        answer = () => eng.VotePollResponse(
          post: pollPostView(
            1,
            poll: pollOf(votes: [4, 5, 3], total: 12, visible: true),
            choice: 2,
          ),
        );
        await pumpVoted(tester, voted());
        expect(find.byKey(const ValueKey('poll-change-vote')), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('poll-change-vote')));
        await tester.pump();
        expect(
          find.byKey(const ValueKey('poll-cancel-change')),
          findsOneWidget,
        );
        expect(find.byIcon(Icons.check_circle), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('poll-choice-1')));
        await tester.pumpAndSettle();

        expect(requests, hasLength(1));
        expect(requests.single.choiceIndex, 1);
        expect(requests.single.expectedChoice, 1);
        expect(find.byKey(const ValueKey('poll-change-vote')), findsOneWidget);
        expect(
          find.text('42%'),
          findsOneWidget,
          reason: '5 of 12 now on Green',
        );
      },
    );

    testWidgets('a failed change rolls back the counts and says so', (
      tester,
    ) async {
      answer = () => connect.ConnectException(connect.Code.unavailable, 'x');
      await pumpVoted(tester, voted());
      expect(find.text('42%'), findsOneWidget, reason: '5 of 12 on Red');
      await startChangeTo(tester, 2);

      expect(find.text('42%'), findsOneWidget, reason: 'rolled back');
      expect(
        find.text('No connection. Check your network and try again.'),
        findsOneWidget,
      );
    });

    testWidgets('Cancel returns to the bars without a call', (tester) async {
      await pumpVoted(tester, voted());
      await tester.tap(find.byKey(const ValueKey('poll-change-vote')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('poll-cancel-change')));
      await tester.pump();
      expect(transport.calledProcedures, isEmpty);
      expect(find.byKey(const ValueKey('poll-change-vote')), findsOneWidget);
    });

    testWidgets('an older server (ALREADY_VOTED): rolled back, says so', (
      tester,
    ) async {
      answer = () => refusal(
        connect.Code.failedPrecondition,
        common.ErrorReason.ERROR_REASON_ALREADY_VOTED,
        {'choice': '0'},
      );
      await pumpVoted(tester, voted());
      await startChangeTo(tester, 1);

      expect(
        find.text("Your vote didn't change. Showing your current choice."),
        findsOneWidget,
      );
      expect(reads, 1);
    });

    testWidgets('LIMIT_REACHED: friendly copy, the control is gone', (
      tester,
    ) async {
      answer = () => refusal(
        connect.Code.resourceExhausted,
        common.ErrorReason.ERROR_REASON_LIMIT_REACHED,
        {'limit': 'poll_vote_changes', 'choice': '0'},
      );
      await pumpVoted(tester, voted());
      await startChangeTo(tester, 1);

      expect(
        find.text("You've changed your vote the most times allowed."),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('poll-change-vote')), findsNothing);
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
    });

    testWidgets('TARGET_BLOCKED: the blocked state appears', (tester) async {
      answer = () => refusal(
        connect.Code.failedPrecondition,
        common.ErrorReason.ERROR_REASON_TARGET_BLOCKED,
      );
      await pumpVoted(tester, voted());
      await startChangeTo(tester, 1);

      expect(find.textContaining('Unblock to vote'), findsWidgets);
      expect(find.byKey(const ValueKey('poll-change-vote')), findsNothing);
    });

    testWidgets('POLL_CLOSED: one GetPost, the final results', (tester) async {
      answer = () => refusal(
        connect.Code.failedPrecondition,
        common.ErrorReason.ERROR_REASON_POLL_CLOSED,
      );
      await pumpVoted(tester, voted());
      await startChangeTo(tester, 1);

      expect(reads, 1);
      expect(find.byKey(const ValueKey('poll-change-vote')), findsNothing);
      expect(find.text('3 votes · Final results'), findsOneWidget);
    });

    testWidgets('blocked and voted: the check and results, no control', (
      tester,
    ) async {
      await pumpVoted(tester, voted(blocked: true));
      expect(find.byKey(const ValueKey('poll-change-vote')), findsNothing);
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(find.text('42%'), findsOneWidget);
      expect(find.textContaining('Unblock to vote'), findsOneWidget);
    });

    testWidgets('blocked and never voted: hidden results, disabled', (
      tester,
    ) async {
      final v = pollPostView(1, poll: pollOf(total: 3));
      v.viewerPollVoteBlocked = true;
      await pumpVoted(tester, v);

      expect(find.textContaining('Unblock to vote'), findsOneWidget);
      expect(find.textContaining('%'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('poll-choice-0')));
      await tester.pump();
      expect(transport.calledProcedures, isEmpty);
    });

    testWidgets('the author sees no Change vote', (tester) async {
      await tester.pumpWidget(
        wrap(PostCard(view: voted(), viewerUserId: 'u1', now: kPollNow)),
      );
      expect(find.byKey(const ValueKey('poll-change-vote')), findsNothing);
    });
  });
}
