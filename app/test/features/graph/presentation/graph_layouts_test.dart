import 'dart:io';
import 'dart:ui' as ui;

import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/graph/presentation/follow_requests_screen.dart';
import 'package:dzeroth/features/graph/presentation/graph_list_screen.dart';
import 'package:dzeroth/features/graph/presentation/managed_accounts_screen.dart';
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/shared/widgets/primitives/app_back_header.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:dzeroth/shared/widgets/primitives/app_side_column.dart';
import 'package:dzeroth/shared/widgets/primitives/app_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/app_fonts.dart';
import '../../../support/context_pane_rig.dart';
import '../../../support/suggestions_fixtures.dart' show suggestedUser;

// Follow requests, Followers / Following and Blocked / Muted from the
// dzeroth-mobile, tablet and desktop mocks: one set of actions, three looks.
// A phone answers a request with round icons and the wide layouts with
// Decline / Accept pills; the desktop side column is the shell's, so the
// pages put nothing in it.

const _screenshots = bool.fromEnvironment('EXPLORE_PEOPLE_SCREENSHOTS');

Future<void> _capture(WidgetTester tester, String name) async {
  if (!_screenshots) return;
  await tester.runAsync(() async {
    final image = await captureImage(tester.element(find.byType(MaterialApp)));
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/artifacts/explore-people/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

const _sizes = <String, Size>{
  'phone': Size(390, 844),
  'tablet': Size(1024, 768),
  'desktop': Size(1440, 900),
};

class _MockGraph extends Mock implements GraphRepository {}

late _MockGraph _graph;

GraphPage _page() => GraphPage(
  items: [for (var i = 1; i <= 3; i++) suggestedUser(i)],
  nextPageToken: '',
);

void _stub() {
  _graph = _MockGraph();
  when(() => _graph.followRequestsUnavailable).thenReturn(false);
  for (final list in [
    _graph.listFollowRequests,
    _graph.listBlockedUsers,
    _graph.listMutedUsers,
  ]) {
    when(
      () => list(
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer((_) async => _page());
  }
  for (final list in [_graph.listFollowers, _graph.listFollowing]) {
    when(
      () => list(
        userId: any(named: 'userId'),
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer((_) async => _page());
  }
  when(
    () => _graph.respondToFollowRequest(
      requesterUserId: any(named: 'requesterUserId'),
      accept: any(named: 'accept'),
      idempotencyKey: any(named: 'idempotencyKey'),
    ),
  ).thenAnswer(
    (i) async => graph.Relationship(
      userId: i.namedArguments[#requesterUserId] as String,
      followState: graph.FollowState.FOLLOW_STATE_FOLLOWING,
    ),
  );
}

Widget _screen(String path) {
  final Widget screen;
  if (path == AppRouter.followRequestsPath) {
    screen = const FollowRequestsScreen();
  } else if (path == AppRouter.blockedAccountsPath) {
    screen = const BlockedAccountsScreen();
  } else if (path == AppRouter.mutedAccountsPath) {
    screen = const MutedAccountsScreen();
  } else {
    // The viewer's own list (u-alice), so Followers say "Follow back".
    screen = const GraphListScreen(
      handle: 'alice',
      userId: 'u-alice',
      viewerUserId: 'u-alice',
    );
  }
  return RepositoryProvider<GraphRepository>.value(
    value: _graph,
    child: screen,
  );
}

final _pages = <String, String>{
  'follow-requests': AppRouter.followRequestsPath,
  'followers': AppRouter.followersPath('alice'),
  'blocked': AppRouter.blockedAccountsPath,
  'muted': AppRouter.mutedAccountsPath,
};

Future<ContextPaneRig> _open(
  WidgetTester tester,
  String path,
  Size size, {
  double textScale = 1,
  Brightness brightness = Brightness.light,
}) async {
  _stub();
  final rig = ContextPaneRig();
  await rig.pump(
    tester,
    location: path,
    width: size.width,
    height: size.height,
    textScale: textScale,
    brightness: brightness,
    pendingFollowRequests: 3,
    page: _screen,
  );
  return rig;
}

/// Accept or Decline on the page itself (the side column has its own "x").
Finder _answer(String label) => find.descendant(
  of: find.byType(FollowRequestsScreen),
  matching: find.byWidgetPredicate(
    (w) =>
        (w is AppPillButton && w.label == label) ||
        (w is IconButton &&
            w.icon is Icon &&
            (w.icon as Icon).icon ==
                (label == 'Accept' ? Icons.check : Icons.close)),
  ),
);

void main() {
  setUpAll(() async {
    if (_screenshots) await loadAppFonts();
  });

  for (final MapEntry(key: name, value: size) in _sizes.entries) {
    final phone = size.width < 600;
    final desktop = size.width >= 1200;
    group('$name (${size.width.toInt()} dp)', () {
      testWidgets('Follow requests: pending count under the title, round '
          'answers on a phone and pills from 600 dp; Accept answers', (
        tester,
      ) async {
        await _open(tester, _pages['follow-requests']!, size);
        expect(find.text('3 pending'), findsOneWidget);
        expect(_answer('Accept'), findsNWidgets(3));
        expect(_answer('Decline'), findsNWidgets(3));
        expect(
          find.widgetWithText(AppPillButton, 'Accept'),
          phone ? findsNothing : findsNWidgets(3),
        );
        expect(
          find.descendant(
            of: find.byType(FollowRequestsScreen),
            matching: find.byIcon(Icons.check),
          ),
          phone ? findsNWidgets(3) : findsNothing,
        );
        await tester.tap(_answer('Accept').first);
        await tester.pumpAndSettle();
        verify(
          () => _graph.respondToFollowRequest(
            requesterUserId: 'u1',
            accept: true,
            idempotencyKey: any(named: 'idempotencyKey'),
          ),
        ).called(1);
        expect(
          find.descendant(
            of: find.byType(FollowRequestsScreen),
            matching: find.text('User 1'),
          ),
          findsNothing,
        );
        // The side column is the shell's: the page adds nothing to it.
        expect(
          find.byType(AppSideColumn),
          desktop ? findsOneWidget : findsNothing,
        );
      });

      testWidgets('Followers: their own list reads Follow back', (
        tester,
      ) async {
        await _open(tester, _pages['followers']!, size);
        expect(find.text('Follow back'), findsNWidgets(3));
        await tester.tap(find.text('Following').first);
        await tester.pumpAndSettle();
        expect(find.text('Follow back'), findsNothing);
      });

      testWidgets('Blocked | Muted: the tabs switch the list and the title', (
        tester,
      ) async {
        final rig = await _open(tester, _pages['blocked']!, size);
        expect(find.text('Blocked accounts'), findsOneWidget);
        expect(find.text('Unblock'), findsNWidgets(3));
        expect(find.byType(AppTabBar), findsOneWidget);
        await tester.tap(find.text('Muted'));
        await tester.pumpAndSettle();
        expect(rig.router.state.uri.path, AppRouter.mutedAccountsPath);
        expect(find.text('Muted accounts'), findsOneWidget);
        expect(find.text('Unmute'), findsNWidgets(3));
        expect(find.byType(AppBackHeader), findsOneWidget);
      });

      if (phone) {
        for (final MapEntry(key: page, value: path) in _pages.entries) {
          testWidgets('$page at text scale 2.0: nothing overflows', (
            tester,
          ) async {
            await _open(tester, path, size, textScale: 2);
            expect(tester.takeException(), isNull);
          });
        }
      }
    });
  }

  group('screenshots', () {
    for (final brightness in Brightness.values) {
      for (final MapEntry(key: name, value: size) in _sizes.entries) {
        for (final MapEntry(key: page, value: path) in _pages.entries) {
          testWidgets('$page $name ${brightness.name}', (tester) async {
            await _open(tester, path, size, brightness: brightness);
            await _capture(tester, '$page-$name-${brightness.name}');
          }, skip: !_screenshots);
        }
      }
    }
  });
}
