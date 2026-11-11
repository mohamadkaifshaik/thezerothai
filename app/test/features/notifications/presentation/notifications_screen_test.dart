import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/notifications/data/notifications_repository.dart';
import 'package:dzeroth/features/notifications/data/notifications_store.dart';
import 'package:dzeroth/features/notifications/data/push_messaging.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/push_cubit.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/push_opt_in_cubit.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/unread_badge_cubit.dart';
import 'package:dzeroth/features/notifications/presentation/notifications_screen.dart';
import 'package:dzeroth/features/notifications/presentation/widgets/notification_row.dart';
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/notifications/v1/notifications.pb.dart'
    as pb;
import 'package:dzeroth/gen/dzeroth/notifications/v1/notifications.pbenum.dart';
import 'package:dzeroth/shared/widgets/primitives/app_notice_banner.dart';
import 'package:dzeroth/shared/widgets/primitives/app_surface.dart';
import 'package:dzeroth/shared/widgets/primitives/app_tab_bar.dart';
import 'package:dzeroth/shared/widgets/primitives/app_tile_icon.dart';
import 'package:dzeroth/shared/widgets/user/follow_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/fake_push_messaging.dart';
import '../../../support/fake_push_opt_in_store.dart';
import '../../../support/notifications_fixtures.dart';

class MockNotificationsRepository extends Mock
    implements NotificationsRepository {}

class MockGraphRepository extends Mock implements GraphRepository {}

class MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

void main() {
  late MockNotificationsRepository repo;
  late MockOnboardingBloc onboarding;
  late MockGraphRepository graphRepo;
  late UnreadBadgeCubit badge;
  late FakePushMessaging messaging;
  late PushCubit push;
  late PushOptInCubit optIn;
  late FakePushOptInStore optInStore;
  late List<String> visited;

  setUpAll(() {
    registerFallbackValue(DevicePlatform.DEVICE_PLATFORM_ANDROID);
    registerFallbackValue(<String>[]);
  });

  setUp(() {
    repo = MockNotificationsRepository();
    onboarding = MockOnboardingBloc();
    graphRepo = MockGraphRepository();
    when(() => graphRepo.followRequestsUnavailable).thenReturn(false);
    when(() => graphRepo.cached(any())).thenReturn(null);
    badge = UnreadBadgeCubit();
    messaging = FakePushMessaging(supported: false);
    push = PushCubit(messaging: messaging, repository: repo);
    optInStore = FakePushOptInStore();
    optIn = PushOptInCubit(store: optInStore, push: push);
    visited = [];
    when(() => repo.enabled).thenReturn(true);
    when(() => repo.sinceRefresh).thenReturn(null);
    when(() => repo.sinceRefreshAttempt).thenReturn(null);
    when(() => repo.rateLimitedFor()).thenReturn(null);
    when(() => repo.markSeen(any())).thenAnswer((_) async => kNotifBase);
  });

  tearDown(() async {
    await optIn.close();
    await push.close();
    await badge.close();
  });

  Future<void> open(
    WidgetTester tester, {
    Set<String> features = const {'notifications'},
    ThemeData? theme,
    Size size = const Size(400, 800),
    double textScale = 1,
    bool settle = true,
    TextDirection textDirection = TextDirection.ltr,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(enabledFeatures: features),
    );
    await optIn.close();
    optIn = PushOptInCubit(store: optInStore, push: push);
    await optIn.load('uid-a');
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const NotificationsScreen(),
        ),
        GoRoute(
          path: '/post/:id',
          builder: (context, state) {
            visited.add('/post/${state.pathParameters['id']}');
            return const Scaffold(body: Text('post page'));
          },
        ),
        GoRoute(
          path: '/follow-requests',
          builder: (context, state) {
            visited.add('/follow-requests');
            return const Scaffold(body: Text('requests page'));
          },
        ),
        GoRoute(
          path: '/u/:userId',
          builder: (context, state) {
            visited.add('/u/${state.pathParameters['userId']}');
            return const Scaffold(body: Text('profile page'));
          },
        ),
        GoRoute(
          path: '/plans/:id',
          builder: (context, state) {
            visited.add('/plans/${state.pathParameters['id']}');
            return const Scaffold(body: Text('plan page'));
          },
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<NotificationsRepository>.value(value: repo),
          RepositoryProvider<GraphRepository>.value(value: graphRepo),
          RepositoryProvider<UnexpectedErrorReporter>.value(value: (_, _) {}),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<OnboardingBloc>.value(value: onboarding),
            BlocProvider<UnreadBadgeCubit>.value(value: badge),
            BlocProvider<PushCubit>.value(value: push),
            BlocProvider<PushOptInCubit>.value(value: optIn),
          ],
          child: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(textScale),
            ),
            child: MaterialApp.router(
              theme: theme ?? appLightTheme,
              routerConfig: router,
              builder: (context, child) =>
                  Directionality(textDirection: textDirection, child: child!),
            ),
          ),
        ),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump();
    }
  }

  void stubList(NotificationsSnapshot s, {NotificationsSnapshot? refreshed}) {
    when(() => repo.cached()).thenAnswer((_) async => s);
    when(() => repo.refresh()).thenAnswer((_) async => refreshed ?? s);
  }

  testWidgets('flag off: placeholder, no RPC', (tester) async {
    await open(tester, features: const {});

    expect(find.text("Notifications aren't available yet"), findsOneWidget);
    verifyNever(() => repo.cached());
    verifyNever(() => repo.refresh());
  });

  testWidgets('loading: skeleton while the first fetch runs', (tester) async {
    when(() => repo.cached()).thenAnswer((_) async => snapshotOfNotifs([]));
    final never = Completer<NotificationsSnapshot>();
    when(() => repo.refresh()).thenAnswer((_) => never.future);

    await open(tester, settle: false);

    expect(find.bySemanticsLabel('Loading notifications'), findsOneWidget);
  });

  testWidgets('empty: icon, title and guidance', (tester) async {
    stubList(snapshotOfNotifs([], since: 's'));

    await open(tester);

    expect(find.text('No notifications yet'), findsOneWidget);
    expect(find.textContaining('New followers'), findsOneWidget);
  });

  testWidgets('data: rows, collapsed likes, unread semantics', (tester) async {
    final seen = kNotifBase.subtract(const Duration(minutes: 30));
    stubList(
      snapshotOfNotifs([
        notif('a', minutesAgo: 5),
        notif(
          'b',
          minutesAgo: 60,
          type: NotificationType.NOTIFICATION_TYPE_LIKE,
          actorCount: 3,
          postId: '9',
          displayName: 'Bob',
          actorId: 'u3',
        ),
      ], seenAt: seen),
    );

    await open(tester);

    expect(find.text('Alice followed you'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('Alice followed you, .* ago, unread')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(RegExp('Bob and 2 others liked your post, .* ago')),
      findsOneWidget,
    );
    // The older row is not read as unread.
    expect(
      find.bySemanticsLabel(RegExp('Bob and 2 others liked your post.*unread')),
      findsNothing,
    );
  });

  group('responsive matrix (W1-9)', () {
    for (final entry in {
      'dark': appDarkTheme,
      'light': appLightTheme,
    }.entries) {
      for (final width in const [360.0, 600.0, 1200.0]) {
        for (final scale in const [1.0, 1.3, 2.0]) {
          testWidgets(
            '${entry.key} ${width.toInt()}dp x$scale: tabs and rows do not '
            'overflow; both tabs render',
            (tester) async {
              stubList(
                snapshotOfNotifs([
                  notif('a', minutesAgo: 1),
                  notif(
                    'b',
                    minutesAgo: 5,
                    type: NotificationType.NOTIFICATION_TYPE_MENTION,
                    postId: '7',
                    displayName: 'A rather long display name for a mention',
                    actorId: 'u5',
                  ),
                ], seenAt: kNotifBase),
              );
              await open(
                tester,
                theme: entry.value,
                size: Size(width, 1200),
                textScale: scale,
              );
              expect(tester.takeException(), isNull);

              await tester.tap(find.text('Mentions'));
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
              expect(find.textContaining('mentioned you'), findsOneWidget);
            },
          );
        }
      }
    }
  });

  group('All / Mentions tabs (W1-6)', () {
    List<pb.Notification> mixed() => [
      notif('f', minutesAgo: 1),
      notif(
        'm',
        minutesAgo: 2,
        type: NotificationType.NOTIFICATION_TYPE_MENTION,
        postId: '7',
        displayName: 'Mia',
        actorId: 'u5',
      ),
      notif(
        'r',
        minutesAgo: 3,
        type: NotificationType.NOTIFICATION_TYPE_REPLY,
        postId: '8',
        displayName: 'Rae',
        actorId: 'u6',
      ),
      notif(
        'l',
        minutesAgo: 4,
        type: NotificationType.NOTIFICATION_TYPE_LIKE,
        postId: '9',
        displayName: 'Lou',
        actorId: 'u7',
      ),
    ];

    testWidgets('All shows everything; Mentions filters the loaded rows with '
        'no extra RPC', (tester) async {
      stubList(snapshotOfNotifs(mixed(), seenAt: kNotifBase));
      await open(tester);

      expect(find.text('All'), findsOneWidget);
      expect(find.text('Mentions'), findsOneWidget);
      expect(find.text('Alice followed you'), findsOneWidget);
      clearInteractions(repo);

      await tester.tap(find.text('Mentions'));
      await tester.pumpAndSettle();

      expect(find.text('Mia mentioned you'), findsOneWidget);
      expect(find.text('Rae replied to your post'), findsOneWidget);
      expect(find.text('Alice followed you'), findsNothing);
      expect(find.text('Lou liked your post'), findsNothing);
      verifyNoMoreInteractions(repo);

      await tester.tap(find.text('All'));
      await tester.pumpAndSettle();
      expect(find.text('Lou liked your post'), findsOneWidget);
    });

    testWidgets('Mentions with none loaded: empty state, and a way to look '
        'further back when older pages exist', (tester) async {
      stubList(snapshotOfNotifs([notif('f')], older: 'p1', seenAt: kNotifBase));
      await open(tester);

      await tester.tap(find.text('Mentions'));
      await tester.pumpAndSettle();

      expect(find.text('No mentions yet'), findsOneWidget);
      expect(find.text('Look through older notifications'), findsOneWidget);
    });

    testWidgets('the tabs are equal-width and announced as a group', (
      tester,
    ) async {
      stubList(snapshotOfNotifs(mixed(), seenAt: kNotifBase));
      final handle = tester.ensureSemantics();
      await open(tester);

      final bar = tester.getRect(find.byType(AppTabBar));
      expect(
        tester.getCenter(find.text('All')).dx,
        closeTo(bar.left + bar.width / 4, 1),
      );
      expect(
        tester.getCenter(find.text('Mentions')).dx,
        closeTo(bar.left + bar.width * 3 / 4, 1),
      );
      expect(find.bySemanticsLabel('Notifications timelines'), findsOneWidget);
      handle.dispose();
    });
  });

  testWidgets('opening marks seen and clears the badge', (tester) async {
    badge.seed(4);
    stubList(snapshotOfNotifs([notif('a', minutesAgo: 1)]));

    await open(tester);

    verify(() => repo.markSeen(any())).called(1);
    expect(badge.state, 0);
  });

  testWidgets('a follow opens the actor profile, others open the post', (
    tester,
  ) async {
    stubList(
      snapshotOfNotifs([
        notif('f', minutesAgo: 1, actorId: 'u2'),
        notif(
          'r',
          minutesAgo: 2,
          type: NotificationType.NOTIFICATION_TYPE_REPLY,
          postId: '55',
        ),
      ], seenAt: kNotifBase),
    );
    await open(tester);

    await tester.tap(find.textContaining('Alice').first);
    await tester.pumpAndSettle();
    expect(visited, ['/u/u2']);

    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('replied').first);
    await tester.pumpAndSettle();
    expect(visited, ['/u/u2', '/post/55']);
  });

  testWidgets('follow_request opens the requests screen, follow_accepted the '
      'actor profile (W3-34)', (tester) async {
    stubList(
      snapshotOfNotifs([
        notif(
          'q',
          minutesAgo: 1,
          type: NotificationType.NOTIFICATION_TYPE_FOLLOW_REQUEST,
          actorId: 'u3',
          handle: 'bob',
          displayName: 'Bob',
        ),
        notif(
          'a',
          minutesAgo: 2,
          type: NotificationType.NOTIFICATION_TYPE_FOLLOW_ACCEPTED,
          actorId: 'u4',
          handle: 'cy',
          displayName: 'Cy',
        ),
      ], seenAt: kNotifBase),
    );
    final semantics = tester.ensureSemantics();
    await open(tester);

    expect(find.text('Bob requested to follow you'), findsOneWidget);
    expect(find.text('Cy accepted your follow request'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('Bob requested to follow you, .* ago')),
      findsOneWidget,
    );

    await tester.tap(find.textContaining('requested to follow'));
    await tester.pumpAndSettle();
    expect(visited, ['/follow-requests']);

    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('accepted your'));
    await tester.pumpAndSettle();
    expect(visited, ['/follow-requests', '/u/u4']);
    semantics.dispose();
  });

  testWidgets('error with nothing cached shows a friendly retry', (
    tester,
  ) async {
    when(() => repo.cached()).thenAnswer((_) async => snapshotOfNotifs([]));
    when(() => repo.refresh()).thenThrow(const NetworkException('offline'));

    await open(tester);

    expect(find.textContaining('No connection'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('refresh failure over cached rows keeps them under a notice', (
    tester,
  ) async {
    when(() => repo.cached()).thenAnswer(
      (_) async => snapshotOfNotifs([notif('a')], seenAt: kNotifBase),
    );
    when(() => repo.refresh())
        .thenThrow(const RateLimitedException('x', limitName: 'search_daily'));

    await open(tester);

    expect(find.textContaining('Alice'), findsOneWidget);
    expect(find.textContaining("today's refresh limit"), findsOneWidget);
  });

  testWidgets('pagination footer: inline retry after a failed page', (
    tester,
  ) async {
    // Enough rows that the list scrolls and the prefetch fires.
    final rows = [for (var i = 0; i < 20; i++) notif('n$i', minutesAgo: i + 1)];
    stubList(snapshotOfNotifs(rows, older: 'p1', seenAt: kNotifBase));
    when(() => repo.loadOlder()).thenThrow(const NetworkException('offline'));
    await open(tester);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -3000));
    await tester.pumpAndSettle();

    expect(find.text("Couldn't load more. Retry"), findsOneWidget);
  });

  testWidgets('push prompt only where supported and not yet asked', (
    tester,
  ) async {
    messaging.supported = false;
    stubList(snapshotOfNotifs([], since: 's'));
    await open(tester);
    expect(find.text('Turn on'), findsNothing);
  });

  testWidgets('opt-in card asks the OS only on the tap', (tester) async {
    final supported = FakePushMessaging();
    final p = PushCubit(messaging: supported, repository: repo);
    addTearDown(p.close);
    push = p;
    when(() => repo.deviceId(any())).thenAnswer((_) async => 'd');
    when(
      () => repo.registerDevice(
        idempotencyKey: any(named: 'idempotencyKey'),
        deviceId: any(named: 'deviceId'),
        fcmToken: any(named: 'fcmToken'),
        platform: any(named: 'platform'),
      ),
    ).thenAnswer((_) async {});
    stubList(snapshotOfNotifs([], since: 's'));
    await p.start();

    await open(tester);

    expect(find.text('Turn on notifications'), findsOneWidget);
    expect(find.text('Turn on'), findsOneWidget);
    expect(supported.permissionRequests, 0);

    await tester.tap(find.text('Turn on'));
    await tester.pumpAndSettle();

    expect(supported.permissionRequests, 1);
    expect(find.text('Turn on'), findsNothing);
    expect(find.text('Turn on notifications'), findsNothing);
  });

  group('push opt-in card (W2-12)', () {
    setUp(() async {
      when(() => repo.deviceId(any())).thenAnswer((_) async => 'd');
      when(
        () => repo.registerDevice(
          idempotencyKey: any(named: 'idempotencyKey'),
          deviceId: any(named: 'deviceId'),
          fcmToken: any(named: 'fcmToken'),
          platform: any(named: 'platform'),
        ),
      ).thenAnswer((_) async {});
      stubList(snapshotOfNotifs([notif('a', minutesAgo: 1)], since: 's'));
      await push.close();
      messaging = FakePushMessaging();
      push = PushCubit(messaging: messaging, repository: repo);
      await push.start();
    });

    testWidgets('sits at the top, above the rows, below the tabs', (
      tester,
    ) async {
      await open(tester);

      final card = tester.getTopLeft(find.text('Turn on notifications')).dy;
      expect(card, greaterThan(tester.getBottomLeft(find.text('Mentions')).dy));
      expect(
        card,
        lessThan(tester.getTopLeft(find.byType(NotificationRow).first).dy),
      );
    });

    testWidgets('Not now removes it and stays removed for 30 days', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();

      expect(find.text('Turn on notifications'), findsNothing);
      expect(optInStore.records.keys, ['uid-a']);

      await open(tester);
      expect(find.text('Turn on notifications'), findsNothing);
    });

    testWidgets('a denial leaves the one-line settings hint', (tester) async {
      messaging.nextPermissionAnswer = PushPermission.denied;
      await open(tester);
      await tester.tap(find.text('Turn on'));
      await tester.pumpAndSettle();

      expect(find.text('Turn on notifications'), findsNothing);
      expect(
        find.text('Notifications are off in your device settings'),
        findsOneWidget,
      );
    });

    testWidgets('the notifications flag off: not even the screen builds it', (
      tester,
    ) async {
      await open(tester, features: const {});

      expect(find.text('Turn on notifications'), findsNothing);
    });

    for (final entry in {
      'dark': appDarkTheme,
      'light': appLightTheme,
    }.entries) {
      for (final width in const [360.0, 600.0, 1200.0]) {
        for (final scale in const [1.0, 1.3, 2.0]) {
          testWidgets(
            'responsive ${entry.key} ${width.toInt()}dp x$scale: one card '
            'above the rows, no overflow, inside the column',
            (tester) async {
              await open(
                tester,
                theme: entry.value,
                size: Size(width, 1200),
                textScale: scale,
              );

              expect(tester.takeException(), isNull);
              expect(find.text('Turn on notifications'), findsOneWidget);
              expect(
                tester.getSize(find.byType(AppSurface).first).width,
                lessThanOrEqualTo(AppBreakpoints.mobile),
              );
            },
          );
        }
      }
    }

    for (final dark in [false, true]) {
      testWidgets(
        '320dp, 2.0 text, ${dark ? 'dark' : 'light'}: card and rows without overflow',
        (tester) async {
          await open(
            tester,
            theme: dark ? appDarkTheme : appLightTheme,
            size: const Size(320, 640),
            textScale: 2,
          );

          expect(tester.takeException(), isNull);
          expect(find.text('Turn on notifications'), findsOneWidget);
        },
      );
    }
  });

  testWidgets('narrow width, 2x text and dark theme: no overflow', (
    tester,
  ) async {
    stubList(
      snapshotOfNotifs([
        notif(
          'a',
          minutesAgo: 1,
          displayName: 'A very long display name that must wrap or ellipsize',
          type: NotificationType.NOTIFICATION_TYPE_LIKE,
          actorCount: 12,
          postId: '1',
        ),
      ], seenAt: kNotifBase.subtract(const Duration(hours: 1))),
    );

    await open(
      tester,
      size: const Size(320, 640),
      textScale: 2,
      theme: appDarkTheme,
    );

    expect(tester.takeException(), isNull);
    expect(find.textContaining('and 11 others'), findsOneWidget);
  });

  testWidgets('rows have 48dp+ tap targets', (tester) async {
    stubList(snapshotOfNotifs([notif('a')], seenAt: kNotifBase));
    await open(tester);

    final size = tester.getSize(find.byType(InkWell).first);
    expect(size.height, greaterThanOrEqualTo(AppSpacing.minTapTarget));
  });

  testWidgets('beacon rows read their verbs and open the plan', (tester) async {
    const id = '1234567890123456789';
    stubList(
      snapshotOfNotifs([
        notif(
          'r',
          minutesAgo: 1,
          type: NotificationType.NOTIFICATION_TYPE_BEACON_REQUEST,
          beaconId: id,
        ),
        notif(
          'a',
          minutesAgo: 2,
          type: NotificationType.NOTIFICATION_TYPE_BEACON_ACCEPTED,
          actorId: 'u4',
          handle: 'cy',
          displayName: 'Cy',
          beaconId: id,
        ),
        notif(
          'c',
          minutesAgo: 3,
          type: NotificationType.NOTIFICATION_TYPE_BEACON_CANCELLED,
          actorId: 'u5',
          handle: 'di',
          displayName: 'Di',
          beaconId: id,
        ),
      ], seenAt: kNotifBase),
    );
    await open(tester);

    expect(find.text('Alice asked to join your plan'), findsOneWidget);
    expect(find.text('Cy accepted you into their plan'), findsOneWidget);
    expect(find.text('Di cancelled a plan you joined'), findsOneWidget);

    await tester.tap(find.textContaining('asked to join'));
    await tester.pumpAndSettle();
    expect(visited, ['/plans/$id']);
  });

  group('Plans tab (F15)', () {
    List<pb.Notification> mixed() => [
      notif('f', minutesAgo: 1),
      notif(
        'm',
        minutesAgo: 2,
        type: NotificationType.NOTIFICATION_TYPE_MENTION,
        postId: '7',
        displayName: 'Mia',
        actorId: 'u5',
      ),
      for (final (i, type) in [
        NotificationType.NOTIFICATION_TYPE_BEACON_REQUEST,
        NotificationType.NOTIFICATION_TYPE_BEACON_ACCEPTED,
        NotificationType.NOTIFICATION_TYPE_BEACON_CANCELLED,
        NotificationType.NOTIFICATION_TYPE_BEACON_UPDATED,
      ].indexed)
        notif(
          'b$i',
          minutesAgo: 3 + i,
          type: type,
          displayName: 'Plan$i',
          actorId: 'p$i',
          beaconId: '123456789012345678$i',
        ),
    ];

    testWidgets('beacons on: All, Plans, Mentions in the design order, equal '
        'width; Plans filters the loaded rows with no extra RPC', (
      tester,
    ) async {
      stubList(snapshotOfNotifs(mixed(), seenAt: kNotifBase));
      await open(tester, features: const {'notifications', 'beacons'});

      final bar = tester.getRect(find.byType(AppTabBar));
      for (final (i, label) in ['All', 'Plans', 'Mentions'].indexed) {
        expect(
          tester.getCenter(find.text(label)).dx,
          closeTo(bar.left + bar.width * (2 * i + 1) / 6, 1),
          reason: label,
        );
      }
      clearInteractions(repo);

      await tester.tap(find.text('Plans'));
      await tester.pumpAndSettle();
      expect(find.text('Plan0 asked to join your plan'), findsOneWidget);
      expect(find.text('Plan1 accepted you into their plan'), findsOneWidget);
      expect(find.text('Plan2 cancelled a plan you joined'), findsOneWidget);
      expect(find.text('Plan3 changed a plan you joined'), findsOneWidget);
      expect(find.text('Alice followed you'), findsNothing);
      expect(find.text('Mia mentioned you'), findsNothing);
      verifyNoMoreInteractions(repo);

      // A plan update opens the plan, as the other plan types do.
      await tester.tap(find.text('Plan3 changed a plan you joined'));
      await tester.pumpAndSettle();
      expect(visited, ['/plans/1234567890123456783']);
    });

    testWidgets('beacons off: no Plans tab (All, Mentions only)', (
      tester,
    ) async {
      stubList(snapshotOfNotifs(mixed(), seenAt: kNotifBase));
      await open(tester);

      expect(find.text('Plans'), findsNothing);
      expect(find.text('All'), findsOneWidget);
      expect(find.text('Mentions'), findsOneWidget);
    });

    testWidgets('Plans with none loaded: its own empty state, and a way to '
        'look further back', (tester) async {
      stubList(snapshotOfNotifs([notif('f')], older: 'p1', seenAt: kNotifBase));
      await open(tester, features: const {'notifications', 'beacons'});

      await tester.tap(find.text('Plans'));
      await tester.pumpAndSettle();

      expect(find.text('No plan updates yet'), findsOneWidget);
      expect(find.text('Look through older notifications'), findsOneWidget);
      expect(find.text('No mentions yet'), findsNothing);
    });

    for (final width in const [320.0, 360.0, 599.0]) {
      testWidgets('${width.toInt()}dp x2.0: three tabs, no overflow', (
        tester,
      ) async {
        stubList(snapshotOfNotifs(mixed(), seenAt: kNotifBase));
        await open(
          tester,
          features: const {'notifications', 'beacons'},
          size: Size(width, 900),
          textScale: 2,
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Plans'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.textContaining('asked to join'), findsOneWidget);
      });
    }
  });

  group('Follow back (F14)', () {
    const features = {'notifications', 'graph'};

    graph.Relationship rel(String id, graph.FollowState state) =>
        graph.Relationship(userId: id, followState: state);

    List<pb.Notification> page() => [
      notif('f1', minutesAgo: 1, actorId: 'u2'),
      notif(
        'f2',
        minutesAgo: 2,
        actorId: 'u3',
        handle: 'bob',
        displayName: 'Bob',
      ),
      // Collapsed: no single account to follow back.
      notif(
        'f3',
        minutesAgo: 3,
        actorId: 'u4',
        handle: 'cy',
        displayName: 'Cy',
        actorCount: 3,
      ),
      notif(
        'l',
        minutesAgo: 4,
        type: NotificationType.NOTIFICATION_TYPE_LIKE,
        postId: '9',
        actorId: 'u5',
        displayName: 'Lou',
      ),
    ];

    void stubRelationships({Map<String, graph.FollowState> states = const {}}) {
      when(() => graphRepo.relationshipsFor(any())).thenAnswer((call) async {
        final ids = call.positionalArguments.first as List<String>;
        return {
          for (final id in ids)
            id: rel(id, states[id] ?? graph.FollowState.FOLLOW_STATE_NONE),
        };
      });
    }

    testWidgets('one batched GetRelationships for the page; Follow back on '
        'single-actor follow rows only', (tester) async {
      stubRelationships(
        states: {'u3': graph.FollowState.FOLLOW_STATE_FOLLOWING},
      );
      stubList(snapshotOfNotifs(page(), seenAt: kNotifBase));
      final semantics = tester.ensureSemantics();
      await open(tester, features: features);

      expect(verify(() => graphRepo.relationshipsFor(captureAny())).captured, [
        ['u2', 'u3'],
      ]);
      // Alice: Follow back; Bob (already followed): Following; Cy (collapsed)
      // and Lou (a like): nothing.
      expect(find.text('Follow back'), findsOneWidget);
      expect(find.text('Following'), findsOneWidget);
      expect(find.byType(FollowButton), findsNWidgets(2));
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('notification-f3')),
          matching: find.byType(FollowButton),
        ),
        findsNothing,
      );
      // Its own node, not swallowed by the row's sentence.
      expect(find.bySemanticsLabel('Follow back'), findsWidgets);
      semantics.dispose();
    });

    testWidgets('graph off: no control and no GetRelationships', (
      tester,
    ) async {
      stubRelationships();
      stubList(snapshotOfNotifs(page(), seenAt: kNotifBase));
      await open(tester);

      expect(find.byType(FollowButton), findsNothing);
      verifyNever(() => graphRepo.relationshipsFor(any()));
    });

    testWidgets('an older page costs one more call, for its new actors only', (
      tester,
    ) async {
      stubRelationships();
      final rows = [
        for (var i = 0; i < 20; i++)
          notif('n$i', minutesAgo: i + 1, actorId: 'a${i % 2}'),
      ];
      stubList(snapshotOfNotifs(rows, older: 'p1', seenAt: kNotifBase));
      when(() => repo.loadOlder()).thenAnswer(
        (_) async => snapshotOfNotifs([
          ...rows,
          notif('o1', minutesAgo: 60, actorId: 'a0'),
          notif('o2', minutesAgo: 61, actorId: 'z9'),
        ], seenAt: kNotifBase),
      );
      await open(tester, features: features);
      expect(verify(() => graphRepo.relationshipsFor(captureAny())).captured, [
        ['a0', 'a1'],
      ]);

      await tester.drag(find.byType(CustomScrollView), const Offset(0, -6000));
      await tester.pumpAndSettle();

      verify(() => repo.loadOlder()).called(1);
      expect(verify(() => graphRepo.relationshipsFor(captureAny())).captured, [
        ['z9'],
      ]);
    });

    testWidgets('Follow back updates the row optimistically to Following', (
      tester,
    ) async {
      stubRelationships();
      final answer = Completer<graph.Relationship>();
      when(
        () => graphRepo.follow(
          userId: any(named: 'userId'),
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenAnswer((_) => answer.future);
      stubList(
        snapshotOfNotifs([notif('f1', actorId: 'u2')], seenAt: kNotifBase),
      );
      await open(tester, features: features);

      await tester.tap(find.text('Follow back'));
      await tester.pump();
      verify(
        () => graphRepo.follow(
          userId: 'u2',
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).called(1);
      // Optimistic: no longer offered while the call is out.
      expect(find.text('Follow back'), findsNothing);
      answer.complete(rel('u2', graph.FollowState.FOLLOW_STATE_FOLLOWING));
      await tester.pumpAndSettle();
      expect(find.text('Following'), findsOneWidget);
      // Never a second GetRelationships for the row.
      verify(() => graphRepo.relationshipsFor(any())).called(1);
    });

    testWidgets('a refused follow rolls back with a message', (tester) async {
      stubRelationships();
      when(
        () => graphRepo.follow(
          userId: any(named: 'userId'),
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenThrow(const NetworkException('offline'));
      stubList(
        snapshotOfNotifs([notif('f1', actorId: 'u2')], seenAt: kNotifBase),
      );
      await open(tester, features: features);

      await tester.tap(find.text('Follow back'));
      await tester.pumpAndSettle();
      expect(find.text('Follow back'), findsOneWidget);
      expect(find.byType(SnackBar), findsOneWidget);
    });

    testWidgets('a failed GetRelationships draws no control and no banner', (
      tester,
    ) async {
      when(() => graphRepo.relationshipsFor(any()))
          .thenThrow(const NetworkException('offline'));
      stubList(snapshotOfNotifs(page(), seenAt: kNotifBase));
      await open(tester, features: features);

      expect(find.byType(FollowButton), findsNothing);
      expect(find.byKey(const ValueKey('follow-back-pending')), findsNothing);
      expect(find.byType(AppNoticeBanner), findsNothing);
      expect(find.text('Alice followed you'), findsOneWidget);
    });

    testWidgets('while the answer is out the row keeps the 48 dp line', (
      tester,
    ) async {
      final answer = Completer<Map<String, graph.Relationship>>();
      when(() => graphRepo.relationshipsFor(any()))
          .thenAnswer((_) => answer.future);
      stubList(
        snapshotOfNotifs([notif('f1', actorId: 'u2')], seenAt: kNotifBase),
      );
      await open(tester, features: features);

      final pending = find.byKey(const ValueKey('follow-back-pending'));
      expect(pending, findsOneWidget);
      expect(tester.getSize(pending).height, AppSpacing.minTapTarget);
      final row = find.byKey(const ValueKey('notification-f1'));
      final rowHeight = tester.getSize(row).height;

      answer.complete({'u2': rel('u2', graph.FollowState.FOLLOW_STATE_NONE)});
      await tester.pumpAndSettle();
      expect(find.text('Follow back'), findsOneWidget);
      expect(tester.getSize(row).height, rowHeight);
    });

    testWidgets('a blocked actor is not offered a follow', (tester) async {
      when(() => graphRepo.relationshipsFor(any())).thenAnswer(
        (_) async => {'u2': graph.Relationship(userId: 'u2', blocking: true)},
      );
      stubList(
        snapshotOfNotifs([notif('f1', actorId: 'u2')], seenAt: kNotifBase),
      );
      await open(tester, features: features);

      expect(find.byType(FollowButton), findsNothing);
      expect(find.text('Unblock'), findsNothing);
    });

    for (final (width, dir) in [
      (320.0, TextDirection.ltr),
      (360.0, TextDirection.ltr),
      (360.0, TextDirection.rtl),
      (600.0, TextDirection.ltr),
      (1200.0, TextDirection.rtl),
    ]) {
      testWidgets('${width.toInt()}dp x2.0 ${dir.name}: Follow back fits, '
          '48 dp, never ellipsized', (tester) async {
        stubRelationships();
        stubList(
          snapshotOfNotifs([
            notif(
              'f1',
              actorId: 'u2',
              displayName: 'A rather long display name that wraps',
            ),
          ], seenAt: kNotifBase),
        );
        await open(
          tester,
          features: features,
          size: Size(width, 1000),
          textScale: 2,
          textDirection: dir,
        );

        expect(tester.takeException(), isNull);
        final button = find.byType(FollowButton);
        expect(button, findsOneWidget);
        expect(
          tester.getSize(button).height,
          greaterThanOrEqualTo(AppSpacing.minTapTarget),
        );
        final label = tester.renderObject<RenderParagraph>(
          find.descendant(of: button, matching: find.byType(RichText)),
        );
        expect(label.didExceedMaxLines, isFalse);
        final tile = tester.getRect(
          find.descendant(
            of: find.byKey(const ValueKey('notification-f1')),
            matching: find.byType(AppTileIcon),
          ),
        );
        final rect = tester.getRect(button);
        if (dir == TextDirection.rtl) {
          expect(rect.right, lessThanOrEqualTo(tile.left));
        } else {
          expect(rect.left, greaterThanOrEqualTo(tile.right));
        }
      });
    }
  });
}
