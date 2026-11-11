import 'package:dzeroth/app/session_wiring.dart';
import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/widgets/app_top_bar.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/notifications/data/notifications_repository.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/push_cubit.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/push_opt_in_cubit.dart';
import 'package:dzeroth/features/notifications/presentation/notifications_screen.dart';
import 'package:dzeroth/features/notifications/presentation/widgets/follow_requests_row.dart';
import 'package:dzeroth/shared/widgets/primitives/app_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/context_pane_rig.dart';
import '../../../support/fake_push_messaging.dart';
import '../../../support/fake_push_opt_in_store.dart';
import '../../../support/geometry.dart';
import '../../../support/notifications_fixtures.dart';
import '../../../support/theme_harness.dart';

class _MockNotificationsRepository extends Mock
    implements NotificationsRepository {}

class _MockGraph extends Mock implements GraphRepository {}

/// Tablet plan T3, Notifications (section 4.1: A "F; FollowRequestsRow kept
/// inline at the top", B "P: list | What's happening"): the existing inline
/// row stays at the top of the list at every width, the pane beside it in
/// band B holds What's happening. (The F16 follow-requests card is not part
/// of T3.)
void main() {
  late _MockNotificationsRepository repo;
  late _MockGraph graphRepo;
  late PushCubit push;
  late PushOptInCubit optIn;

  setUp(() async {
    repo = _MockNotificationsRepository();
    graphRepo = _MockGraph();
    when(() => graphRepo.followRequestsUnavailable).thenReturn(false);
    when(() => repo.enabled).thenReturn(true);
    when(() => repo.sinceRefresh).thenReturn(null);
    when(() => repo.sinceRefreshAttempt).thenReturn(null);
    when(() => repo.rateLimitedFor()).thenReturn(null);
    when(() => repo.markSeen(any())).thenAnswer((_) async => kNotifBase);
    final list = snapshotOfNotifs([notif('a', minutesAgo: 1)]);
    when(() => repo.cached()).thenAnswer((_) async => list);
    when(() => repo.refresh()).thenAnswer((_) async => list);
    push = PushCubit(
      messaging: FakePushMessaging(supported: false),
      repository: repo,
    );
    optIn = PushOptInCubit(store: FakePushOptInStore(), push: push);
    await optIn.load('uid-a');
  });

  tearDown(() async {
    await optIn.close();
    await push.close();
  });

  Future<ContextPaneRig> open(
    WidgetTester tester, {
    required double width,
    double height = 768,
    Set<String> flags = const {...kContextPaneFlags, 'private_accounts'},
    int pending = 12,
    Brightness brightness = Brightness.light,
    double textScale = 1,
  }) async {
    final rig = ContextPaneRig();
    await rig.pump(
      tester,
      location: '/notifications',
      width: width,
      height: height,
      brightness: brightness,
      textScale: textScale,
      flags: flags,
      pendingFollowRequests: pending,
      isProtected: true,
      page: (path) => path == '/notifications'
          ? const NotificationsScreen()
          : Scaffold(
              appBar: const AppTopBar(title: 'Page'),
              body: Text('$path body'),
            ),
      wrap: (app) => MultiRepositoryProvider(
        providers: [
          RepositoryProvider<NotificationsRepository>.value(value: repo),
          RepositoryProvider<GraphRepository>.value(value: graphRepo),
          RepositoryProvider<UnexpectedErrorReporter>.value(value: (_, _) {}),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<PushCubit>.value(value: push),
            BlocProvider<PushOptInCubit>.value(value: optIn),
          ],
          child: app,
        ),
      ),
    );
    return rig;
  }

  Finder inScreen(Finder f) =>
      find.descendant(of: find.byType(NotificationsScreen), matching: f);

  for (final width in [600.0, 834.0, 840.0, 1024.0, 1199.0]) {
    final bandB = width >= 840;
    testWidgets('${width.toInt()} dp: the Follow requests row heads the list '
        '${bandB ? 'beside the pane (What\'s happening)' : '(no pane)'}', (
      tester,
    ) async {
      await open(tester, width: width);

      final row = inScreen(find.byType(FollowRequestsRow));
      expect(row, findsOneWidget);
      expect(find.text('Follow requests · 12'), findsOneWidget);
      // Right under the tab bar, above the first notification.
      final rowRect = tester.getRect(row);
      expect(
        rowRect.top,
        tester.getRect(inScreen(find.byType(AppTabBar))).bottom,
      );
      expectMinTarget(tester, row);
      // It stays in the primary pane; the pane never takes it over.
      expect(inContextPane(find.byType(FollowRequestsRow)), findsNothing);
      if (bandB) {
        expect(
          rowRect.right,
          lessThanOrEqualTo(tester.getRect(findContextPane()).left),
        );
        expect(inContextPane(find.text("What's happening")), findsOneWidget);
      } else {
        expect(findContextPane(), findsNothing);
      }
      expectNoOverflow(tester);
    });
  }

  testWidgets('band B: the row opens Follow requests', (tester) async {
    await open(tester, width: 1024);

    await tester.tap(find.text('Follow requests · 12'));
    await tester.pumpAndSettle();
    expect(find.text('/follow-requests body'), findsOneWidget);
    // Follow requests has its own pane: Who to follow.
    expect(inContextPane(find.text('Who to follow')), findsOneWidget);
  });

  testWidgets('band B keeps the row\'s own gating: no pending requests, no '
      'row; the pane is unchanged', (tester) async {
    await open(tester, width: 1024, pending: 0);

    expect(find.textContaining('Follow requests'), findsNothing);
    expect(inContextPane(find.text("What's happening")), findsOneWidget);
  });

  testWidgets('band B keeps the row\'s own gating: graph off, no row', (
    tester,
  ) async {
    await open(
      tester,
      width: 1024,
      flags: {...kContextPaneFlags}..remove('graph'),
    );

    expect(find.text('Follow requests · 12'), findsNothing);
  });

  testWidgets('ui_tablet off at 1024: the row as today, no pane', (
    tester,
  ) async {
    await open(
      tester,
      width: 1024,
      flags: {...kContextPaneFlags, 'private_accounts'}
        ..remove(kFeatureUiTablet),
    );

    expect(findContextPane(), findsNothing);
    expect(find.text('Follow requests · 12'), findsOneWidget);
  });

  // The tablet matrix (plan section 5.5): 5 widths x 2 scales x 2 themes,
  // and 840.
  forEachThemeAndWidth(
    'tablet matrix: the list and its Follow requests row fit the primary pane',
    (tester, env) async {
      await open(
        tester,
        width: env.size.width,
        height: env.size.height,
        brightness: env.brightness,
        textScale: env.textScale,
      );

      expectNoOverflow(tester);
      expectTabletPanes(
        tester,
        find.byType(NotificationsScreen),
        env.size.width,
      );
      final row = inScreen(find.byType(FollowRequestsRow));
      expect(row, findsOneWidget);
      expect(
        tester.getRect(row).top,
        tester.getRect(inScreen(find.byType(AppTabBar))).bottom,
      );
      expectMinTarget(tester, row);
      if (env.size.width >= 840) {
        expect(inContextPane(find.text("What's happening")), findsOneWidget);
      }
    },
    // Plus 840, the narrowest band B primary (439 dp).
    widths: [...kTabletMatrixWidths, 840],
    textScales: kTabletTextScales,
    heights: {...kTabletHeights, 840: 1194},
  );

  // T8e: the readable column. The tabs sit in the 680 column; their
  // hairline spans the pane (band A above 760: the only widths where the
  // column is narrower than the pane).
  for (final width in [600.0, 834.0, 839.0, 1024.0]) {
    testWidgets('${width.toInt()} dp: the tab bar in the column, its '
        'hairline across the pane', (tester) async {
      await open(tester, width: width);
      final primary = tester.getRect(
        find.byKey(const ValueKey('tablet-primary')),
      );
      final column = primary.width < 680 ? primary.width : 680.0;
      final bar = tester.getRect(inScreen(find.byType(AppTabBar)));
      expect(bar.width, moreOrLessEquals(column));
      expect(bar.center.dx, moreOrLessEquals(primary.center.dx));
      final bleed = (primary.width - column) / 2;
      final hairline = tester.renderObject(
        inScreen(find.byKey(AppTabBar.hairlineKey)),
      );
      if (bleed > 0) {
        expect(
          hairline,
          paints
            ..rect(rect: Rect.fromLTRB(-bleed, bar.height - 1, 0, bar.height))
            ..rect(
              rect: Rect.fromLTRB(
                bar.width,
                bar.height - 1,
                bar.width + bleed,
                bar.height,
              ),
            ),
        );
      } else {
        expect(hairline, isNot(paints..rect()));
      }
    });
  }
}
