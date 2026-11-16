import 'package:dzeroth/app/session_wiring.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/app_top_bar.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/home/presentation/home_screen.dart';
import 'package:dzeroth/features/timeline/presentation/timeline_feed_view.dart';
import 'package:dzeroth/features/home/presentation/widgets/pinned_timelines_button.dart';
import 'package:dzeroth/features/lists/data/home_tabs_repository.dart';
import 'package:dzeroth/features/lists/data/lists_repository.dart';
import 'package:dzeroth/features/lists/domain/home_tab_entry.dart';
import 'package:dzeroth/features/notifications/data/notifications_repository.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/push_cubit.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/push_opt_in_cubit.dart';
import 'package:dzeroth/features/notifications/presentation/notifications_screen.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'package:dzeroth/features/search/presentation/explore_screen.dart';
import 'package:dzeroth/features/timeline/data/timeline_repository.dart';
import 'package:dzeroth/features/timeline/data/timeline_store.dart';
import 'package:dzeroth/features/timeline/domain/feed_key.dart';
import 'package:dzeroth/shared/widgets/primitives/app_tab_bar.dart';
import 'package:dzeroth/gen/dzeroth/notifications/v1/notifications.pbenum.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/context_pane_rig.dart';
import '../../support/fake_push_messaging.dart';
import '../../support/fake_push_opt_in_store.dart';
import '../../support/messages_tablet_fixtures.dart';
import '../../support/messaging_flow_rig.dart';
import '../../support/notifications_fixtures.dart';
import '../../support/plans_tablet_rig.dart';
import '../../support/suggestions_fixtures.dart';
import '../../support/timeline_fixtures.dart';

// The five bottom-nav tab screens (Home, Explore, Notifications, Messages,
// Plans) draw ONE header: the floating AppTopBar (round avatar on a phone,
// the title, round AppTopBarActions at 48dp, the hairline), the same height,
// title style and colours at phone 390, tablet 900 and desktop 1440, in
// light and dark. Explore's title slot is its search field; Home's phone
// title is the centred wordmark.

class _MockNotifications extends Mock implements NotificationsRepository {}

class _MockTabs extends Mock implements HomeTabsRepository {}

class _MockLists extends Mock implements ListsRepository {}

class _MockGraph extends Mock implements GraphRepository {}

enum _Tab {
  home('Home'),
  explore('Explore'),
  notifications('Notifications'),
  messages('Messages'),
  plans('Plans');

  const _Tab(this.label);
  final String label;
}

const _sizes = <String, Size>{
  'phone': Size(390, 844),
  'tablet': Size(900, 800),
  'desktop': Size(1440, 900),
};

void main() {
  const feed = FeedKey.home();
  late _MockNotifications notifications;
  late _MockGraph graph;
  late MockTimelineRepository timeline;
  late MockPostsRepository posts;
  late PendingPostsCubit pending;
  late PushCubit push;
  late PushOptInCubit optIn;
  late _MockTabs tabs;

  setUpAll(() async {
    registerFallbackValue(const HomeTabEntry(kind: HomeTabKind.list, id: 'L1'));
  });

  setUp(() async {
    notifications = _MockNotifications();
    graph = _MockGraph();
    when(() => graph.followRequestsUnavailable).thenReturn(false);
    when(() => graph.cached(any())).thenReturn(null);
    when(() => graph.relationshipsFor(any())).thenAnswer((_) async => {});
    when(
      () => graph.listFollowRequests(
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer(
      (_) async => GraphPage(
        items: [for (var i = 1; i <= 3; i++) suggestedUser(i, userId: 'r$i')],
        nextPageToken: '',
      ),
    );
    when(() => notifications.enabled).thenReturn(true);
    when(() => notifications.sinceRefresh).thenReturn(null);
    when(() => notifications.sinceRefreshAttempt).thenReturn(null);
    when(() => notifications.rateLimitedFor()).thenReturn(null);
    when(() => notifications.markSeen(any()))
        .thenAnswer((_) async => kNotifBase);
    final notifs = snapshotOfNotifs([
      for (var i = 0; i < 14; i++)
        notif(
          'n$i',
          minutesAgo: 5 + i * 30,
          type: NotificationType.NOTIFICATION_TYPE_LIKE,
          postId: '${i + 1}',
          actorCount: 2,
        ),
    ]);
    when(() => notifications.cached()).thenAnswer((_) async => notifs);
    when(() => notifications.refresh()).thenAnswer((_) async => notifs);
    push = PushCubit(
      messaging: FakePushMessaging(supported: false),
      repository: notifications,
    );
    optIn = PushOptInCubit(store: FakePushOptInStore(), push: push);
    await optIn.load('uid-a');

    timeline = MockTimelineRepository();
    posts = MockPostsRepository();
    pending = PendingPostsCubit();
    tabs = _MockTabs();
    const pinned = [
      HomeTabEntry(kind: HomeTabKind.list, id: 'L1', title: 'Nearby'),
    ];
    when(() => tabs.tabs).thenReturn(pinned);
    when(() => tabs.changes).thenAnswer((_) => const Stream.empty());
    when(() => tabs.saving).thenReturn(false);
    when(() => tabs.writeUnavailable).thenReturn(false);
    when(() => tabs.isFull).thenReturn(false);
    when(() => tabs.needsLabel(any())).thenReturn(false);
    when(() => tabs.labelFor(any()))
        .thenAnswer((i) => (i.positionalArguments.first as HomeTabEntry).title);
    when(() => timeline.sinceRefresh(feed)).thenReturn(null);
    when(() => timeline.sinceRefreshAttempt(feed)).thenReturn(null);
    when(() => timeline.rateLimitedFor()).thenReturn(null);
    when(() => posts.removedPosts).thenAnswer((_) => const Stream.empty());
    final list = TimelineSnapshot(
      entries: [
        for (var i = 12; i >= 1; i--)
          postEntry(i, text: 'A post of the feed, number $i, to scroll past.'),
      ],
      sinceToken: 's',
      olderPageToken: '',
    );
    when(() => timeline.cached(feed)).thenAnswer((_) async => list);
    when(() => timeline.refresh(feed)).thenAnswer((_) async => list);
  });

  tearDown(() async {
    await pending.close();
    await optIn.close();
    await push.close();
  });

  Future<void> open(
    WidgetTester tester,
    _Tab tab,
    Size size, {
    Brightness brightness = Brightness.light,
    double textScale = 1,
    EdgeInsets padding = EdgeInsets.zero,
  }) async {
    switch (tab) {
      case _Tab.messages:
        final rig = MessagingFlowRig(
          server: tabletServer(now: DateTime.now().toUtc()),
          // `read_receipts`: Message settings, the header's action on a
          // phone (New message is the floating button there).
          flags: {...kMessagesTabletFlags, 'read_receipts'},
        );
        await rig.pump(
          tester,
          size: size,
          brightness: brightness,
          textScale: textScale,
          hoisted: true,
        );
      case _Tab.plans:
        final rig = PlansTabletRig();
        await rig.pump(
          tester,
          width: size.width,
          height: size.height,
          brightness: brightness,
          textScale: textScale,
        );
      case _Tab.home:
      case _Tab.explore:
      case _Tab.notifications:
        await ContextPaneRig().pump(
          tester,
          location: '/${tab == _Tab.home ? 'home' : tab.name}',
          width: size.width,
          height: size.height,
          brightness: brightness,
          textScale: textScale,
          padding: padding,
          flags: const {
            ...kContextPaneFlags,
            'lists',
            'notification_prefs',
            'private_accounts',
            'beacons',
          },
          pendingFollowRequests: 3,
          isProtected: true,
          page: (path) => switch (path) {
            '/home' => const HomeScreen(),
            '/explore' => const ExploreScreen(),
            '/notifications' => const NotificationsScreen(),
            _ => Text('$path body'),
          },
          wrap: (app) => MultiRepositoryProvider(
            providers: [
              RepositoryProvider<NotificationsRepository>.value(
                value: notifications,
              ),
              RepositoryProvider<GraphRepository>.value(value: graph),
              RepositoryProvider<UnexpectedErrorReporter>.value(
                value: (_, _) {},
              ),
              RepositoryProvider<TimelineRepository>.value(value: timeline),
              RepositoryProvider<PostsRepository>.value(value: posts),
              RepositoryProvider<HomeTabsRepository>.value(value: tabs),
              RepositoryProvider<ListsRepository>.value(value: _MockLists()),
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
    }
    await tester.pumpAndSettle();
  }

  /// The screen's app bar (the one inside the page, not the shell's).
  Finder bar() => find.byType(AppBar);

  for (final brightness in Brightness.values) {
    for (final MapEntry(key: device, value: size) in _sizes.entries) {
      final phone = size.width < 600;
      testWidgets('$device ${brightness.name}: one header on the five tab '
          'screens', (tester) async {
        final heights = <_Tab, double>{};
        // (kept simple: the bar is compared to its pane per screen)
        final avatars = <_Tab, Offset>{};
        final titleStyles = <_Tab, TextStyle>{};
        final colors = <_Tab, Color?>{};
        for (final tab in _Tab.values) {
          await open(tester, tab, size, brightness: brightness);
          expect(tester.takeException(), isNull, reason: tab.name);
          // One top bar per screen: the floating AppTopBar sliver.
          expect(bar(), findsOneWidget, reason: '${tab.name} has one bar');
          expect(find.byType(SliverAppBar), findsOneWidget);
          heights[tab] = tester.getSize(bar()).height;
          // The bar spans the whole pane, like the others (left and width).
          final barRect = tester.getRect(bar());
          final pane = tester.getRect(
            find.ancestor(of: bar(), matching: find.byType(Scaffold)).first,
          );
          expect(barRect.width, pane.width, reason: '${tab.name} bar width');
          expect(barRect.left, pane.left, reason: '${tab.name} bar left');
          // Semantics: the avatar is its own button; one header node per
          // titled bar; Explore's field is a text field, not a header.
          final handle = tester.ensureSemantics();
          final root = tester.getSemantics(bar());
          final nodes = <SemanticsNode>[];
          void walk(SemanticsNode n) {
            nodes.add(n);
            n.visitChildren((c) {
              walk(c);
              return true;
            });
          }

          walk(root);
          expect(
            nodes.where((n) => n.getSemanticsData().flagsCollection.isHeader),
            hasLength(tab == _Tab.explore ? 0 : 1),
            reason: '${tab.name} header nodes',
          );
          if (phone) {
            final avatar = nodes.where((n) => n.label == 'Open account menu');
            expect(avatar, hasLength(1), reason: '${tab.name} avatar node');
            expect(
              avatar.single.getSemanticsData().flagsCollection.isButton,
              isTrue,
            );
            expect(
              avatar.single.getSemanticsData().flagsCollection.isHeader,
              isFalse,
              reason: '${tab.name} avatar is not merged into the header',
            );
          }
          if (tab == _Tab.explore) {
            final field = nodes.where(
              (n) => n.getSemanticsData().flagsCollection.isTextField,
            );
            expect(field, isNotEmpty);
            expect(
              field.first.getSemanticsData().flagsCollection.isHeader,
              isFalse,
            );
          }
          handle.dispose();
          colors[tab] = tester
              .widget<SliverAppBar>(find.byType(SliverAppBar))
              .backgroundColor;
          if (phone) {
            expect(
              find.descendant(
                of: bar(),
                matching: find.byType(AppAvatarButton),
              ),
              findsOneWidget,
              reason: '${tab.name}: the round avatar leads',
            );
            avatars[tab] = tester.getTopLeft(find.byType(AppAvatarButton));
          } else {
            expect(find.byType(AppAvatarButton), findsNothing);
          }
          // Actions are the round AppTopBarAction at 48dp targets (Home's
          // Pinned timelines button is the same round disc in its own 48dp
          // hit area, with its own glyph).
          final actions = find.descendant(
            of: bar(),
            matching: tab == _Tab.home
                ? find.byType(PinnedTimelinesButton)
                : find.byType(AppTopBarAction),
          );
          expect(actions, findsWidgets, reason: '${tab.name} has actions');
          for (final a in actions.evaluate()) {
            final button = find.descendant(
              of: find.byWidget(a.widget),
              matching: find.byType(IconButton),
            );
            final target = tester.getSize(
              tab == _Tab.home ? find.byWidget(a.widget) : button,
            );
            expect(
              target,
              const Size(AppSpacing.minTapTarget, AppSpacing.minTapTarget),
              reason: '${tab.name} action target',
            );
          }
          // The title (Explore carries its search field instead; Home's
          // phone title is the centred wordmark).
          if (tab != _Tab.explore && !(phone && tab == _Tab.home)) {
            final title = find.descendant(
              of: bar(),
              matching: find.text(tab.label),
            );
            expect(title, findsOneWidget, reason: tab.label);
            titleStyles[tab] = tester.widget<Text>(title).style!;
            expect(tester.getRect(title).left, lessThan(size.width / 2));
          } else if (tab == _Tab.explore) {
            expect(
              find.descendant(of: bar(), matching: find.byType(TextField)),
              findsOneWidget,
            );
          } else {
            expect(
              find.descendant(of: bar(), matching: find.text('DZEROTH')),
              findsOneWidget,
            );
          }
        }
        // Identical bar: height, avatar offset, colour, title style.
        final first = heights.values.first;
        for (final e in heights.entries) {
          expect(e.value, first, reason: '${e.key.name} bar height');
        }
        for (final e in avatars.entries) {
          expect(e.value, avatars.values.first, reason: '${e.key.name} avatar');
        }
        for (final e in colors.entries) {
          expect(e.value, colors.values.first, reason: '${e.key.name} colour');
        }
        for (final e in titleStyles.entries) {
          expect(
            e.value,
            titleStyles.values.first,
            reason: '${e.key.name} title',
          );
        }
        expect(titleStyles, isNotEmpty);
      });
    }
  }

  // Hide on scroll down, back on scroll up: the floating, snapping bar. A
  // short window so every screen's content scrolls.
  for (final tab in _Tab.values) {
    testWidgets('${tab.label}: the header hides on scroll down and returns on '
        'scroll up', (tester) async {
      await open(tester, tab, const Size(390, 520));
      expect(find.byType(SliverAppBar), findsOneWidget);
      final shown = tester.getRect(bar());
      expect(shown.top, greaterThanOrEqualTo(0));
      final scrollable = find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.drag(scrollable, const Offset(0, -400));
      await tester.pumpAndSettle();
      // Scrolled out of the viewport: the bar is no longer built (or is
      // wholly above the screen).
      expect(
        bar().evaluate().isEmpty || tester.getRect(bar()).bottom <= 0,
        isTrue,
        reason: 'hidden after scrolling down',
      );
      // The tab bar stays pinned at the top while the header is away.
      final tabBar = find.byType(AppTabBar);
      if (tabBar.evaluate().isNotEmpty) {
        expect(tester.getRect(tabBar.first).top, closeTo(0, 0.5));
      }
      await tester.drag(scrollable, const Offset(0, 60));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(bar()).top,
        greaterThanOrEqualTo(shown.top - 0.5),
        reason: 'back after scrolling up (snap)',
      );
      if (tabBar.evaluate().isNotEmpty) {
        // Pinned right under the returned header.
        expect(
          tester.getRect(tabBar.first).top,
          closeTo(tester.getRect(bar()).bottom, 0.5),
        );
      }
    });
  }

  // Tablet: the pane has no outer SafeArea, so the pinned tab bar must keep
  // clear of the status bar once the top bar floated away.
  for (final tab in [_Tab.home, _Tab.explore, _Tab.notifications]) {
    testWidgets('${tab.label} at 900 dp with a 24 dp status bar: the pinned '
        'tabs stay below it', (tester) async {
      await open(
        tester,
        tab,
        const Size(900, 500),
        padding: const EdgeInsets.only(top: 24),
      );
      final tabBar = find.byType(AppTabBar);
      expect(tabBar, findsWidgets);
      // The bar is shown: the tabs sit right under it.
      expect(
        tester.getRect(tabBar.first).top,
        closeTo(tester.getRect(bar()).bottom, 0.5),
      );
      final scrollable = find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.drag(scrollable, const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(
        bar().evaluate().isEmpty || tester.getRect(bar()).bottom <= 24,
        isTrue,
      );
      expect(
        tester.getRect(tabBar.first).top,
        greaterThanOrEqualTo(24),
        reason: 'not under the status bar',
      );
    });
  }

  // The "N new posts" pill sits under the top bar and the pinned tab bar at
  // every text scale.
  for (final scale in [1.0, 1.3, 2.0]) {
    testWidgets('Home: the new-posts pill top clears the headers at text '
        'x$scale', (tester) async {
      await open(tester, _Tab.home, const Size(390, 844), textScale: scale);
      final below = tester
          .widget<TimelineFeedView>(find.byType(TimelineFeedView).first)
          .newPostsPillTop;
      final headersBottom = tester.getRect(find.byType(AppTabBar).first).bottom;
      expect(below - AppSpacing.sm, closeTo(headersBottom, 1.0));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Explore: a drag closes the open search suggestions', (
    tester,
  ) async {
    await open(tester, _Tab.explore, const Size(390, 520));
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    final field = find.byType(EditableText);
    expect(tester.widget<EditableText>(field).focusNode.hasFocus, isTrue);
    await tester.drag(
      find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first,
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
    expect(
      field.evaluate().isEmpty ||
          !tester.widget<EditableText>(field).focusNode.hasFocus,
      isTrue,
    );
  });

  // 320 dp and 2x text must not overflow.
  for (final tab in _Tab.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('${tab.label} at 320 dp, text x$scale: no overflow', (
        tester,
      ) async {
        await open(tester, tab, const Size(320, 700), textScale: scale);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
