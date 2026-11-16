import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/features/beacons/data/beacons_repository.dart';
import 'package:dzeroth/features/beacons/presentation/widgets/beacon_row.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/graph/presentation/bloc/suggestions_cubit.dart';
import 'package:dzeroth/features/graph/presentation/widgets/user_list_row.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/search/data/recent_searches_store.dart';
import 'package:dzeroth/features/search/data/search_repository.dart';
import 'package:dzeroth/features/search/domain/explore_tab.dart';
import 'package:dzeroth/features/search/presentation/bloc/trends_cubit.dart';
import 'package:dzeroth/features/search/presentation/explore_screen.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/shared/widgets/primitives/app_tab_bar.dart';
import 'package:dzeroth/shared/widgets/user/follow_pill.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/beacons_fixtures.dart';
import '../../../support/fake_beacons_server.dart';
import '../../../support/fake_search_repository.dart';
import '../../../support/search_field_rig.dart';
import '../../../support/suggestions_fixtures.dart';
import '../../../support/theme_harness.dart';

class _MockGraph extends Mock implements GraphRepository {}

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

/// F18: Explore's Plans and People tabs, each behind its own flag.
void main() {
  late FakeSuggestionsRepository suggestions;
  late SuggestionsCubit cubit;
  late FakeBeaconsServer beacons;
  late _MockOnboarding onboarding;

  setUp(() {
    suggestions = FakeSuggestionsRepository([
      for (var i = 1; i <= 5; i++) suggestedUser(i),
    ]);
    cubit = SuggestionsCubit(repository: suggestions);
    beacons = FakeBeaconsServer();
    onboarding = _MockOnboarding();
  });

  tearDown(() => cubit.close());

  Future<void> open(
    WidgetTester tester, {
    Set<String> features = const {
      'search',
      'trends',
      'graph',
      'follow_suggestions',
      'beacons',
    },
    Size size = const Size(360, 800),
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
          RepositoryProvider<GraphRepository>.value(value: _MockGraph()),
          RepositoryProvider<BeaconsRepository>.value(value: beacons),
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
            BlocProvider<TrendsCubit>(
              create: (_) => TrendsCubit(repository: FakeSearchRepository()),
            ),
          ],
          child: const ExploreScreen(),
        ),
      ),
      size: size,
    );
  }

  List<String> tabLabels(WidgetTester tester) => [
    for (final t in tester.widget<AppTabBar>(find.byType(AppTabBar)).tabs)
      t.label,
  ];

  group('which tabs show', () {
    test('exploreTabsFor and resolveExploreTab', () {
      List<ExploreTab> tabs(bool p, bool u) =>
          exploreTabsFor(plans: p, people: u);
      expect(tabs(false, false), [ExploreTab.trending]);
      expect(showsExploreTabBar(tabs(false, false)), isFalse);
      expect(showsExploreTabBar(tabs(true, false)), isTrue);
      expect(tabs(true, true), [
        ExploreTab.trending,
        ExploreTab.plans,
        ExploreTab.people,
      ]);
      expect(
        resolveExploreTab(ExploreTab.plans, [ExploreTab.trending]),
        ExploreTab.trending,
      );
    });

    testWidgets('both flags: Trending, Plans, People', (tester) async {
      await open(tester);
      expect(tabLabels(tester), ['Trending', 'Plans', 'People']);
      expect(find.text('Nearby'), findsNothing);
    });

    testWidgets('beacons only: no People', (tester) async {
      await open(tester, features: const {'search', 'trends', 'beacons'});
      expect(tabLabels(tester), ['Trending', 'Plans']);
    });

    testWidgets('suggestions only: no Plans', (tester) async {
      await open(
        tester,
        features: const {'search', 'trends', 'graph', 'follow_suggestions'},
      );
      expect(tabLabels(tester), ['Trending', 'People']);
    });

    testWidgets('follow_suggestions without graph: no People', (tester) async {
      await open(
        tester,
        features: const {'search', 'trends', 'follow_suggestions'},
      );
      expect(find.byType(AppTabBar), findsNothing);
    });

    testWidgets('neither: no bar (the old look) and no calls', (tester) async {
      await open(tester, features: const {'search', 'trends'});
      expect(find.byType(AppTabBar), findsNothing);
      expect(beacons.calls, isEmpty);
      expect(suggestions.calls, 0);
    });
  });

  group('Plans tab', () {
    testWidgets('opening Explore sends no ListBeacons', (tester) async {
      await open(tester);
      expect(beacons.calls, isEmpty);
    });

    testWidgets('empty state', (tester) async {
      await open(tester);
      await tester.tap(find.text('Plans'));
      await tester.pumpAndSettle();
      expect(find.text('No public plans yet'), findsOneWidget);
      expect(beacons.calls, ['list:']);
    });

    testWidgets('loads rows and pages with Load more', (tester) async {
      final start = DateTime.now().add(const Duration(days: 1));
      for (var i = 0; i < 25; i++) {
        beacons.public.add(
          beaconView(startAt: start, id: '${1000 + i}', title: 'Plan $i'),
        );
      }
      await open(tester);
      await tester.tap(find.text('Plans'));
      await tester.pumpAndSettle();
      expect(find.byType(BeaconRow), findsWidgets);
      await tester.dragUntilVisible(
        find.text('Load more'),
        find.byType(CustomScrollView),
        const Offset(0, -300),
      );
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -200));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Load more'));
      await tester.pumpAndSettle();
      expect(beacons.calls, ['list:', 'list:']);
      await tester.dragUntilVisible(
        find.text('Plan 24'),
        find.byType(CustomScrollView),
        const Offset(0, -300),
      );
      expect(find.text('Load more'), findsNothing);
    });

    testWidgets('pull to refresh asks again', (tester) async {
      await open(tester);
      await tester.tap(find.text('Plans'));
      await tester.pumpAndSettle();
      await tester.fling(
        find.byType(CustomScrollView),
        const Offset(0, 400),
        1000,
      );
      await tester.pumpAndSettle();
      expect(beacons.calls.length, 2);
    });

    testWidgets('back to Trending keeps the list, no second load', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(find.text('Plans'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Trending'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Plans'));
      await tester.pumpAndSettle();
      expect(beacons.calls, ['list:']);
    });
  });

  group('People tab', () {
    testWidgets('shows all five suggestions with follow buttons', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(find.text('People'));
      await tester.pumpAndSettle();
      expect(find.byType(UserListRow), findsNWidgets(5));
      expect(find.widgetWithText(FollowPill, 'Follow'), findsWidgets);
    });

    testWidgets('empty state when nothing is suggested', (tester) async {
      suggestions.rows = [];
      await open(tester);
      await tester.tap(find.text('People'));
      await tester.pumpAndSettle();
      expect(find.text('No suggestions right now'), findsOneWidget);
    });

    testWidgets('desktop width keeps the tab', (tester) async {
      await open(tester, size: const Size(1200, 900));
      expect(tabLabels(tester), ['Trending', 'Plans', 'People']);
    });
  });
}
