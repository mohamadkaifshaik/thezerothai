import 'package:dzeroth/features/search/data/search_repository.dart';
import 'package:dzeroth/features/search/presentation/widgets/app_search_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_search_repository.dart';
import '../../../support/search_field_rig.dart';
import '../../../support/theme_harness.dart';

void main() {
  late FakeSearchRepository repo;
  late FakeRecentSearchesStore store;
  late List<String> submitted;
  late List<String> people;

  setUp(() {
    repo = FakeSearchRepository();
    store = FakeRecentSearchesStore();
    submitted = [];
    people = [];
  });

  Future<void> open(
    WidgetTester tester, {
    Set<String> features = const {'search', 'trends'},
    Size size = const Size(400, 800),
    double textScale = 1.0,
    Brightness brightness = Brightness.light,
  }) => pumpWithSearch(
    tester,
    AppSearchField(
      onSubmitted: (_, q) => submitted.add(q),
      onPersonSelected: (_, p) => people.add(p.user.handle),
    ),
    repository: repo,
    store: store,
    features: features,
    size: size,
    textScale: textScale,
    brightness: brightness,
  );

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.pump();
  }

  const debounce = Duration(milliseconds: 300);

  testWidgets('search off: the field is absent', (tester) async {
    await open(tester, features: const {'trends'});
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('has the spoken label "Search query"', (tester) async {
    await open(tester);
    final handle = tester.ensureSemantics();
    expect(
      tester.getSemantics(find.byType(TextField)).label,
      contains('Search query'),
    );
    handle.dispose();
  });

  testWidgets('focus shows Recent with Clear all; a row submits it', (
    tester,
  ) async {
    store = FakeRecentSearchesStore(['#go', '@ann']);
    await open(tester);
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.pump();
    expect(find.text('Recent'), findsOneWidget);
    expect(find.text('#go'), findsOneWidget);
    expect(repo.calls, isEmpty);

    await tester.tap(find.text('#go'));
    await tester.pump();
    expect(submitted, ['#go']);
    expect(store.items.first, '#go');
    expect(find.text('Recent'), findsNothing, reason: 'overlay closed');
  });

  testWidgets('Clear all empties the list; remove drops one', (tester) async {
    store = FakeRecentSearchesStore(['#go', '@ann']);
    await open(tester);
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byTooltip('Remove #go'));
    await tester.pump();
    await tester.pump();
    expect(store.items, ['@ann']);
    await tester.tap(find.text('Clear all'));
    await tester.pump();
    await tester.pump();
    expect(store.items, isEmpty);
    expect(find.text(kSearchEmptyHint), findsOneWidget);
  });

  testWidgets('"a" then "ab" typed quickly makes exactly one call', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byType(TextField));
    await type(tester, 'a');
    await tester.pump(const Duration(milliseconds: 100));
    await type(tester, 'ab');
    await tester.pump(debounce);
    await tester.pump();
    expect(repo.peopleQueries, ['ab']);
    expect(repo.calls.where((c) => c.startsWith('people')), hasLength(1));
  });

  testWidgets('one character makes no call at all', (tester) async {
    await open(tester);
    await tester.tap(find.byType(TextField));
    await type(tester, 'a');
    await tester.pump(debounce * 2);
    expect(repo.calls, isEmpty);
  });

  testWidgets('trends off: no hashtag suggestions and no GetTrends call', (
    tester,
  ) async {
    repo.trendsResult = TrendsResult(trends: [searchTrend('go', 5, 1)]);
    await open(tester, features: const {'search'});
    await tester.tap(find.byType(TextField));
    await type(tester, 'go');
    await tester.pump(debounce);
    await tester.pump();
    expect(repo.calls.any((c) => c.startsWith('trends')), isFalse);
    expect(find.text('#go'), findsNothing);
  });

  testWidgets('shows Search for, hashtags and people; rows act', (
    tester,
  ) async {
    repo.peopleResult = SearchPeopleResult(users: [searchPerson('gopher')]);
    repo.trendsResult = TrendsResult(trends: [searchTrend('golang', 1200, 1)]);
    await open(tester);
    await tester.tap(find.byType(TextField));
    await type(tester, 'go');
    await tester.pump(debounce);
    await tester.pump();
    await tester.pump();
    expect(find.text('Search for "go"'), findsOneWidget);
    expect(find.text('#golang'), findsOneWidget);
    expect(find.text('1.2K posts'), findsOneWidget);
    expect(find.text('@gopher'), findsOneWidget);
    expect(repo.calls, containsAll(['people:go', 'trends:go']));

    await tester.tap(find.text('@gopher'));
    await tester.pump();
    expect(people, ['gopher']);
    expect(submitted, isEmpty);
    expect(store.items, ['@gopher']);
  });

  testWidgets('Enter submits the canonical text and records it', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byType(TextField));
    await type(tester, '  #Go ');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(submitted, ['#go']);
    expect(store.items, ['#go']);
  });

  testWidgets('Enter on text that cannot be searched does nothing', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byType(TextField));
    await type(tester, '@');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(submitted, isEmpty);
    await type(tester, '7');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(submitted, isEmpty, reason: 'one character: too short');
  });

  testWidgets('#tag asks only for hashtags; @handle only for people', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byType(TextField));
    await type(tester, '#go');
    await tester.pump(debounce);
    await tester.pump();
    expect(repo.calls, ['trends:go']);
    await type(tester, '@bo');
    await tester.pump(debounce);
    await tester.pump();
    expect(repo.calls, ['trends:go', 'people:bo']);
  });

  testWidgets('RATE_LIMITED shows a quiet hint; Search for still works', (
    tester,
  ) async {
    repo.error = const SearchRateLimitedException();
    await open(tester);
    await tester.tap(find.byType(TextField));
    await type(tester, 'ab');
    await tester.pump(debounce);
    await tester.pump();
    await tester.pump();
    expect(find.text(kSearchRateLimitedHint), findsOneWidget);
    await tester.tap(find.text('Search for "ab"'));
    await tester.pump();
    expect(submitted, ['ab']);
  });

  testWidgets('FEATURE_DISABLED stops further people calls', (tester) async {
    repo.error = const SearchUnavailableException('search');
    await open(tester, features: const {'search'});
    await tester.tap(find.byType(TextField));
    await type(tester, 'ab');
    await tester.pump(debounce);
    await tester.pump();
    await type(tester, 'abc');
    await tester.pump(debounce);
    await tester.pump();
    expect(repo.peopleQueries, ['ab']);
  });

  testWidgets('arrows move, Enter picks the highlighted row, Escape closes', (
    tester,
  ) async {
    repo.peopleResult = SearchPeopleResult(users: [searchPerson('gopher')]);
    await open(tester, features: const {'search'});
    await tester.tap(find.byType(TextField));
    await type(tester, 'go');
    await tester.pump(debounce);
    await tester.pump();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(people, ['gopher'], reason: 'row 2 is the person');

    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.bySemanticsLabel('Search suggestions'), findsNothing);
  });

  forEachThemeAndWidth(
    'full overlay does not overflow',
    (tester, env) async {
      repo.peopleResult = SearchPeopleResult(
        users: [
          searchPerson(
            'a_very_long_handle',
            name: 'A very long display name that must ellipsize',
          ),
        ],
      );
      repo.trendsResult = TrendsResult(
        trends: [searchTrend('averyveryverylonghashtagthatgoesonandon', 99, 1)],
      );
      await open(
        tester,
        size: env.size,
        textScale: env.textScale,
        brightness: env.brightness,
      );
      await tester.tap(find.byType(TextField));
      await type(tester, 'a_very_long_query_that_wraps_when_scaled');
      await tester.pump(debounce);
      await tester.pump();
      await tester.pump();
      expect(find.bySemanticsLabel('Search suggestions'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    widths: const [360, 600, 1200],
    textScales: kMatrixTextScalesLarge,
  );
}
