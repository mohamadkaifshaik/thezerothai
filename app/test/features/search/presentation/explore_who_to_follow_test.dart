import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/graph/presentation/bloc/suggestions_cubit.dart';
import 'package:dzeroth/features/graph/presentation/widgets/user_list_row.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/search/data/recent_searches_store.dart';
import 'package:dzeroth/features/search/data/search_repository.dart';
import 'package:dzeroth/features/search/presentation/explore_screen.dart';
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/fake_search_repository.dart';
import '../../../support/search_field_rig.dart';
import '../../../support/suggestions_fixtures.dart';
import '../../../support/theme_harness.dart';

class _MockGraph extends Mock implements GraphRepository {}

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

/// W4-19: the "Who to follow" slot of Explore renders W3's card from W3's
/// shared cubit; W4 adds no call and no cache of its own.
void main() {
  late FakeSuggestionsRepository repo;
  late SuggestionsCubit cubit;
  late _MockGraph graphRepo;
  late _MockOnboarding onboarding;

  setUp(() {
    repo = FakeSuggestionsRepository([
      for (var i = 1; i <= 5; i++) suggestedUser(i),
    ]);
    cubit = SuggestionsCubit(repository: repo);
    graphRepo = _MockGraph();
    onboarding = _MockOnboarding();
    when(
      () => graphRepo.follow(
        userId: any(named: 'userId'),
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).thenAnswer(
      (invocation) async => graph.Relationship(
        userId: invocation.namedArguments[#userId] as String,
        followState: graph.FollowState.FOLLOW_STATE_FOLLOWING,
      ),
    );
  });

  tearDown(() => cubit.close());

  Future<void> open(
    WidgetTester tester, {
    Set<String> features = const {'search', 'graph', 'follow_suggestions'},
    Size size = const Size(360, 800),
    Brightness brightness = Brightness.light,
    double textScale = 1,
  }) async {
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        enabledFeatures: features,
        profile: identity.Profile(userId: 'me', handle: 'me'),
      ),
    );
    await pumpThemed(
      tester,
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<GraphRepository>.value(value: graphRepo),
          RepositoryProvider<SearchRepository>.value(
            value: FakeSearchRepository(),
          ),
          RepositoryProvider<RecentSearchesStore>.value(
            value: FakeRecentSearchesStore(),
          ),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<OnboardingBloc>.value(value: onboarding),
            BlocProvider<SuggestionsCubit>.value(value: cubit),
          ],
          child: const ExploreScreen(),
        ),
      ),
      size: size,
      brightness: brightness,
      textScale: textScale,
    );
  }

  testWidgets('flag on: three rows from the shared list', (tester) async {
    await open(tester);
    expect(find.text('Who to follow'), findsOneWidget);
    expect(find.byType(UserListRow), findsNWidgets(3));
    expect(find.text('Show more'), findsOneWidget);
  });

  testWidgets('flag off: no card and no call', (tester) async {
    await open(tester, features: const {'search'});
    expect(find.text('Who to follow'), findsNothing);
    expect(find.byType(UserListRow), findsNothing);
    expect(repo.calls, 0);
  });

  testWidgets('a follow from the card updates the row button', (tester) async {
    await open(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Follow').first);
    await tester.pumpAndSettle();
    verify(
      () => graphRepo.follow(
        userId: any(named: 'userId'),
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).called(1);
    expect(repo.followedIds, ['u1']);
  });

  for (final size in const [Size(360, 800), Size(600, 900), Size(1200, 900)]) {
    for (final b in Brightness.values) {
      testWidgets('${size.width.toInt()}dp ${b.name} x2.0: no overflow', (
        tester,
      ) async {
        await open(tester, size: size, brightness: b, textScale: 2);
        expect(tester.takeException(), isNull);
        expect(find.byType(UserListRow), findsWidgets);
      });
    }
  }
}
