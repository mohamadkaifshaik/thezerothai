import 'dart:io';
import 'dart:ui' as ui;

import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/search/data/search_repository.dart';
import 'package:dzeroth/features/search/domain/search_results_tab.dart';
import 'package:dzeroth/features/search/presentation/search_results_screen.dart';
import 'package:dzeroth/features/search/presentation/widgets/app_search_field.dart';
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/shared/widgets/post/post_card.dart';
import 'package:dzeroth/shared/widgets/primitives/app_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/app_fonts.dart';
import '../../../support/context_pane_rig.dart';
import '../../../support/fake_search_repository.dart';
import '../../../support/posts_fixtures.dart';
import '../../../support/search_field_rig.dart' show searchPerson, searchTrend;

class _MockGraph extends Mock implements GraphRepository {}

const _screenshots = bool.fromEnvironment('SEARCH_SCREENSHOTS');
final _captureKey = GlobalKey();

Future<void> _capture(WidgetTester tester, String name) async {
  if (!_screenshots) return;
  final boundary =
      _captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/artifacts/search/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

const _people = ['thirdwave', 'coffeeclub', 'coffeelab', 'coffeecart'];

FakeSearchRepository _results() => FakeSearchRepository()
  ..trendsResult = TrendsResult(
    trends: [for (var i = 1; i <= 4; i++) searchTrend('tag$i', 100 * i, i)],
    computedAt: DateTime.now().subtract(const Duration(hours: 2)),
  )
  ..peopleResult = SearchPeopleResult(
    users: [for (final handle in _people) searchPerson(handle)],
  )
  ..postsResult = SearchPostsPage(
    posts: [
      postView(1, text: 'Found the quietest café in Indiranagar. #coffee'),
      postView(2, text: "Cold brew Saturday? I'll make the #coffee plan."),
    ],
    normalizedTag: 'coffee',
  );

/// The SearchPeople and SearchPosts calls (the pane's GetTrends aside).
List<String> _searchCalls(FakeSearchRepository search) =>
    search.calls.where((c) => !c.startsWith('trends')).toList();

int _peopleCalls(FakeSearchRepository search) =>
    search.calls.where((c) => c.startsWith('people:')).length;

Finder _preview(String handle) =>
    find.byKey(ValueKey('search-preview-u-$handle'));

Finder _peopleRow(String handle) =>
    find.byKey(ValueKey('search-person-u-$handle'));

Finder get _viewAll => find.widgetWithText(TextButton, 'View all');

Future<void> _tapTab(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(of: find.byType(AppTabBar), matching: find.text(label)),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    if (_screenshots) await loadAppFonts();
  });

  Future<FakeSearchRepository> open(
    WidgetTester tester, {
    String query = 'coffee',
    SearchResultsTab tab = SearchResultsTab.top,
    Size size = const Size(390, 844),
    Brightness brightness = Brightness.light,
    Set<String> flags = kContextPaneFlags,
    FakeSearchRepository? search,
    GraphRepository? graphRepository,
  }) async {
    final repo = search ?? _results();
    final rig = ContextPaneRig(search: repo);
    await rig.pump(
      tester,
      location: '/search',
      width: size.width,
      height: size.height,
      brightness: brightness,
      flags: flags,
      wrap: (app) => MultiRepositoryProvider(
        providers: [
          RepositoryProvider<UnexpectedErrorReporter>.value(
            value: (error, stack) {},
          ),
          if (graphRepository != null)
            RepositoryProvider<GraphRepository>.value(value: graphRepository),
        ],
        child: RepaintBoundary(key: _captureKey, child: app),
      ),
      page: (_) => SearchResultsScreen(query: query, initialTab: tab),
    );
    return repo;
  }

  group('three looks, one screen', () {
    for (final brightness in Brightness.values) {
      for (final size in const [
        Size(390, 844),
        Size(768, 1024),
        Size(1024, 768),
        Size(1440, 900),
      ]) {
        final phone = size.width < 600;
        final desktop = size.width >= 1200;
        testWidgets(
          '${brightness.name} ${size.width.toInt()}: header, tabs, preview and posts',
          (tester) async {
            final search = await open(
              tester,
              size: size,
              brightness: brightness,
            );
            expect(tester.takeException(), isNull);
            // The same tabs, preview rows and posts at every width.
            for (final label in ['Top', 'Latest', 'People', 'Media']) {
              expect(
                find.descendant(
                  of: find.byType(AppTabBar),
                  matching: find.text(label),
                ),
                findsOneWidget,
              );
            }
            expect(find.text('People'), findsNWidgets(2));
            expect(_viewAll, findsOneWidget);
            for (final handle in _people.take(kSearchPeoplePreviewRows)) {
              expect(_preview(handle), findsOneWidget);
            }
            expect(_preview(_people.last), findsNothing);
            expect(find.byType(PostCard), findsNWidgets(2));
            expect(find.text(kSeeLatestLabel), findsOneWidget);
            expect(_peopleCalls(search), 1);
            // What differs: the raised pill on phones only, and no second
            // pill in the desktop side column (the page has its own).
            final fields = tester
                .widgetList<AppSearchField>(find.byType(AppSearchField))
                .toList();
            expect(fields, hasLength(1));
            expect(fields.single.raised, phone);
            if (desktop) {
              expect(find.text("What's happening"), findsOneWidget);
            }
            await _capture(
              tester,
              'top_${brightness.name}_${size.width.toInt()}',
            );
          },
        );
      }
    }

    for (final entry in kTabletFlagModes.entries) {
      testWidgets('1024 ${entry.key}: the preview and its rows', (
        tester,
      ) async {
        final search = await open(
          tester,
          size: const Size(1024, 768),
          flags: {...kContextPaneFlags.difference(_shellFlags), ...entry.value},
        );
        expect(tester.takeException(), isNull);
        expect(_viewAll, findsOneWidget);
        expect(_preview('thirdwave'), findsOneWidget);
        expect(_peopleCalls(search), 1);
      });
    }

    testWidgets('the side column keeps its pill away from search', (
      tester,
    ) async {
      final rig = ContextPaneRig(search: _results());
      await rig.pump(tester, location: '/home', width: 1440, height: 900);
      expect(find.byType(AppSearchField), findsOneWidget);
    });
  });

  group('one SearchPeople, shared by Top and People', () {
    testWidgets('a word: one people call, and View all asks nothing more', (
      tester,
    ) async {
      final search = await open(tester);
      expect(_searchCalls(search), [
        'people:coffee',
        'posts:#coffee:SEARCH_TAB_TOP',
      ]);
      await tester.tap(_viewAll);
      await tester.pumpAndSettle();
      expect(_peopleCalls(search), 1);
      for (final handle in _people) {
        expect(_peopleRow(handle), findsOneWidget);
      }
      await _tapTab(tester, 'Top');
      await _tapTab(tester, 'People');
      expect(_peopleCalls(search), 1);
    });

    testWidgets('a #tag: no people call on Top, nor on People', (tester) async {
      final search = await open(tester, query: '#coffee');
      expect(_peopleCalls(search), 0);
      expect(_viewAll, findsNothing);
      expect(find.byType(PostCard), findsNWidgets(2));
      await _tapTab(tester, 'People');
      expect(_peopleCalls(search), 0);
    });

    testWidgets('an @handle opens People; Top reuses its rows', (tester) async {
      final search = await open(
        tester,
        query: '@coffee',
        tab: SearchResultsTab.people,
      );
      expect(_peopleCalls(search), 1);
      await _tapTab(tester, 'Top');
      expect(_peopleCalls(search), 1);
      expect(_preview('thirdwave'), findsOneWidget);
    });

    testWidgets('pull to refresh on Top asks for the posts only', (
      tester,
    ) async {
      final search = await open(tester);
      final posts = search.calls.where((c) => c.startsWith('posts:')).length;
      await tester.fling(
        find.byType(PostCard).first,
        const Offset(0, 400),
        1000,
      );
      await tester.pumpAndSettle();
      expect(
        search.calls.where((c) => c.startsWith('posts:')).length,
        posts + 1,
      );
      expect(_peopleCalls(search), 1);
      expect(_preview('thirdwave'), findsOneWidget);
    });

    testWidgets('a failed people call hides the preview, not the posts', (
      tester,
    ) async {
      final failing = _FailingPeople(_results());
      await open(tester, search: failing);
      expect(tester.takeException(), isNull);
      expect(_viewAll, findsNothing);
      expect(find.byType(PostCard), findsNWidgets(2));
      // People shows the failure and its Retry.
      await _tapTab(tester, 'People');
      expect(find.text('Retry'), findsOneWidget);
      expect(_peopleCalls(failing), 1);
    });

    testWidgets('no people found: no preview, the posts as before', (
      tester,
    ) async {
      final search = _results()..peopleResult = const SearchPeopleResult();
      await open(tester, search: search);
      expect(_viewAll, findsNothing);
      expect(find.byType(PostCard), findsNWidgets(2));
    });
  });

  group('follow state', () {
    testWidgets('a follow in the preview shows on the People tab', (
      tester,
    ) async {
      final graphRepo = _MockGraph();
      when(
        () => graphRepo.follow(
          userId: any(named: 'userId'),
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenAnswer(
        (call) async => graph.Relationship(
          userId: call.namedArguments[#userId] as String,
          followState: graph.FollowState.FOLLOW_STATE_FOLLOWING,
        ),
      );
      await open(tester, graphRepository: graphRepo);
      await tester.tap(
        find.descendant(
          of: _preview('thirdwave'),
          matching: find.text('Follow'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: _preview('thirdwave'),
          matching: find.text('Following'),
        ),
        findsOneWidget,
      );
      await tester.tap(_viewAll);
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: _peopleRow('thirdwave'),
          matching: find.text('Following'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: _peopleRow('coffeeclub'),
          matching: find.text('Follow'),
        ),
        findsOneWidget,
      );
      verify(
        () => graphRepo.follow(
          userId: 'u-thirdwave',
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).called(1);
    });

    for (final size in const [Size(390, 844), Size(1440, 900)]) {
      testWidgets('${size.width.toInt()} without graph: no Follow anywhere', (
        tester,
      ) async {
        await open(
          tester,
          size: size,
          flags: kContextPaneFlags.difference({'graph'}),
        );
        expect(_preview('thirdwave'), findsOneWidget);
        expect(
          find.descendant(
            of: _preview('thirdwave'),
            matching: find.text('Follow'),
          ),
          findsNothing,
        );
        await tester.tap(_viewAll);
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: _peopleRow('thirdwave'),
            matching: find.text('Follow'),
          ),
          findsNothing,
        );
      });
    }
  });

  testWidgets('View all is announced as one button', (tester) async {
    final handle = tester.ensureSemantics();
    await open(tester);
    expect(
      tester.getSemantics(find.bySemanticsLabel('View all people')),
      isSemantics(isButton: true, hasTapAction: true),
    );
    handle.dispose();
  });
}

/// The shell flags of [kContextPaneFlags]; each flag mode replaces them.
final _shellFlags = kTabletFlagModes.values.expand((f) => f).toSet();

/// Every SearchPeople fails with a server error; posts and trends as [base].
class _FailingPeople extends FakeSearchRepository {
  _FailingPeople(FakeSearchRepository base) {
    trendsResult = base.trendsResult;
    postsResult = base.postsResult;
  }

  @override
  Future<SearchPeopleResult> searchPeople(String query, {int limit = 5}) async {
    calls.add('people:$query');
    throw const NetworkException('offline');
  }
}
