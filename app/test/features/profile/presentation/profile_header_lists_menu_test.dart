import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/lists/data/lists_repository.dart';
import 'package:dzeroth/features/moderation/data/moderation_repository.dart';
import 'package:dzeroth/features/profile/presentation/widgets/profile_header.dart';
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/lists/v1/lists.pb.dart' as pb;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

class _MockGraph extends Mock implements GraphRepository {}

class _MockModeration extends Mock implements ModerationRepository {}

class _MockLists extends Mock implements ListsRepository {}

/// W5-13: "Add or remove from Lists" and "View Lists" in the profile overflow
/// menu of another user, behind the `lists` flag.
void main() {
  late _MockLists lists;
  late String visited;
  Object? visitedExtra;

  setUp(() {
    lists = _MockLists();
    visited = '';
    visitedExtra = null;
    when(() => lists.enabled).thenReturn(true);
    when(
      () => lists.listUserLists(
        ownerId: any(named: 'ownerId'),
        containsUserId: any(named: 'containsUserId'),
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer(
      (_) async => ListsPage(
        lists: [pb.ListInfo(listId: 'l1', name: 'Friends', memberCount: 2)],
        containingListIds: const {'l1'},
      ),
    );
  });

  final profile = identity.Profile(
    userId: 'u-kaif',
    handle: 'kaif',
    displayName: 'Kaif Shaik',
  );

  Future<void> header(
    WidgetTester tester, {
    bool own = false,
    bool graphEnabled = true,
    bool blocking = false,
    bool listsEnabled = true,
    bool reportsEnabled = false,
    Size size = const Size(400, 800),
    double textScale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final graphRepository = _MockGraph();
    when(() => graphRepository.cached(any())).thenReturn(null);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, _) => Scaffold(
            body: SingleChildScrollView(
              child: ProfileHeader(
                profile: profile,
                isOwnProfile: own,
                graphEnabled: graphEnabled,
                listsEnabled: listsEnabled,
                reportsEnabled: reportsEnabled,
                relationship: own || !graphEnabled
                    ? null
                    : graph.Relationship(userId: 'u-kaif', blocking: blocking),
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/u/:userId/lists',
          builder: (context, state) {
            visited = state.uri.path;
            visitedExtra = state.extra;
            return const Scaffold(body: Text('user lists page'));
          },
        ),
        GoRoute(
          path: AppRouter.listsPath,
          builder: (context, state) => const Scaffold(body: Text('lists page')),
        ),
      ],
    );
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<GraphRepository>.value(value: graphRepository),
          RepositoryProvider<ModerationRepository>.value(
            value: _MockModeration(),
          ),
          RepositoryProvider<ListsRepository>.value(value: lists),
          RepositoryProvider<UnexpectedErrorReporter>.value(value: (e, s) {}),
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
    );
    await tester.pumpAndSettle();
  }

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Show menu'));
    await tester.pumpAndSettle();
  }

  const add = 'Add or remove from Lists';

  for (final graphEnabled in [true, false]) {
    group('graph ${graphEnabled ? 'on' : 'off'}', () {
      testWidgets('lists on: both rows', (tester) async {
        await header(tester, graphEnabled: graphEnabled);
        await openMenu(tester);
        expect(find.text(add), findsOneWidget);
        expect(find.text('View Lists'), findsOneWidget);
      });

      testWidgets('lists off: no menu rows', (tester) async {
        await header(tester, graphEnabled: graphEnabled, listsEnabled: false);
        // With the graph on the menu still holds Mute and Block.
        if (graphEnabled) await openMenu(tester);
        expect(find.text(add), findsNothing);
        expect(find.text('View Lists'), findsNothing);
      });

      testWidgets('own profile: no menu rows', (tester) async {
        await header(tester, own: true, graphEnabled: graphEnabled);
        expect(find.byTooltip('Show menu'), findsNothing);
      });

      testWidgets('View Lists opens /u/:id/lists with the handle', (
        tester,
      ) async {
        await header(tester, graphEnabled: graphEnabled);
        await openMenu(tester);
        await tester.tap(find.text('View Lists'));
        await tester.pumpAndSettle();
        expect(visited, '/u/u-kaif/lists');
        expect(visitedExtra, 'kaif');
      });

      testWidgets('Add opens the sheet with the person checked in the list', (
        tester,
      ) async {
        await header(tester, graphEnabled: graphEnabled);
        await openMenu(tester);
        await tester.tap(find.text(add));
        await tester.pumpAndSettle();
        expect(find.text('Add or remove @kaif'), findsOneWidget);
        expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
        verify(
          () => lists.listUserLists(
            containsUserId: 'u-kaif',
            pageSize: any(named: 'pageSize'),
            pageToken: any(named: 'pageToken'),
          ),
        ).called(1);
      });
    });
  }

  testWidgets('reports and lists share the menu', (tester) async {
    await header(tester, reportsEnabled: true);
    await openMenu(tester);
    expect(find.text(add), findsOneWidget);
    expect(find.text('Report @kaif'), findsOneWidget);
  });

  testWidgets('blocked by the viewer: View Lists only, no Add', (tester) async {
    await header(tester, blocking: true);
    await openMenu(tester);
    expect(find.text(add), findsNothing);
    expect(find.text('View Lists'), findsOneWidget);
  });

  testWidgets('large text on a narrow screen: no overflow', (tester) async {
    await header(
      tester,
      size: const Size(360, 800),
      textScale: 2.0,
      brightness: Brightness.dark,
    );
    await openMenu(tester);
    expect(tester.takeException(), isNull);
    expect(find.text(add), findsOneWidget);
  });
}
