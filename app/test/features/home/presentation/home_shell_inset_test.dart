import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/app_bottom_bar.dart';
import 'package:dzeroth/core/widgets/responsive_scaffold.dart';
import 'package:dzeroth/features/home/presentation/home_screen.dart';
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
import 'package:dzeroth/features/timeline/presentation/widgets/feed_post_row.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/notifications/v1/notifications.pbenum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/fake_push_messaging.dart';
import '../../../support/fake_push_opt_in_store.dart';
import '../../../support/timeline_fixtures.dart';

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockNotificationsRepository extends Mock
    implements NotificationsRepository {}

const _destinations = [
  AppNavDestination(
    icon: Icons.home_outlined,
    selectedIcon: Icons.home,
    label: 'Home',
  ),
  AppNavDestination(
    icon: Icons.notifications_none,
    selectedIcon: Icons.notifications,
    label: 'Notifications',
  ),
];

/// The Home feed (`TimelineFeedView`, the scroll view Home, lists,
/// communities, search and the profile tabs share) under the shell's phone
/// chrome: with `ui_shell` on, the end of a short feed must clear the
/// floating bar without the bar having to hide; with it off, the docked bar
/// is unchanged.
void main() {
  const feed = FeedKey.home();
  late MockTimelineRepository timeline;
  late MockPostsRepository posts;
  late _MockOnboardingBloc onboarding;
  late PendingPostsCubit pending;
  late PushCubit push;
  late PushOptInCubit optIn;
  // Taps the bar took.
  final barTaps = <int>[];

  setUpAll(() {
    registerFallbackValue(DevicePlatform.DEVICE_PLATFORM_ANDROID);
  });

  setUp(() {
    barTaps.clear();
    timeline = MockTimelineRepository();
    posts = MockPostsRepository();
    onboarding = _MockOnboardingBloc();
    pending = PendingPostsCubit();
    final notifications = _MockNotificationsRepository();
    when(() => notifications.enabled).thenReturn(true);
    when(() => notifications.deviceId(any())).thenAnswer((_) async => 'd');
    push = PushCubit(messaging: FakePushMessaging(), repository: notifications);
    optIn = PushOptInCubit(store: FakePushOptInStore(), push: push);
    when(() => timeline.sinceRefresh(feed)).thenReturn(null);
    when(() => timeline.sinceRefreshAttempt(feed)).thenReturn(null);
    when(() => timeline.rateLimitedFor()).thenReturn(null);
    when(() => posts.removedPosts).thenAnswer((_) => const Stream.empty());
    final snapshot = snapshotOf([3, 2, 1]);
    when(() => timeline.cached(feed)).thenAnswer((_) async => snapshot);
    when(() => timeline.refresh(feed)).thenAnswer((_) async => snapshot);
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        enabledFeatures: const {'posts'},
        profile: identity.Profile(userId: 'me', handle: 'me'),
      ),
    );
  });

  tearDown(() async {
    await pending.close();
    await optIn.close();
    await push.close();
  });

  Future<void> open(
    WidgetTester tester, {
    required double height,
    bool floating = true,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(360, height);
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
          child: MaterialApp(
            theme: appLightTheme,
            home: ResponsiveScaffold(
              selectedIndex: 0,
              onDestinationSelected: barTaps.add,
              destinations: _destinations,
              floatingBar: floating,
              body: const HomeScreen(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder lastRow() => find.byType(FeedPostRow).last;

  /// Jumps the feed to its end: not a user scroll, so the bar stays up.
  Future<void> jumpToEnd(WidgetTester tester) async {
    final position = tester
        .state<ScrollableState>(
          find.ancestor(of: lastRow(), matching: find.byType(Scrollable)).first,
        )
        .position;
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
  }

  /// The height at which the last of the three rows sits 40 dp above the
  /// bottom edge: inside the 90 dp of the floating bar, on a feed whose
  /// content alone fits the screen.
  Future<double> shortHeight(WidgetTester tester) async {
    await open(tester, height: 2000);
    return (tester.getRect(lastRow()).bottom + 40).roundToDouble();
  }

  testWidgets('ui_shell on: the last row of a short feed ends above the '
      'pill, and a tap on it is not swallowed by the bar', (tester) async {
    final height = await shortHeight(tester);
    await open(tester, height: height);
    await jumpToEnd(tester);

    final opacity = tester.widget<AnimatedOpacity>(
      find.ancestor(
        of: find.byType(AppBottomBar),
        matching: find.byType(AnimatedOpacity),
      ),
    );
    expect(opacity.opacity, 1);
    final pill = tester.getRect(
      find.descendant(
        of: find.byType(AppFloatingBottomBar),
        matching: find.byType(Material),
      ),
    );
    expect(pill.top, height - 90);
    final row = tester.getRect(lastRow());
    expect(row.bottom, lessThanOrEqualTo(pill.top));
    // A tap at the foot of the row hits the row, not the bar.
    final hits = tester.hitTestOnBinding(Offset(row.center.dx, row.bottom - 4));
    final bar = tester.renderObject(find.byType(AppFloatingBottomBar));
    final rowBox = tester.renderObject(lastRow());
    expect(hits.path.any((entry) => entry.target == bar), isFalse);
    expect(hits.path.any((entry) => entry.target == rowBox), isTrue);
    expect(barTaps, isEmpty);
  });

  testWidgets('ui_shell off: the docked bar; the feed ends at its top', (
    tester,
  ) async {
    final height = await shortHeight(tester);
    await open(tester, height: height, floating: false);
    await jumpToEnd(tester);

    expect(find.byType(AppFloatingBottomBar), findsNothing);
    final barTop = tester.getRect(find.byType(AppBottomBar)).top;
    expect(barTop, height - 56);
    expect(tester.getRect(lastRow()).bottom, lessThanOrEqualTo(barTop));
  });
}
