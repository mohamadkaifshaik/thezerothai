import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/beacons/data/beacons_repository.dart';
import 'package:dzeroth/features/beacons/presentation/widgets/beacon_row.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/graph/presentation/bloc/suggestions_cubit.dart';
import 'package:dzeroth/features/location/domain/location_models.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/search/data/recent_searches_store.dart';
import 'package:dzeroth/features/search/data/search_repository.dart';
import 'package:dzeroth/features/search/domain/explore_tab.dart';
import 'package:dzeroth/features/search/presentation/bloc/trends_cubit.dart';
import 'package:dzeroth/features/search/presentation/explore_screen.dart';
import 'package:dzeroth/features/search/presentation/widgets/explore_nearby_section.dart';
import 'package:dzeroth/gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/location/v1/location.pb.dart' as loc;
import 'package:dzeroth/gen/dzeroth/location/v1/location.pbenum.dart'
    as locenum;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/shared/widgets/primitives/app_tab_bar.dart';
import 'package:material_ui/material_ui.dart';
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

const _alpha = AreaRef(
  id: 'in.x.a',
  name: 'Alpha',
  type: AreaType.area,
  cityId: 'in.x',
  cityName: 'Xcity',
);

/// Explore's Nearby tab: shown with `location` and `beacons`, the prompt, the
/// list with its count and scope switch, and the area line on each card.
void main() {
  late FakeBeaconsServer beacons;
  late _MockOnboarding onboarding;
  late SuggestionsCubit suggestions;
  final start = DateTime.now().add(const Duration(days: 1));

  pb.NearbyBeacon row(
    int i, {
    pb.AreaProximity proximity = pb.AreaProximity.AREA_PROXIMITY_SAME_AREA,
    bool withArea = true,
  }) {
    final view = beaconView(
      startAt: start,
      id: '${3000 + i}',
      title: 'Plan $i',
    );
    if (withArea) {
      view.beacon.area = loc.AreaSummary(
        areaId: 'in.x.b',
        name: 'Beta',
        kind: locenum.AreaKind.AREA_KIND_AREA,
        cityId: 'in.x',
        cityName: 'Xcity',
      );
    }
    return pb.NearbyBeacon(view: view, proximity: proximity);
  }

  setUp(() {
    beacons = FakeBeaconsServer()..nearbyArea = _alpha;
    onboarding = _MockOnboarding();
    suggestions = SuggestionsCubit(
      repository: FakeSuggestionsRepository([suggestedUser(1)]),
    );
  });

  tearDown(() => suggestions.close());

  Future<void> open(
    WidgetTester tester, {
    Set<String> features = const {'search', 'trends', 'beacons', 'location'},
    Size size = const Size(360, 800),
    ExploreTab? initialTab,
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
            BlocProvider<SuggestionsCubit>.value(value: suggestions),
            BlocProvider<TrendsCubit>(
              create: (_) => TrendsCubit(repository: FakeSearchRepository()),
            ),
          ],
          child: ExploreScreen(initialTab: initialTab),
        ),
      ),
      size: size,
    );
  }

  Future<void> openNearby(WidgetTester tester, {Size? size}) async {
    await open(tester, size: size ?? const Size(360, 800));
    await tester.tap(find.text('Nearby'));
    await tester.pumpAndSettle();
  }

  List<String> tabLabels(WidgetTester tester) => [
    for (final t in tester.widget<AppTabBar>(find.byType(AppTabBar)).tabs)
      t.label,
  ];

  group('which tabs show', () {
    test('exploreTabsFor puts Nearby after Trending', () {
      expect(exploreTabsFor(plans: true, people: true, nearby: true), [
        ExploreTab.trending,
        ExploreTab.nearby,
        ExploreTab.plans,
        ExploreTab.people,
      ]);
      expect(exploreTabsFor(plans: true, people: false), [
        ExploreTab.trending,
        ExploreTab.plans,
      ]);
    });

    testWidgets('location and beacons: Nearby shows', (tester) async {
      await open(tester);
      expect(tabLabels(tester), ['Trending', 'Nearby', 'Plans']);
      expect(beacons.calls, isEmpty);
    });

    testWidgets('initialTab nearby opens on Nearby with one call', (
      tester,
    ) async {
      await open(tester, initialTab: ExploreTab.nearby);
      expect(beacons.calls, ['nearby']);
    });

    testWidgets('initialTab nearby with location off falls back to Trending', (
      tester,
    ) async {
      await open(
        tester,
        features: {'search', 'trends', 'beacons'},
        initialTab: ExploreTab.nearby,
      );
      expect(beacons.calls, isEmpty);
    });

    testWidgets('location off: no Nearby tab', (tester) async {
      await open(tester, features: const {'search', 'trends', 'beacons'});
      expect(tabLabels(tester), ['Trending', 'Plans']);
      expect(find.text('Nearby'), findsNothing);
    });

    testWidgets('beacons off: no Nearby tab', (tester) async {
      await open(tester, features: const {'search', 'trends', 'location'});
      expect(find.byType(AppTabBar), findsNothing);
      expect(find.text('Nearby'), findsNothing);
    });

    testWidgets('FEATURE_DISABLED hides the tab', (tester) async {
      beacons.nearbyRefusals.add(
        const FeatureDisabledException('off', feature: 'location'),
      );
      await openNearby(tester);
      expect(tabLabels(tester), ['Trending', 'Plans']);
    });
  });

  group('count copy', () {
    test('none, few, exact, about', () {
      expect(nearbyCountText(null), isNull);
      expect(nearbyCountText(pb.NearbyCount()), isNull);
      expect(nearbyCountText(pb.NearbyCount(few: true)), 'A few plans');
      expect(nearbyCountText(pb.NearbyCount(plans: 14)), '14 plans');
      expect(nearbyCountText(pb.NearbyCount(plans: 120)), 'About 120 plans');
      expect(nearbyCountText(pb.NearbyCount(plans: 1000)), 'About 1000+ plans');
    });
  });

  group('Nearby tab', () {
    testWidgets('no area: the prompt, no list', (tester) async {
      beacons.nearbyRefusals.add(const StateConflictException('area_not_set'));
      await openNearby(tester);
      expect(find.text(kNearbyPromptTitle), findsOneWidget);
      expect(find.text(kNearbyChooseArea), findsOneWidget);
      expect(find.byType(BeaconRow), findsNothing);
    });

    testWidgets('list with the exact count, the scope switch and labels', (
      tester,
    ) async {
      beacons.nearby.addAll([
        row(1),
        row(2, proximity: pb.AreaProximity.AREA_PROXIMITY_NEIGHBOURING),
        row(3, proximity: pb.AreaProximity.AREA_PROXIMITY_SAME_CITY),
        row(4, withArea: false),
      ]);
      beacons.nearbyCount = pb.NearbyCount(plans: 14);
      await openNearby(tester, size: const Size(360, 3000));

      expect(find.text('In your area · Alpha'), findsOneWidget);
      expect(find.text('14 plans'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Your area'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'All of Xcity'), findsOneWidget);
      expect(find.byType(BeaconRow), findsWidgets);
      expect(find.text('In your area'), findsWidgets);
      expect(find.text('Nearby: Beta'), findsOneWidget);
      expect(find.text('In Xcity'), findsOneWidget);
      expect(find.textContaining(' km'), findsNothing);
    });

    testWidgets('a few plans reads "A few plans"', (tester) async {
      beacons.nearby.add(row(1));
      beacons.nearbyCount = pb.NearbyCount(few: true);
      await openNearby(tester);
      expect(find.text('A few plans'), findsOneWidget);
    });

    testWidgets('the City scope asks the server again', (tester) async {
      beacons.nearby.add(row(1));
      await openNearby(tester);
      await tester.tap(find.widgetWithText(ChoiceChip, 'All of Xcity'));
      await tester.pumpAndSettle();
      expect(beacons.nearbyScopes.last, pb.NearbyScope.NEARBY_SCOPE_CITY);
    });

    testWidgets('a city area has no scope switch', (tester) async {
      beacons.nearbyArea = const AreaRef(
        id: 'in.x',
        name: 'Xcity',
        type: AreaType.city,
        cityId: 'in.x',
        cityName: 'Xcity',
      );
      beacons.nearby.add(row(1));
      await openNearby(tester);
      expect(find.byType(ChoiceChip), findsNothing);
    });

    testWidgets('empty: No plans near <area> yet', (tester) async {
      await openNearby(tester);
      expect(find.text('No plans near Alpha yet'), findsOneWidget);
    });

    testWidgets('error with retry', (tester) async {
      beacons.nearbyRefusals.add(const NetworkException('offline'));
      await openNearby(tester);
      expect(find.text('Try again'), findsOneWidget);
      beacons.nearby.add(row(1));
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.byType(BeaconRow), findsOneWidget);
    });

    testWidgets('pages with Load more', (tester) async {
      beacons.nearby.addAll([for (var i = 0; i < 25; i++) row(i)]);
      await openNearby(tester);
      await tester.dragUntilVisible(
        find.text('Load more'),
        find.byType(CustomScrollView),
        const Offset(0, -300),
      );
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -200));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Load more'));
      await tester.pumpAndSettle();
      expect(beacons.calls, ['nearby', 'nearby']);
    });

    testWidgets('pull to refresh asks again', (tester) async {
      beacons.nearby.add(row(1));
      await openNearby(tester);
      await tester.fling(
        find.byType(CustomScrollView),
        const Offset(0, 400),
        1000,
      );
      await tester.pumpAndSettle();
      expect(beacons.calls.length, 2);
    });

    testWidgets('tablet and desktop widths keep the tab and the list', (
      tester,
    ) async {
      for (final size in const [Size(800, 900), Size(1280, 900)]) {
        beacons = FakeBeaconsServer()
          ..nearbyArea = _alpha
          ..nearby.add(row(1));
        await openNearby(tester, size: size);
        expect(tabLabels(tester), contains('Nearby'), reason: '$size');
        expect(find.byType(BeaconRow), findsOneWidget, reason: '$size');
        expect(tester.takeException(), isNull, reason: '$size');
      }
    });
  });
}
