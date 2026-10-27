import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'package:dzeroth/features/profile/presentation/profile_screen.dart';
import 'package:dzeroth/features/profile/presentation/widgets/profile_header.dart';
import 'package:dzeroth/features/timeline/data/timeline_repository.dart';
import 'package:dzeroth/features/timeline/domain/feed_key.dart';
import 'package:dzeroth/features/timeline/data/timeline_store.dart';
import 'package:dzeroth/features/timeline/presentation/timeline_feed_view.dart';
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/shared/widgets/app_tab_bar.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart'
    as pb;

import '../../../support/timeline_fixtures.dart';

class _MockIdentityRepository extends Mock implements IdentityRepository {}

class _MockGraphRepository extends Mock implements GraphRepository {}

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

/// W3-13: the profile's pinned tab bar, per-tab scroll, app-bar name fade and
/// "Joined" row. Every date here is only formatted, never compared with the
/// real clock.
void main() {
  late _MockIdentityRepository identityRepository;
  late _MockGraphRepository graphRepository;
  late MockTimelineRepository timeline;
  late MockPostsRepository posts;
  late _MockOnboardingBloc onboardingBloc;
  late PendingPostsCubit pending;

  final ownFeed = FeedKey.user('viewer-uid');
  final ownReplies = FeedKey.user('viewer-uid', includeReplies: true);
  final targetFeed = FeedKey.user('target-uid');
  final targetReplies = FeedKey.user('target-uid', includeReplies: true);
  final nameKey = find.byKey(const ValueKey('profile-appbar-name'));

  // Mid-month noon UTC: the same month in every zone CI can run in.
  final created = pb.Timestamp.fromDateTime(DateTime.utc(2026, 3, 15, 12));

  setUpAll(() => registerFallbackValue(const FeedKey.home()));

  setUp(() {
    identityRepository = _MockIdentityRepository();
    graphRepository = _MockGraphRepository();
    timeline = MockTimelineRepository();
    posts = MockPostsRepository();
    onboardingBloc = _MockOnboardingBloc();
    pending = PendingPostsCubit();
    when(() => graphRepository.cached(any())).thenReturn(null);
    when(() => timeline.rateLimitedFor()).thenReturn(null);
    when(() => timeline.sinceRefresh(any())).thenReturn(null);
    when(() => timeline.sinceRefreshAttempt(any())).thenReturn(null);
    when(() => posts.removedPosts).thenAnswer((_) => const Stream.empty());
  });

  tearDown(() => pending.close());

  /// [own] = the viewer's profile (`viewer-uid`), else `target-uid`. Both
  /// tabs get 30 rows so each can scroll.
  void arrange({bool own = true, bool withCreated = true}) {
    final uid = own ? 'viewer-uid' : 'target-uid';
    whenListen(
      onboardingBloc,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        enabledFeatures: const {'posts', 'replies', 'graph'},
        profile: identity.Profile(userId: 'viewer-uid', handle: 'viewer'),
      ),
    );
    when(() => identityRepository.getProfile(handle: 'kaif')).thenAnswer(
      (_) async => identity.Profile(
        userId: uid,
        handle: 'kaif',
        displayName: 'Kaif',
        bio: 'Builds things.',
        postsCount: Int64(30),
        createdAt: withCreated ? created : null,
      ),
    );
    when(() => graphRepository.profileRelationshipFor(uid)).thenAnswer(
      (_) async =>
          ProfileRelationship(relationship: graph.Relationship(userId: uid)),
    );
    final postsList = [for (var i = 30; i >= 1; i--) i];
    final repliesList = [for (var i = 130; i >= 101; i--) i];
    for (final entry in {
      own ? ownFeed : targetFeed: postsList,
      own ? ownReplies : targetReplies: repliesList,
    }.entries) {
      final snapshot = snapshotOf(entry.value, authorId: uid);
      when(() => timeline.cached(entry.key)).thenAnswer((_) async => snapshot);
      when(() => timeline.refresh(entry.key)).thenAnswer((_) async => snapshot);
    }
  }

  Future<void> open(
    WidgetTester tester, {
    Size size = const Size(400, 800),
    ThemeData? theme,
    double textScale = 1,
    bool disableAnimations = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<IdentityRepository>.value(
            value: identityRepository,
          ),
          RepositoryProvider<GraphRepository>.value(value: graphRepository),
          RepositoryProvider<TimelineRepository>.value(value: timeline),
          RepositoryProvider<PostsRepository>.value(value: posts),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<OnboardingBloc>.value(value: onboardingBloc),
            BlocProvider<PendingPostsCubit>.value(value: pending),
          ],
          child: MaterialApp(
            theme: theme ?? appLightTheme,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(textScale),
                disableAnimations: disableAnimations,
              ),
              child: child!,
            ),
            home: const ProfileScreen(handle: 'kaif'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  double appBarBottom(WidgetTester tester) =>
      tester.getBottomLeft(find.byType(AppBar)).dy;

  Finder headerName() => find.descendant(
    of: find.byType(ProfileHeader),
    matching: find.text('Kaif'),
  );

  /// The selected tab's list (the inner scroll view of the nested scroll).
  ScrollPosition innerPosition(WidgetTester tester) => tester
      .state<ScrollableState>(
        find
            .descendant(
              of: find.byType(TimelineFeedView),
              matching: find.byType(Scrollable),
            )
            .first,
      )
      .position;

  /// The header's scroll position (the outer view of the nested scroll).
  ScrollPosition outerPosition(WidgetTester tester) =>
      tester.state<ScrollableState>(find.byType(Scrollable).first).position;

  Future<void> jumpOuter(WidgetTester tester, double offset) async {
    outerPosition(tester).jumpTo(offset);
    await tester.pumpAndSettle();
  }

  double fade(WidgetTester tester) => tester.widget<Opacity>(nameKey).opacity;

  /// Drags the page up (the header, then the list, moves) by [dy].
  Future<void> scrollUp(WidgetTester tester, double dy) async {
    await tester.drag(
      find.byType(TimelineFeedView),
      Offset(0, -dy),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
  }

  /// Number of visible semantics nodes whose spoken label contains [label].
  int spoken(WidgetTester tester, String label) {
    var count = 0;
    void visit(SemanticsNode node) {
      if (!node.isInvisible && node.label.contains(label)) count++;
      node.visitChildren((child) {
        visit(child);
        return true;
      });
    }

    visit(
      tester
          .binding
          .renderViews
          .first
          .owner!
          .semanticsOwner!
          .rootSemanticsNode!,
    );
    return count;
  }

  group('pinned tab bar', () {
    testWidgets('the header scrolls away and the tab bar stays at the top', (
      tester,
    ) async {
      arrange();
      await open(tester);

      final bar = tester.getRect(find.byType(AppTabBar));
      expect(bar.top, greaterThan(appBarBottom(tester) + 100));
      expect(
        tester.getRect(find.byType(ProfileHeader, skipOffstage: false)).bottom,
        greaterThan(bar.top - 2),
      );

      await scrollUp(tester, 1500);

      expect(
        tester.getRect(find.byType(ProfileHeader, skipOffstage: false)).bottom,
        lessThanOrEqualTo(appBarBottom(tester) + 0.5),
      );
      final pinned = tester.getRect(find.byType(AppTabBar));
      expect(pinned.top, closeTo(appBarBottom(tester), 0.5));
      expect(find.byType(AppTabBar).hitTestable(), findsOneWidget);
      // The first visible row sits right under the pinned bar, never under it.
      final firstRow = find
          .descendant(
            of: find.byType(TimelineFeedView),
            matching: find.textContaining(RegExp(r'^post \d+$')),
          )
          .evaluate()
          .map((e) => tester.getRect(find.byWidget(e.widget)))
          .where((r) => r.bottom > pinned.bottom)
          .map((r) => r.top)
          .fold<double>(double.infinity, (a, b) => a < b ? a : b);
      expect(firstRow, greaterThanOrEqualTo(pinned.bottom - 0.5));
    });

    testWidgets('each tab keeps its own offset and its rows', (tester) async {
      arrange();
      await open(tester);

      await scrollUp(tester, 1800);
      final postsOffset = innerPosition(tester).pixels;
      expect(postsOffset, greaterThan(100));
      final outerCollapsed = appBarBottom(tester);

      await tester.tap(find.text('Replies'));
      await tester.pumpAndSettle();
      expect(find.text('post 130'), findsOneWidget);
      // The header stays collapsed; the new tab starts at its own top.
      expect(
        tester.getRect(find.byType(AppTabBar)).top,
        closeTo(outerCollapsed, 0.5),
      );
      expect(innerPosition(tester).pixels, 0);

      await scrollUp(tester, 400);
      final repliesOffset = innerPosition(tester).pixels;
      expect(repliesOffset, greaterThan(100));
      expect(repliesOffset, isNot(closeTo(postsOffset, 1)));

      await tester.tap(find.text('Posts'));
      await tester.pumpAndSettle();
      expect(innerPosition(tester).pixels, closeTo(postsOffset, 0.5));

      await tester.tap(find.text('Replies'));
      await tester.pumpAndSettle();
      expect(innerPosition(tester).pixels, closeTo(repliesOffset, 0.5));

      // Switching tabs never asked the server again.
      verify(() => timeline.refresh(ownFeed)).called(1);
      verify(() => timeline.refresh(ownReplies)).called(1);
    });

    testWidgets('scrolling a tab past 70 % loads its next page once', (
      tester,
    ) async {
      arrange();
      final withMore = snapshotOf(
        [for (var i = 30; i >= 1; i--) i],
        older: 'o1',
        authorId: 'viewer-uid',
      );
      when(() => timeline.cached(ownFeed)).thenAnswer((_) async => withMore);
      when(() => timeline.refresh(ownFeed)).thenAnswer((_) async => withMore);
      when(() => timeline.loadOlder(ownFeed)).thenAnswer(
        (_) async => snapshotOf([
          for (var i = 30; i >= 1; i--) i,
        ], authorId: 'viewer-uid'),
      );
      await open(tester);
      verifyNever(() => timeline.loadOlder(ownFeed));

      await scrollUp(tester, 4000);

      verify(() => timeline.loadOlder(ownFeed)).called(1);
    });

    for (final collapsed in [false, true]) {
      testWidgets(
        'the "new posts" pill ${collapsed ? 'sits under the pinned tabs and '
                  'takes the tap' : 'floats in the list at the top'}',
        (tester) async {
          arrange(own: false);
          final cached = snapshotOf([
            for (var i = 30; i >= 1; i--) i,
          ], authorId: 'target-uid');
          final refreshed = Completer<TimelineSnapshot>();
          when(() => timeline.cached(targetFeed))
              .thenAnswer((_) async => cached);
          when(() => timeline.refresh(targetFeed))
              .thenAnswer((_) => refreshed.future);
          await open(tester);
          if (collapsed) await scrollUp(tester, 1500);

          refreshed.complete(
            snapshotOf(
              [31, for (var i = 30; i >= 1; i--) i],
              since: 's2',
              authorId: 'target-uid',
            ),
          );
          await tester.pumpAndSettle();

          final pill = find.text('1 new post');
          expect(pill, findsOneWidget);
          final bar = tester.getRect(find.byType(AppTabBar));
          expect(tester.getRect(pill).top, greaterThanOrEqualTo(bar.bottom));

          await tester.tap(pill);
          await tester.pumpAndSettle();
          expect(find.text('1 new post'), findsNothing);
          expect(find.text('post 31'), findsOneWidget);
        },
      );
    }

    testWidgets('a tab nobody opens costs no request', (tester) async {
      arrange();
      await open(tester);

      verify(() => timeline.refresh(ownFeed)).called(1);
      verifyNever(() => timeline.refresh(ownReplies));
    });

    testWidgets('pull-to-refresh at the top refreshes the selected tab only', (
      tester,
    ) async {
      arrange();
      await open(tester);

      await tester.fling(
        find.byType(TimelineFeedView),
        const Offset(0, 400),
        1000,
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      verify(() => timeline.refresh(ownFeed)).called(2);
      verifyNever(() => timeline.refresh(ownReplies));

      await tester.tap(find.text('Replies'));
      await tester.pumpAndSettle();
      verify(() => timeline.refresh(ownReplies)).called(1);
      await tester.fling(
        find.byType(TimelineFeedView),
        const Offset(0, 400),
        1000,
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      verify(() => timeline.refresh(ownReplies)).called(1);
      verifyNever(() => timeline.refresh(ownFeed));
    });

    testWidgets('the tabs announce the selected one', (tester) async {
      final handle = tester.ensureSemantics();
      arrange();
      await open(tester);

      expect(
        tester.getSemantics(find.text('Posts').first),
        matchesSemantics(
          label: 'Posts',
          isButton: true,
          isSelected: true,
          isInMutuallyExclusiveGroup: true,
          hasSelectedState: true,
          hasTapAction: true,
        ),
      );
      await tester.tap(find.text('Replies'));
      await tester.pumpAndSettle();
      expect(
        tester.getSemantics(find.text('Replies').first),
        matchesSemantics(
          label: 'Replies',
          isButton: true,
          isSelected: true,
          isInMutuallyExclusiveGroup: true,
          hasSelectedState: true,
          hasTapAction: true,
        ),
      );
      handle.dispose();
    });
  });

  group('app-bar name fade', () {
    test(
      'profileNameFade: 0 clear of the bar, 1 once the name is under it',
      () {
        expect(profileNameFade(distanceUnderBar: -500), 0);
        expect(profileNameFade(distanceUnderBar: -kProfileNameFadeDistance), 0);
        expect(
          profileNameFade(distanceUnderBar: -kProfileNameFadeDistance / 2),
          closeTo(0.5, 1e-9),
        );
        expect(profileNameFade(distanceUnderBar: 0), 1);
        expect(profileNameFade(distanceUnderBar: 300), 1);
      },
    );

    testWidgets('0 at the top, 1 once the header is gone', (tester) async {
      arrange();
      await open(tester);
      expect(fade(tester), 0);

      await scrollUp(tester, 1500);
      expect(fade(tester), 1);

      await tester.drag(
        find.byType(TimelineFeedView),
        const Offset(0, 3000),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(fade(tester), 0);
    });

    testWidgets('fades in while the header name slips under the bar', (
      tester,
    ) async {
      arrange();
      await open(tester);
      final gap = tester.getRect(headerName()).bottom - appBarBottom(tester);

      // Leave the name 12dp (half of the 24dp fade distance) below the bar.
      await jumpOuter(tester, gap - 12);

      final under = appBarBottom(tester) - tester.getRect(headerName()).bottom;
      expect(under, closeTo(-12, 0.5));
      final value = fade(tester);
      expect(value, closeTo(0.5, 0.05));
    });

    testWidgets('reduced motion: the name switches, it never half-fades', (
      tester,
    ) async {
      arrange();
      await open(tester, disableAnimations: true);
      final gap = tester.getRect(headerName()).bottom - appBarBottom(tester);

      // 20dp short of the bar: the scroll-linked value would be about 0.17.
      await jumpOuter(tester, gap - 20);
      expect(fade(tester), 0);

      // 8dp short: about 0.67 linked, so it has switched on.
      await jumpOuter(tester, gap - 8);
      expect(fade(tester), 1);

      await jumpOuter(tester, 0);
      expect(fade(tester), 0);
    });

    testWidgets('the title is one widget whose spoken name never changes', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      arrange();
      await open(tester);

      // One title in the bar (nothing crossfaded); the header has the other.
      final inBar = find.descendant(
        of: find.byType(AppBar),
        matching: find.text('Kaif'),
      );
      expect(inBar, findsOneWidget);
      expect(find.text('Kaif'), findsNWidgets(2));
      // At 0 opacity the title still names the screen (its route name), as
      // before W3-13, so the name is spoken by the title and by the header.
      expect(spoken(tester, 'Kaif'), 2);

      await scrollUp(tester, 1500);
      expect(inBar, findsOneWidget);
      // The header's node is hidden with the header; the title's remains.
      expect(spoken(tester, 'Kaif'), 1);
      handle.dispose();
    });
  });
  group('Joined row', () {
    testWidgets('own profile: "Joined March 2026" under the bio', (
      tester,
    ) async {
      arrange();
      await open(tester);

      final joined = find.text('Joined March 2026');
      expect(joined, findsOneWidget);
      expect(
        tester.getRect(joined).top,
        greaterThan(tester.getRect(find.text('Builds things.')).bottom),
      );
      expect(
        tester.getRect(joined).bottom,
        lessThanOrEqualTo(tester.getRect(find.text('30 Posts')).top),
      );
    });

    testWidgets("another user's profile shows it too", (tester) async {
      arrange(own: false);
      await open(tester);

      expect(find.text('Joined March 2026'), findsOneWidget);
    });

    testWidgets('no created time: no row (never "January 1970")', (
      tester,
    ) async {
      arrange(withCreated: false);
      await open(tester);

      expect(find.textContaining('Joined'), findsNothing);
      expect(find.textContaining('1970'), findsNothing);
    });

    testWidgets('is spoken as one phrase, the icon is silent', (tester) async {
      final handle = tester.ensureSemantics();
      arrange();
      await open(tester);

      expect(spoken(tester, 'Joined March 2026'), 1);
      handle.dispose();
    });
  });

  for (final own in [true, false]) {
    for (final entry in {
      'dark': appDarkTheme,
      'light': appLightTheme,
    }.entries) {
      for (final width in const [360.0, 600.0, 1200.0]) {
        for (final scale in const [1.0, 1.3, 2.0]) {
          testWidgets('responsive matrix (W3-13): ${own ? 'own' : 'other'} '
              '${entry.key} ${width.toInt()}dp x$scale: header, pinned tabs '
              'and rows do not overflow', (tester) async {
            arrange(own: own);
            await open(
              tester,
              size: Size(width, 900),
              theme: entry.value,
              textScale: scale,
            );

            expect(tester.takeException(), isNull);
            expect(find.text('Joined March 2026'), findsOneWidget);
            expect(find.text('Replies'), findsOneWidget);
            final bar = tester.getRect(find.byType(AppTabBar));
            expect(bar.width, lessThanOrEqualTo(600.5));
            expect(bar.left, greaterThanOrEqualTo(0));
            expect(bar.right, lessThanOrEqualTo(width + 0.5));

            await scrollUp(tester, 2500);
            expect(tester.takeException(), isNull);
            expect(
              tester.getRect(find.byType(AppTabBar)).top,
              closeTo(appBarBottom(tester), 0.5),
            );
            expect(fade(tester), 1);
            expect(find.byType(AppTabBar).hitTestable(), findsOneWidget);

            await tester.tap(find.text('Replies'));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expect(find.text('post 130'), findsOneWidget);
          });
        }
      }
    }
  }

  testWidgets('320dp at text scale 2.0: the meta row wraps without overflow', (
    tester,
  ) async {
    arrange();
    await open(tester, size: const Size(320, 900), textScale: 2);

    expect(tester.takeException(), isNull);
    expect(find.text('Joined March 2026'), findsOneWidget);
    expect(
      tester.getRect(find.text('Joined March 2026')).right,
      lessThanOrEqualTo(320),
    );
  });

  testWidgets('dark mode: tab bar and Joined text keep AA contrast tokens', (
    tester,
  ) async {
    arrange();
    await open(tester, theme: appDarkTheme);

    final text = tester.widget<Text>(find.text('Joined March 2026'));
    expect(text.style?.color, appDarkTheme.colorScheme.onSurfaceVariant);
  });
}
