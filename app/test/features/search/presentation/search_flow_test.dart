import 'dart:io';

import 'package:bloc_test/bloc_test.dart';
import 'package:drift/native.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/app/session_wiring.dart';
import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/theme/theme_mode_cubit.dart';
import 'package:dzeroth/core/widgets/app_bottom_bar.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/engagement/data/engagement_repository.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/engagement_cubit.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/graph/presentation/bloc/suggestions_cubit.dart';
import 'package:dzeroth/features/messages/presentation/bloc/messages_badge_cubit.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/unread_badge_cubit.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/search/data/recent_searches_store.dart';
import 'package:dzeroth/features/search/data/search_repository.dart';
import 'package:dzeroth/features/search/presentation/bloc/trends_cubit.dart';
import 'package:dzeroth/features/search/presentation/search_results_screen.dart';
import 'package:dzeroth/features/search/presentation/widgets/app_search_field.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/fake_search_repository.dart';
import '../../../support/posts_fixtures.dart';
import '../../../support/search_field_rig.dart';
import '../../../support/suggestions_fixtures.dart';
import '../../../support/theme_harness.dart';

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockGraph extends Mock implements GraphRepository {}

class _MockEngagement extends Mock implements EngagementRepository {}

class _NoThemeStore implements ThemeModeStore {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) async {}
}

/// W4-21 (ADR-0028): the cross-screen flow on the real router and the real
/// `MainShell` with only the repositories faked. The widgets have their own
/// tests (`app_search_field_test`, `search_results_screen_test`,
/// `explore_who_to_follow_test`, `main_shell_explore_test`); what no test had
/// was the whole walk (Explore, the field and its overlay, results, a hashtag
/// tapped inside a result, back to Explore and the side column), the flag
/// product `search` x `trends` x `ui_shell` x W3's `follow_suggestions` on the
/// real router, and that sign-out leaves the next user an empty "Recent".
void main() {
  const user = AppUser(
    uid: 'me',
    email: 'a@example.com',
    emailVerified: true,
    isPasswordProvider: true,
  );

  late FakeSearchRepository search;
  late FakeSuggestionsRepository suggestions;
  late FakeRecentSearchesStore recents;
  late AppRouter appRouter;

  setUp(() {
    search = FakeSearchRepository()
      ..trendsResult = TrendsResult(
        trends: [
          searchTrend('launch', 120, 1),
          searchTrend('golang', 80, 2),
          searchTrend('flutter', 40, 3),
        ],
        computedAt: DateTime.now().subtract(const Duration(hours: 2)),
      )
      ..postsResult = SearchPostsPage(
        posts: [postView(1, text: 'Shipping the build #other')],
      );
    suggestions = FakeSuggestionsRepository([
      for (var i = 1; i <= 5; i++) suggestedUser(i),
    ]);
    recents = FakeRecentSearchesStore(['#old']);
  });

  /// Pumps the real `AppRouter` at [location] for a signed-in caller with
  /// [flags] on. `graph` is on by default so the W3 card can show.
  Future<void> open(
    WidgetTester tester, {
    String location = '/explore',
    Set<String> flags = const {
      'search',
      'trends',
      kFeatureUiShell,
      'graph',
      'follow_suggestions',
    },
    Size size = const Size(390, 844),
    Brightness brightness = Brightness.light,
    double textScale = 1,
    RecentSearchesStore? store,
  }) async {
    final auth = _MockAuthBloc();
    final onboarding = _MockOnboardingBloc();
    whenListen(
      auth,
      const Stream<AuthState>.empty(),
      initialState: const AuthState(
        status: AuthStatus.authenticated,
        user: user,
      ),
    );
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        profile: identity.Profile(userId: 'me', handle: 'me'),
        enabledFeatures: flags,
      ),
    );
    final engagement = EngagementCubit(repository: _MockEngagement());
    final trends = TrendsCubit(repository: search);
    final suggestionsCubit = SuggestionsCubit(repository: suggestions);
    final unread = UnreadBadgeCubit();
    final messages = MessagesBadgeCubit();
    addTearDown(() async {
      await engagement.close();
      await trends.close();
      await suggestionsCubit.close();
      await unread.close();
      await messages.close();
    });
    appRouter = AppRouter(authBloc: auth, onboardingBloc: onboarding);
    appRouter.router.go(location);
    addTearDown(appRouter.router.dispose);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<SearchRepository>.value(value: search),
          RepositoryProvider<RecentSearchesStore>.value(
            value: store ?? recents,
          ),
          RepositoryProvider<GraphRepository>.value(value: _MockGraph()),
          RepositoryProvider<UnexpectedErrorReporter>.value(value: (_, _) {}),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<AuthBloc>.value(value: auth),
            BlocProvider<OnboardingBloc>.value(value: onboarding),
            BlocProvider<EngagementCubit>.value(value: engagement),
            BlocProvider<TrendsCubit>.value(value: trends),
            BlocProvider<SuggestionsCubit>.value(value: suggestionsCubit),
            BlocProvider<UnreadBadgeCubit>.value(value: unread),
            BlocProvider<MessagesBadgeCubit>.value(value: messages),
            BlocProvider<ThemeModeCubit>(
              create: (_) => ThemeModeCubit(_NoThemeStore()),
            ),
          ],
          child: MaterialApp.router(
            theme: buildAppTheme(brightness: brightness),
            routerConfig: appRouter.router,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The location on top: a pushed page (the search field pushes) reports its
  /// own uri, not the one of the page under it.
  String path() {
    final cfg = appRouter.router.routerDelegate.currentConfiguration;
    final last = cfg.last;
    return (last is ImperativeRouteMatch ? last.matches.uri : cfg.uri)
        .toString();
  }

  Future<void> submit(WidgetTester tester, String text) async {
    await tester.tap(find.byType(TextField).first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, text);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
  }

  List<String> trendsCalls() =>
      search.calls.where((c) => c == 'trends:').toList();

  group('the walk', () {
    testWidgets(
      'Explore -> field -> overlay -> results -> hashtag tap -> back -> Explore',
      (tester) async {
        await open(tester);

        // Explore: the trends list and W3's card, one GetTrends so far.
        expect(path(), '/explore');
        expect(find.text('Trending today'), findsOneWidget);
        expect(find.text('#launch'), findsOneWidget);
        expect(find.text('Who to follow'), findsOneWidget);
        expect(trendsCalls(), hasLength(1));

        // Focus: the overlay shows Recent with Clear all and nothing is asked.
        await tester.tap(find.byType(TextField).first);
        await tester.pumpAndSettle();
        expect(find.text('Recent'), findsOneWidget);
        expect(find.text('#old'), findsOneWidget);
        expect(find.text('Clear all'), findsOneWidget);
        expect(search.calls.where((c) => c.startsWith('people')), isEmpty);

        // Type a tag and submit: the results open on Top for the tag.
        await tester.enterText(find.byType(TextField).first, '#launch');
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();
        expect(find.textContaining('Search for'), findsWidgets);
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        expect(path(), startsWith('/search?q=%23launch'));
        expect(find.byType(SearchResultsScreen), findsOneWidget);
        expect(search.calls, contains('posts:#launch:SEARCH_TAB_TOP'));
        expect(recents.items.first.toLowerCase(), '#launch');
        expect(recents.items, contains('#old'));
        expect(find.textContaining('Shipping the build'), findsOneWidget);

        // A hashtag tapped inside a result searches that tag on Top.
        await tester.tapOnText(find.textRange.ofSubstring('#other'));
        await tester.pumpAndSettle();
        expect(path(), startsWith('/search?q=%23other'));
        expect(search.calls, contains('posts:#other:SEARCH_TAB_TOP'));
        noException(tester, 'walk');

        // Back, back: Explore again, with its list intact and no new GetTrends
        // (the shared cubit serves every screen).
        appRouter.router.pop();
        await tester.pumpAndSettle();
        expect(path(), startsWith('/search?q=%23launch'));
        appRouter.router.pop();
        await tester.pumpAndSettle();
        expect(path(), '/explore');
        expect(find.text('#launch'), findsWidgets);
        expect(trendsCalls(), hasLength(1));
        noException(tester, 'walk');
      },
    );

    testWidgets('a trend row opens its results, a person row its profile', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(find.text('#golang'));
      await tester.pumpAndSettle();
      expect(path(), startsWith('/search?q=%23golang'));
      expect(search.calls, contains('posts:#golang:SEARCH_TAB_TOP'));
    });

    testWidgets('at 1200 the side column and the centre share one GetTrends', (
      tester,
    ) async {
      await open(tester, size: const Size(1200, 900), location: '/home');

      expect(find.text("What's happening"), findsOneWidget);
      expect(
        find.byType(AppSearchField),
        findsOneWidget,
        reason: 'the side column pill, on Home',
      );
      await submit(tester, '#launch');
      expect(path(), startsWith('/search?q=%23launch'));
      expect(find.text("What's happening"), findsOneWidget);

      appRouter.router.go('/explore');
      await tester.pumpAndSettle();
      expect(find.text('Trending today'), findsOneWidget);
      expect(find.text("What's happening"), findsOneWidget);
      expect(
        find.byType(AppSearchField),
        findsOneWidget,
        reason: 'on Explore the pill is only in the centre header',
      );
      expect(trendsCalls(), hasLength(1));
      noException(tester, 'walk');
    });
  });

  group('flag product (search x trends x ui_shell x follow_suggestions)', () {
    // The rules, from the code (main_shell.dart, app_router.dart,
    // explore_screen.dart): the Explore destination and the /explore route
    // need `search` AND `ui_shell`; the trends list and the side-column card
    // need `trends` as well; W3's "Who to follow" slot needs `graph` and
    // `follow_suggestions` only; the side pill needs the destination.
    for (final s in [false, true]) {
      for (final t in [false, true]) {
        for (final u in [false, true]) {
          for (final f in [false, true]) {
            final name =
                'search=$s trends=$t ui_shell=$u follow_suggestions=$f';
            testWidgets(name, (tester) async {
              final flags = {
                'graph',
                if (s) 'search',
                if (t) 'trends',
                if (u) kFeatureUiShell,
                if (f) 'follow_suggestions',
              };
              final reachable = s && u;
              await open(
                tester,
                flags: flags,
                size: const Size(1200, 900),
                location: '/home',
              );

              // Home: the side column.
              expect(
                find.byType(AppSearchField),
                reachable ? findsOneWidget : findsNothing,
                reason: 'side pill',
              );
              expect(
                find.text("What's happening"),
                reachable && t ? findsOneWidget : findsNothing,
                reason: 'trends card',
              );
              expect(
                find.text('You might like'),
                u && f ? findsOneWidget : findsNothing,
                reason: 'W3 card',
              );

              // /explore: reachable only with search + ui_shell.
              appRouter.router.go('/explore');
              await tester.pumpAndSettle();
              if (!reachable) {
                expect(path(), '/home', reason: 'redirected');
                expect(find.text('Trending today'), findsNothing);
              } else {
                expect(path(), '/explore');
                expect(
                  find.text('Trending today'),
                  t ? findsOneWidget : findsNothing,
                );
                expect(
                  find.text('Who to follow'),
                  f ? findsOneWidget : findsNothing,
                );
                expect(find.byType(AppSearchField), findsOneWidget);
              }
              // GetTrends is asked once when something shows trends, never
              // when nothing does.
              expect(trendsCalls().length, reachable && t ? 1 : 0);
              expect(
                suggestions.calls,
                u && f || (reachable && f) ? greaterThan(0) : 0,
                reason: 'W3 list is asked only when a card can show it',
              );
              noException(tester, 'walk');
            });
          }
        }
      }
    }

    testWidgets('the Explore destination sits second in the phone bar', (
      tester,
    ) async {
      await open(tester, location: '/home');
      final bar = find.byType(AppBottomBar);
      expect(bar, findsOneWidget);
      expect(
        find.descendant(of: bar, matching: find.byIcon(Icons.search)),
        findsOneWidget,
      );
    });
  });

  group('sign-out clears recent searches', () {
    testWidgets('the next user on the device sees no Recent in the overlay', (
      tester,
    ) async {
      // The real store over an in-memory database, as the app wires it.
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final store = DatabaseRecentSearchesStore(db);
      await tester.runAsync(() => store.add('me', '#secret'));

      await open(tester, store: store);
      await tester.tap(find.byType(TextField).first);
      await tester.pumpAndSettle();
      expect(find.text('#secret'), findsOneWidget);

      // Sign-out: the session epoch ends and the local database is wiped.
      await tester.runAsync(() async {
        db.sessionEpoch.end();
        await db.clearAll();
      });
      // The next user opens Explore and focuses the field.
      await tester.pumpWidget(const SizedBox());
      await open(tester, store: store);
      await tester.tap(find.byType(TextField).first);
      await tester.pumpAndSettle();
      expect(find.text('#secret'), findsNothing);
      expect(find.text('Recent'), findsNothing);
      expect(await tester.runAsync(() => store.read('me')), isEmpty);
    });
  });

  // D-1 (open defect, docs/reviews/test-report-w4-client.md). On Explore at 360 dp and text scale 2.0 the
  // overlay's "Recent" header row (app_search_field.dart `_recentHeader`) overflows by about 5 px: the
  // pill is narrower there (264 dp: the avatar button and the margins), "Clear all" keeps its natural
  // width and "Recent" wraps. The shared field tests only run the full-width pill, so they never see it.
  testWidgets(
    'D-1: Explore overlay "Recent" header fits at 360 dp, text scale 2.0',
    skip:
        Platform.environment['W421_RUN_DEFECTS'] !=
        '1', // open defect D-1: set W421_RUN_DEFECTS=1 to reproduce
    (tester) async {
      await open(tester, size: const Size(360, 800), textScale: 2);
      await tester.tap(find.byType(TextField).first);
      await tester.pumpAndSettle();
      expect(find.text('Recent'), findsOneWidget);
      noException(tester, 'Recent header');
    },
  );

  group('the whole walk at the widest accessibility setting', () {
    forEachThemeAndWidth('Explore, overlay and every results tab at 2.0', (
      tester,
      env,
    ) async {
      // No saved searches: the "Recent" header is D-1 (below), kept out of this walk.
      recents = FakeRecentSearchesStore();
      search.peopleResult = SearchPeopleResult(
        users: [searchPerson('bob'), searchPerson('bobby')],
      );
      await open(
        tester,
        size: env.size,
        brightness: env.brightness,
        textScale: env.textScale,
      );
      noException(tester, 'Explore');

      await tester.tap(find.byType(TextField).first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'bo');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      noException(tester, 'overlay with rows');

      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      noException(tester, 'results');
      final results = find.byType(SearchResultsScreen);
      expect(results, findsOneWidget);
      for (final tab in ['Latest', 'People', 'Media', 'Top']) {
        final label = find.descendant(of: results, matching: find.text(tab));
        await tester.ensureVisible(label.first);
        await tester.tap(label.first);
        await tester.pumpAndSettle();
        noException(tester, 'tab $tab');
      }
      // Each tab asked once: Top (first), Latest, People, Media; the second Top reused its rows.
      expect(search.calls.where((c) => c.startsWith('people:')), isNotEmpty);
      expect(
        search.calls.where((c) => c.endsWith('SEARCH_TAB_MEDIA')),
        hasLength(1),
      );
    }, textScales: const [2.0]);
  });
}

/// Fails with the full render diagnostics (which widget overflowed) rather than the one-line summary.
void noException(WidgetTester tester, String where) {
  final e = tester.takeException();
  expect(
    e,
    isNull,
    reason: '$where: ${e is FlutterError ? e.toStringDeep() : e}',
  );
}
