import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/feature_flags/service_feature_gate.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/storage/session_epoch.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/home/presentation/home_screen.dart';
import 'package:dzeroth/features/home/presentation/widgets/home_tabs_view.dart';
import 'package:dzeroth/features/lists/presentation/bloc/home_tabs_cubit.dart';
import 'package:dzeroth/features/lists/data/home_tabs_repository.dart';
import 'package:dzeroth/features/lists/data/lists_repository.dart';
import 'package:dzeroth/features/lists/presentation/manage_pinned_screen.dart';
import 'package:dzeroth/features/notifications/data/notifications_repository.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/push_cubit.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/push_opt_in_cubit.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'package:dzeroth/features/timeline/data/timeline_repository.dart';
import 'package:dzeroth/features/timeline/domain/feed_key.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/lists/v1/lists.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/timeline/v1/timeline.pb.dart' as tl;
import 'package:dzeroth/shared/widgets/app_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/fake_push_messaging.dart';
import '../../../support/fake_push_opt_in_store.dart';
import '../../../support/fake_transport.dart';
import '../../../support/theme_harness.dart';
import '../../../support/timeline_fixtures.dart';

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockNotifications extends Mock implements NotificationsRepository {}

class _MockLists extends Mock implements ListsRepository {}

common.HomeTab _wire(String id, [String title = '']) => common.HomeTab(
  kind: common.HomeTabKind.HOME_TAB_KIND_LIST,
  id: id,
  title: title,
);

pb.ListInfo _info(String id, String name) =>
    pb.ListInfo(listId: id, name: name, memberCount: 2);

/// W5-14: the Home tab bar with pinned Lists and Manage pinned.
void main() {
  const home = FeedKey.home();
  final friends = FeedKey.list('L1');
  final mutuals = FeedKey.list('L2');

  late MockTimelineRepository timeline;
  late MockPostsRepository posts;
  late _MockLists lists;
  late _MockOnboarding onboarding;
  late PendingPostsCubit pending;
  late FakePushMessaging pushMessaging;
  late PushCubit push;
  late PushOptInCubit optIn;
  late SessionEpoch epoch;
  late HomeTabsRepository tabs;
  late FakeTransport transport;
  late List<tl.SetHomeTabsRequest> sent;
  late List<pb.ListInfo> ownLists;
  Object? Function(tl.SetHomeTabsRequest) answer = (_) => null;

  setUp(() {
    timeline = MockTimelineRepository();
    posts = MockPostsRepository();
    lists = _MockLists();
    onboarding = _MockOnboarding();
    pending = PendingPostsCubit();
    pushMessaging = FakePushMessaging();
    final notifications = _MockNotifications();
    when(() => notifications.enabled).thenReturn(true);
    push = PushCubit(messaging: pushMessaging, repository: notifications);
    optIn = PushOptInCubit(store: FakePushOptInStore(), push: push);
    epoch = SessionEpoch();
    sent = [];
    answer = (r) => tl.SetHomeTabsResponse(tabs: r.tabs);
    ownLists = [_info('L1', 'Friends'), _info('L2', 'Mutuals')];
    transport = FakeTransport((procedure, input) async {
      final request = input as tl.SetHomeTabsRequest;
      sent.add(request);
      final r = answer(request);
      if (r is Exception) throw r;
      return r!;
    });
    tabs = HomeTabsRepository(
      apiClient: ApiClient.withTransport(transport),
      gate: ServiceFeatureGate(
        isEnabled: () => true,
        onUnexpectedError: (_, _) {},
      ),
      epoch: epoch,
    );
    when(() => posts.removedPosts).thenAnswer((_) => const Stream.empty());
    when(() => timeline.rateLimitedFor()).thenReturn(null);
    when(
      () => lists.listUserLists(
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer((_) async => ListsPage(lists: ownLists));
    when(() => lists.getList(any())).thenAnswer((i) async {
      final id = i.positionalArguments.first as String;
      return _info(id, 'Named $id');
    });
    for (final feed in [home, friends, mutuals]) {
      when(() => timeline.sinceRefresh(feed)).thenReturn(null);
      // A tab refreshed moments ago: the tick must not ask again.
      when(() => timeline.sinceRefreshAttempt(feed))
          .thenReturn(const Duration(seconds: 5));
    }
    void serve(FeedKey feed, List<int> ids) {
      when(() => timeline.cached(feed))
          .thenAnswer((_) async => snapshotOf(ids));
      when(() => timeline.refresh(feed))
          .thenAnswer((_) async => snapshotOf(ids));
    }

    serve(home, [3, 2, 1]);
    serve(friends, [11, 10]);
    serve(mutuals, [21]);
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        profile: identity.Profile(userId: 'me', handle: 'me'),
        enabledFeatures: const {'posts', 'lists', 'ui_shell'},
      ),
    );
    tabs.adoptFromMe([
      _wire('L1', 'Friends'),
      _wire('L2', 'Mutuals'),
    ], epoch: epoch.value);
  });

  tearDown(() async {
    await pending.close();
    await optIn.close();
    await push.close();
  });

  void withFeatures(Set<String> features) => whenListen(
    onboarding,
    const Stream<OnboardingState>.empty(),
    initialState: OnboardingState(
      status: OnboardingStatus.ready,
      profile: identity.Profile(userId: 'me', handle: 'me'),
      enabledFeatures: features,
    ),
  );

  Widget app(
    Widget Function() screen, {
    Brightness b = Brightness.light,
    double scale = 1,
  }) {
    final router = GoRouter(
      initialLocation: '/home',
      routes: [
        GoRoute(path: '/home', builder: (_, _) => screen()),
        GoRoute(
          path: '/home/pinned',
          builder: (_, _) => const ManagePinnedScreen(),
        ),
      ],
    );
    return MultiRepositoryProvider(
      providers: [
        RepositoryProvider<TimelineRepository>.value(value: timeline),
        RepositoryProvider<PostsRepository>.value(value: posts),
        RepositoryProvider<ListsRepository>.value(value: lists),
        RepositoryProvider<HomeTabsRepository>.value(value: tabs),
      ],
      child: MultiBlocProvider(
        providers: [
          BlocProvider<OnboardingBloc>.value(value: onboarding),
          BlocProvider<PendingPostsCubit>.value(value: pending),
          BlocProvider<PushCubit>.value(value: push),
          BlocProvider<PushOptInCubit>.value(value: optIn),
        ],
        child: MaterialApp.router(
          theme: buildAppTheme(brightness: b),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          routerConfig: router,
        ),
      ),
    );
  }

  Future<void> openHome(
    WidgetTester tester, {
    Size size = const Size(400, 900),
    Brightness brightness = Brightness.light,
    double scale = 1,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      app(() => const HomeScreen(), b: brightness, scale: scale),
    );
    await tester.pumpAndSettle();
  }

  group('lists and ui_shell on', () {
    forEachThemeAndWidth('three tabs and a 48dp plus fit without overflow', (
      tester,
      env,
    ) async {
      await openHome(
        tester,
        size: env.size,
        brightness: env.brightness,
        scale: env.textScale,
      );

      expect(tester.takeException(), isNull);
      expect(find.byType(AppTabBar), findsOneWidget);
      expect(find.text('Following'), findsOneWidget);
      // The pinned tabs are built labels in the (scrolling) bar.
      expect(find.text('Friends', skipOffstage: false), findsOneWidget);
      expect(find.text('Mutuals', skipOffstage: false), findsOneWidget);
      final plus = find.byTooltip('Manage pinned timelines');
      expect(plus, findsOneWidget);
      expect(tester.getSize(plus).width, greaterThanOrEqualTo(48));
      expect(tester.getSize(plus).height, greaterThanOrEqualTo(48));
      expect(find.text('post 3'), findsOneWidget);
    }, textScales: kMatrixTextScalesLarge);

    testWidgets('no list timeline is asked for before its tab is opened', (
      tester,
    ) async {
      await openHome(tester);

      verifyNever(() => timeline.cached(friends));
      verifyNever(() => timeline.refresh(friends));
      verifyNever(() => timeline.cached(mutuals));
      expect(transport.calledProcedures, isEmpty);
    });

    testWidgets('a tab is read once on first visit and keeps its scroll', (
      tester,
    ) async {
      final many = [for (var i = 60; i > 0; i--) i];
      when(() => timeline.cached(home))
          .thenAnswer((_) async => snapshotOf(many));
      when(() => timeline.refresh(home))
          .thenAnswer((_) async => snapshotOf(many));
      final longList = [for (var i = 200; i > 140; i--) i];
      when(() => timeline.cached(friends))
          .thenAnswer((_) async => snapshotOf(longList));
      when(() => timeline.refresh(friends))
          .thenAnswer((_) async => snapshotOf(longList));
      await openHome(tester);
      final vertical = find.byWidgetPredicate(
        (w) => w is Scrollable && w.axis == Axis.vertical,
      );

      await tester.drag(vertical, const Offset(0, -900));
      await tester.pumpAndSettle();
      final offset = tester.state<ScrollableState>(vertical).position.pixels;
      expect(offset, greaterThan(300));

      await _select(tester, 'list:L1');
      await tester.pumpAndSettle();
      expect(find.text('post 200'), findsOneWidget);
      expect(find.text('post 60'), findsNothing);
      await tester.drag(vertical, const Offset(0, -900));
      await tester.pumpAndSettle();
      final friendsOffset = tester
          .state<ScrollableState>(vertical)
          .position
          .pixels;
      expect(friendsOffset, greaterThan(300));

      await _select(tester, 'following');
      await tester.pumpAndSettle();
      expect(
        tester.state<ScrollableState>(vertical).position.pixels,
        offset,
        reason: 'Following keeps its offset while another tab is shown',
      );

      await _select(tester, 'list:L1');
      await tester.pumpAndSettle();
      expect(
        tester.state<ScrollableState>(vertical).position.pixels,
        friendsOffset,
        reason: 'the List tab keeps its offset too',
      );
      await _select(tester, 'following');
      await tester.pumpAndSettle();
      await _select(tester, 'list:L1');
      await tester.pumpAndSettle();

      verify(() => timeline.cached(friends)).called(1);
      verify(() => timeline.refresh(friends)).called(1);
      verifyNever(() => timeline.cached(mutuals));
      expect(transport.calledProcedures, isEmpty);
    });

    testWidgets('a hidden tab does not tick; the visible one does', (
      tester,
    ) async {
      await openHome(tester);
      await tester.tap(find.text('Friends'));
      await tester.pumpAndSettle();
      // Both feeds are "stale" for the tick from here on.
      when(() => timeline.sinceRefreshAttempt(home)).thenReturn(null);
      when(() => timeline.sinceRefreshAttempt(friends)).thenReturn(null);
      clearInteractions(timeline);

      await tester.pump(const Duration(seconds: 31));

      verify(() => timeline.refresh(friends)).called(1);
      verifyNever(() => timeline.refresh(home));
    });

    testWidgets('arrow keys move across the tabs', (tester) async {
      await openHome(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();

      expect(find.text('post 11'), findsOneWidget);
      // Each tab has its own bar (it scrolls with its feed), so focus starts
      // again with Tab in the newly shown one.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(find.text('post 3'), findsOneWidget);
    });

    testWidgets('an unavailable List shows the state with Unpin', (
      tester,
    ) async {
      when(() => timeline.refresh(friends))
          .thenThrow(const NotFoundException('gone'));
      when(() => timeline.cached(friends))
          .thenAnswer((_) async => snapshotOf([]));
      await openHome(tester);

      await tester.tap(find.text('Friends'));
      await tester.pumpAndSettle();
      expect(find.text('This List is unavailable'), findsOneWidget);
      expect(find.text('Unpin from Home'), findsOneWidget);

      await tester.tap(find.text('Unpin from Home'));
      await tester.pumpAndSettle();

      expect(sent, hasLength(1));
      expect([for (final t in sent.single.tabs) t.id], ['L2']);
      // The selection falls back to Following.
      expect(find.text('post 3'), findsOneWidget);
      expect(find.text('Friends'), findsNothing);
    });

    testWidgets('an unlabelled tab costs one GetList, once', (tester) async {
      tabs.clearSession();
      tabs.adoptFromMe([_wire('L9')], epoch: epoch.value);
      when(() => timeline.sinceRefresh(FeedKey.list('L9'))).thenReturn(null);
      await openHome(tester);

      verify(() => lists.getList('L9')).called(1);
    });

    testWidgets('"+" opens Manage pinned', (tester) async {
      await openHome(tester);

      await tester.tap(find.byTooltip('Manage pinned timelines'));
      await tester.pumpAndSettle();

      expect(find.text('Manage pinned'), findsOneWidget);
      expect(find.text('Add from your Lists'), findsOneWidget);
    });
  });

  group('flags off: Home is as before and makes no Lists call', () {
    testWidgets('lists off: only Following, nothing Lists is touched', (
      tester,
    ) async {
      withFeatures(const {'posts', 'ui_shell'});
      await openHome(tester);

      expect(find.text('Following'), findsOneWidget);
      expect(find.text('Friends', skipOffstage: false), findsNothing);
      expect(find.byTooltip('Manage pinned timelines'), findsNothing);
      expect(find.text('post 3'), findsOneWidget);
      expect(transport.calledProcedures, isEmpty);
      verifyNever(() => timeline.cached(friends));
      verifyNever(() => timeline.refresh(friends));
      verifyNever(() => lists.getList(any()));
      verifyNever(
        () => lists.listUserLists(
          pageSize: any(named: 'pageSize'),
          pageToken: any(named: 'pageToken'),
        ),
      );
    });

    testWidgets('ui_shell off: the legacy header keeps one tab', (
      tester,
    ) async {
      withFeatures(const {'posts', 'lists'});
      await openHome(tester);

      expect(find.text('Following'), findsOneWidget);
      expect(find.text('Friends', skipOffstage: false), findsNothing);
      expect(find.byTooltip('Manage pinned timelines'), findsNothing);
      expect(transport.calledProcedures, isEmpty);
      verifyNever(() => timeline.cached(friends));
    });

    testWidgets('lists off without the Lists repositories provided', (
      tester,
    ) async {
      withFeatures(const {'posts'});
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(400, 900);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: [
            RepositoryProvider<TimelineRepository>.value(value: timeline),
            RepositoryProvider<PostsRepository>.value(value: posts),
          ],
          child: MultiBlocProvider(
            providers: [
              BlocProvider<OnboardingBloc>.value(value: onboarding),
              BlocProvider<PendingPostsCubit>.value(value: pending),
              BlocProvider<PushCubit>.value(value: push),
              BlocProvider<PushOptInCubit>.value(value: optIn),
            ],
            child: MaterialApp(theme: appLightTheme, home: const HomeScreen()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('post 3'), findsOneWidget);
    });
  });

  group('Manage pinned', () {
    Future<void> openManage(
      WidgetTester tester, {
      Size size = const Size(400, 900),
      Brightness brightness = Brightness.light,
      double scale = 1,
    }) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        app(() => const ManagePinnedScreen(), b: brightness, scale: scale),
      );
      await tester.pumpAndSettle();
    }

    forEachThemeAndWidth('rows, handles and Unpin fit; targets are 48dp', (
      tester,
      env,
    ) async {
      ownLists = [..._ownBase(), _info('L3', 'Readers')];
      await openManage(
        tester,
        size: env.size,
        brightness: env.brightness,
        scale: env.textScale,
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Following'), findsOneWidget);
      expect(find.text('Friends'), findsOneWidget);
      expect(find.text('Mutuals'), findsOneWidget);
      // Only the list that is not pinned is offered.
      expect(find.byTooltip('Pin Readers to Home'), findsOneWidget);
      for (final tip in ['Unpin Friends', 'Pin Readers to Home']) {
        final size = tester.getSize(find.byTooltip(tip));
        expect(size.width, greaterThanOrEqualTo(48));
        expect(size.height, greaterThanOrEqualTo(48));
      }
      expect(
        tester.getSize(find.byIcon(Icons.drag_handle).first).height,
        greaterThanOrEqualTo(48),
      );
    }, textScales: kMatrixTextScalesLarge);

    testWidgets('a drag reorder sends exactly one SetHomeTabs', (tester) async {
      await openManage(tester);

      await tester.drag(
        find.byIcon(Icons.drag_handle).first,
        const Offset(0, 120),
      );
      await tester.pumpAndSettle();

      expect(sent, hasLength(1));
      expect([for (final t in sent.single.tabs) t.id], ['L2', 'L1']);
      expect(sent.single.idempotencyKey, isNotEmpty);
    });

    testWidgets('Move down is a semantic action and sends one SetHomeTabs', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await openManage(tester);

      final node = tester.getSemantics(
        find.byWidgetPredicate(
          (w) =>
              w is Semantics &&
              w.properties.label == 'Friends' &&
              w.properties.customSemanticsActions != null,
        ),
      );
      final ids = node.getSemanticsData().customSemanticsActionIds ?? const [];
      final labels = [
        for (final id in ids) CustomSemanticsAction.getAction(id)!.label,
      ];
      expect(labels, ['Move down']);
      tester.semantics.performAction(
        find.semantics.byPredicate((n) => n.id == node.id),
        SemanticsAction.customAction,
        args: ids.single,
      );
      await tester.pumpAndSettle();

      expect(sent, hasLength(1));
      expect([for (final t in sent.single.tabs) t.id], ['L2', 'L1']);
      semantics.dispose();
    });

    testWidgets('Unpin sends one SetHomeTabs and offers the list again', (
      tester,
    ) async {
      await openManage(tester);

      await tester.tap(find.byTooltip('Unpin Friends'));
      await tester.pumpAndSettle();

      expect(sent, hasLength(1));
      expect([for (final t in sent.single.tabs) t.id], ['L2']);
      expect(find.byTooltip('Pin Friends to Home'), findsOneWidget);
    });

    testWidgets('Pin appends; a failure rolls back with a message', (
      tester,
    ) async {
      tabs.clearSession();
      tabs.adoptFromMe([_wire('L1', 'Friends')], epoch: epoch.value);
      answer = (_) => connect.ConnectException(connect.Code.unavailable, 'x');
      await openManage(tester);

      await tester.tap(find.byTooltip('Pin Mutuals to Home'));
      await tester.pumpAndSettle();

      expect(sent, hasLength(1));
      expect([for (final t in sent.single.tabs) t.id], ['L1', 'L2']);
      expect(find.byType(SnackBar), findsOneWidget);
      // Rolled back: Mutuals is offered again, not listed as pinned.
      expect(find.byTooltip('Pin Mutuals to Home'), findsOneWidget);
      expect(find.byTooltip('Unpin Mutuals'), findsNothing);
    });

    testWidgets('at five pins, Pin is disabled with the reason', (
      tester,
    ) async {
      tabs.clearSession();
      tabs.adoptFromMe([
        for (var i = 1; i <= 5; i++) _wire('P$i', 'Pinned $i'),
      ], epoch: epoch.value);
      ownLists = [..._ownBase(), _info('L3', 'Readers')];
      await openManage(tester);

      expect(find.textContaining('the most allowed'), findsOneWidget);
      final pin = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.push_pin_outlined).first,
      );
      expect(pin.onPressed, isNull);
      expect(sent, isEmpty);
    });

    testWidgets('empty: guidance when nothing is pinned', (tester) async {
      tabs.clearSession();
      await openManage(tester);

      expect(find.textContaining('Nothing pinned yet'), findsOneWidget);
    });
  });
}

List<pb.ListInfo> _ownBase() => [
  _info('L1', 'Friends'),
  _info('L2', 'Mutuals'),
];

/// Shows a Home tab by key without its tab bar: after a scroll the bar is out
/// of view (the header scrolls away, as before).
Future<void> _select(WidgetTester tester, String key) async {
  tester.element(find.byType(HomeTabsView)).read<HomeTabsCubit>().select(key);
  await tester.pumpAndSettle();
}
