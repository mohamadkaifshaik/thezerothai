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
}
