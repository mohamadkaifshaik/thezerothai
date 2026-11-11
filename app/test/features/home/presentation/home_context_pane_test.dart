import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/app_top_bar.dart';
import 'package:dzeroth/features/graph/presentation/widgets/user_list_row.dart';
import 'package:dzeroth/features/graph/presentation/widgets/who_to_follow_card.dart';
import 'package:dzeroth/features/home/presentation/home_screen.dart';
import 'package:dzeroth/features/notifications/data/notifications_repository.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/push_cubit.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/push_opt_in_cubit.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'package:dzeroth/features/timeline/data/timeline_repository.dart';
import 'package:dzeroth/features/timeline/domain/feed_key.dart';
import 'package:dzeroth/shared/widgets/primitives/app_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/context_pane_rig.dart';
import '../../../support/fake_push_messaging.dart';
import '../../../support/fake_push_opt_in_store.dart';
import '../../../support/geometry.dart';
import '../../../support/theme_harness.dart';
import '../../../support/timeline_fixtures.dart';

class _MockNotificationsRepository extends Mock
    implements NotificationsRepository {}

/// Tablet plan T3, Home (section 4.1 Feed: A "F", B "P" with search, What's
/// happening and Who to follow in the pane): the real Home inside the real
/// shell. In band B its "Who to follow" lives in the pane only.
void main() {
  const feed = FeedKey.home();
  late MockTimelineRepository timeline;
  late MockPostsRepository posts;
  late PendingPostsCubit pending;
  late PushCubit push;
  late PushOptInCubit optIn;

  setUp(() {
    timeline = MockTimelineRepository();
    posts = MockPostsRepository();
    pending = PendingPostsCubit();
    final notifications = _MockNotificationsRepository();
    when(() => notifications.enabled).thenReturn(true);
    push = PushCubit(
      messaging: FakePushMessaging(supported: false),
      repository: notifications,
    );
    optIn = PushOptInCubit(store: FakePushOptInStore(), push: push);
    when(() => timeline.sinceRefresh(feed)).thenReturn(null);
    when(() => timeline.sinceRefreshAttempt(feed)).thenReturn(null);
    when(() => timeline.rateLimitedFor()).thenReturn(null);
    when(() => posts.removedPosts).thenAnswer((_) => const Stream.empty());
    // Long enough to scroll at every width.
    final list = snapshotOf([for (var i = 20; i >= 1; i--) i]);
    when(() => timeline.cached(feed)).thenAnswer((_) async => list);
    when(() => timeline.refresh(feed)).thenAnswer((_) async => list);
  });

  tearDown(() async {
    await pending.close();
    await optIn.close();
    await push.close();
  });

  Future<ContextPaneRig> open(
    WidgetTester tester, {
    double width = 1024,
    double height = 768,
    Brightness brightness = Brightness.light,
    double textScale = 1,
  }) async {
    final rig = ContextPaneRig();
    await rig.pump(
      tester,
      width: width,
      height: height,
      brightness: brightness,
      textScale: textScale,
      page: (path) => path == '/home'
          ? const HomeScreen()
          : Scaffold(
              appBar: const AppTopBar(title: 'Page'),
              body: Text('$path body'),
            ),
      wrap: (app) => MultiRepositoryProvider(
        providers: [
          RepositoryProvider<TimelineRepository>.value(value: timeline),
          RepositoryProvider<PostsRepository>.value(value: posts),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<PendingPostsCubit>.value(value: pending),
            BlocProvider<PushCubit>.value(value: push),
            BlocProvider<PushOptInCubit>.value(value: optIn),
          ],
          child: app,
        ),
      ),
    );
    return rig;
  }

  Finder inHome(Finder f) =>
      find.descendant(of: find.byType(HomeScreen), matching: f);

  testWidgets('band B (1024): the feed in the primary, Who to follow in the '
      'pane only', (tester) async {
    await open(tester);

    expect(find.text('post 20'), findsOneWidget);
    expect(inHome(find.byType(WhoToFollowCard)), findsNothing);
    expect(inContextPane(find.text('Who to follow')), findsOneWidget);
    expect(inContextPane(find.byType(UserListRow)), findsNWidgets(3));
    expectTabletPanes(tester, find.byType(HomeScreen), 1024);
  });

  testWidgets('band A (834): Who to follow inline, no pane', (tester) async {
    await open(tester, width: 834, height: 1194);

    expect(findContextPane(), findsNothing);
    expect(inHome(find.text('Who to follow')), findsOneWidget);
  });

  testWidgets('a resize across 840 keeps the feed and its scroll position; '
      'the card moves between the page and the pane', (tester) async {
    await open(tester, width: 1024, height: 768);
    final scrollable = inHome(find.byType(Scrollable)).first;
    final state = tester.state<ScrollableState>(scrollable);
    state.position.jumpTo(40);
    await tester.pump();

    for (final width in [839.0, 840.0, 1024.0]) {
      tester.view.physicalSize = Size(width, 768);
      await tester.pumpAndSettle();
      final bandB = width >= AppBreakpoints.expanded;
      expect(
        tester.state<ScrollableState>(inHome(find.byType(Scrollable)).first),
        same(state),
        reason: '$width',
      );
      expect(state.position.pixels, 40, reason: '$width');
      expect(
        inHome(find.byType(WhoToFollowCard)),
        bandB ? findsNothing : findsOneWidget,
        reason: '$width',
      );
      expect(
        inContextPane(find.byType(WhoToFollowCard)),
        bandB ? findsOneWidget : findsNothing,
        reason: '$width',
      );
      expectNoOverflow(tester);
    }
  });

  // The tablet matrix (plan section 5.5): 5 widths x 2 scales x 2 themes,
  // and 840.
  forEachThemeAndWidth(
    'tablet matrix: Home fits its pane, the card in one place',
    (tester, env) async {
      await open(
        tester,
        width: env.size.width,
        height: env.size.height,
        brightness: env.brightness,
        textScale: env.textScale,
      );

      expectNoOverflow(tester);
      expectTabletPanes(tester, find.byType(HomeScreen), env.size.width);
      final bandB = env.size.width >= AppBreakpoints.expanded;
      if (!bandB) {
        await tester.scrollUntilVisible(
          inHome(find.byType(WhoToFollowCard)),
          200,
          scrollable: inHome(find.byType(Scrollable)).first,
        );
        await tester.pumpAndSettle();
        expectNoOverflow(tester);
      }
      expect(find.byType(WhoToFollowCard), findsOneWidget);
      expect(
        inContextPane(find.byType(WhoToFollowCard)),
        bandB ? findsOneWidget : findsNothing,
      );
    },
    // Plus 840, the narrowest band B primary (439 dp).
    widths: [...kTabletMatrixWidths, 840],
    textScales: kTabletTextScales,
    heights: {...kTabletHeights, 840: 1194},
  );

  // T8e: the readable column. Home's tabs sit in the 680 column; their
  // hairline spans the pane (band A above 760, the only widths where the
  // column is narrower than the pane).
  for (final width in [600.0, 834.0, 839.0, 1024.0]) {
    testWidgets('${width.toInt()} dp: the tab bar in the column, its '
        'hairline across the pane', (tester) async {
      await open(tester, width: width, height: 1194);
      final primary = tester.getRect(
        find.byKey(const ValueKey('tablet-primary')),
      );
      final column = primary.width < 680 ? primary.width : 680.0;
      final bar = tester.getRect(inHome(find.byType(AppTabBar)).first);
      expect(bar.width, moreOrLessEquals(column));
      expect(bar.center.dx, moreOrLessEquals(primary.center.dx));
      final bleed = (primary.width - column) / 2;
      final hairline = tester.renderObject(
        inHome(find.byKey(AppTabBar.hairlineKey)).first,
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
