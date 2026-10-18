import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/notifications/data/notifications_repository.dart';
import 'package:dzeroth/features/notifications/data/notifications_store.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/push_cubit.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/unread_badge_cubit.dart';
import 'package:dzeroth/features/notifications/presentation/notifications_screen.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/notifications/v1/notifications.pbenum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/fake_push_messaging.dart';
import '../../../support/notifications_fixtures.dart';

class MockNotificationsRepository extends Mock
    implements NotificationsRepository {}

class MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

void main() {
  late MockNotificationsRepository repo;
  late MockOnboardingBloc onboarding;
  late UnreadBadgeCubit badge;
  late FakePushMessaging messaging;
  late PushCubit push;
  late List<String> visited;

  setUpAll(() {
    registerFallbackValue(DevicePlatform.DEVICE_PLATFORM_ANDROID);
  });

  setUp(() {
    repo = MockNotificationsRepository();
    onboarding = MockOnboardingBloc();
    badge = UnreadBadgeCubit();
    messaging = FakePushMessaging(supported: false);
    push = PushCubit(messaging: messaging, repository: repo);
    visited = [];
    when(() => repo.enabled).thenReturn(true);
    when(() => repo.sinceRefresh).thenReturn(null);
    when(() => repo.sinceRefreshAttempt).thenReturn(null);
    when(() => repo.rateLimitedFor()).thenReturn(null);
    when(() => repo.markSeen(any())).thenAnswer((_) async => kNotifBase);
  });

  tearDown(() async {
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
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(enabledFeatures: features),
    );
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
          path: '/u/:userId',
          builder: (context, state) {
            visited.add('/u/${state.pathParameters['userId']}');
            return const Scaffold(body: Text('profile page'));
          },
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<NotificationsRepository>.value(value: repo),
          RepositoryProvider<UnexpectedErrorReporter>.value(value: (_, _) {}),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<OnboardingBloc>.value(value: onboarding),
            BlocProvider<UnreadBadgeCubit>.value(value: badge),
            BlocProvider<PushCubit>.value(value: push),
          ],
          child: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(textScale),
            ),
            child: MaterialApp.router(
              theme: theme ?? appLightTheme,
              routerConfig: router,
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
    when(() => repo.refresh()).thenThrow(
      const RateLimitedException('x', limitName: 'read_budget_daily'),
    );

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

  testWidgets('push prompt asks the OS only on the tap', (tester) async {
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

    expect(find.text('Turn on'), findsOneWidget);
    expect(supported.permissionRequests, 0);

    await tester.tap(find.text('Turn on'));
    await tester.pumpAndSettle();

    expect(supported.permissionRequests, 1);
    expect(find.text('Turn on'), findsNothing);
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
}
