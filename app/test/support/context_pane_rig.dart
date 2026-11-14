import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/router/main_shell.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/theme/theme_mode_cubit.dart';
import 'package:dzeroth/core/widgets/app_top_bar.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/graph/data/suggestions_repository.dart';
import 'package:dzeroth/features/graph/presentation/bloc/suggestions_cubit.dart';
import 'package:dzeroth/features/messages/presentation/bloc/messages_badge_cubit.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/unread_badge_cubit.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/search/data/recent_searches_store.dart';
import 'package:dzeroth/features/search/data/search_repository.dart';
import 'package:dzeroth/features/search/presentation/bloc/trends_cubit.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import 'fake_search_repository.dart';
import 'search_field_rig.dart';
import 'suggestions_fixtures.dart';

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockGraph extends Mock implements GraphRepository {}

class _MemoryThemeStore implements ThemeModeStore {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) async {}
}

/// Every flag a side-column section reads, plus the tablet shell's two:
/// the search pill (`search`), What's happening (`search` + `trends`), Who
/// to follow (`graph` + `follow_suggestions`), with `posts` and
/// `notifications` for the rail.
const kContextPaneFlags = <String>{
  'posts',
  'notifications',
  'search',
  'trends',
  'graph',
  'follow_suggestions',
  kFeatureUiShell,
  kFeatureUiTablet,
};

/// The flag modes the tablet shell distinguishes (tablet plan section 2.3):
/// only `ui_shell` + `ui_tablet` draws the tablet layout.
const kTabletFlagModes = <String, Set<String>>{
  'neither': {},
  'ui_shell only': {kFeatureUiShell},
  'ui_tablet only': {kFeatureUiTablet},
  'ui_shell + ui_tablet': {kFeatureUiShell, kFeatureUiTablet},
};

/// The paths [ContextPaneRig] routes, each a `ShellRoute` child under the
/// real `MainShell`.
const kContextPaneRigPaths = <String>[
  '/home',
  '/explore',
  '/explore/trending',
  '/explore/media',
  '/post/:id/photo/:index',
  '/notifications',
  '/search',
  '/follow-requests',
  '/bookmarks',
  '/settings',
  '/settings/blocked',
  '/settings/muted',
  '/messages',
  '/plans',
  '/plans/:id',
  '/plans/:id/people',
  '/plans/:id/edit',
  '/creator-studio',
  '/profile/:handle',
  '/profile/:handle/followers',
  '/profile/:handle/following',
  '/u/:userId',
];

/// The key of the stub page's focusable action (focus-order tests).
const kPrimaryActionKey = Key('primary-action');

/// The real `MainShell` in a real `ShellRoute`, with the shared cubits the
/// context-pane sections read (`TrendsCubit`, `SuggestionsCubit`) over fakes,
/// so a test sees exactly what the pane draws and how many calls go out.
///
/// The pages are stubs (a top bar, the path as text and one button) unless
/// [ContextPaneRig.pump]'s `page` builds a real one.
class ContextPaneRig {
  ContextPaneRig({
    FakeSearchRepository? search,
    SuggestionsRepository? suggestions,
  }) : search =
           search ??
           (FakeSearchRepository()
             ..trendsResult = TrendsResult(
               trends: [
                 for (var i = 1; i <= 6; i++) searchTrend('tag$i', 100 * i, i),
               ],
               computedAt: DateTime.now().subtract(const Duration(hours: 2)),
             )),
       suggestionsRepository =
           suggestions ??
           FakeSuggestionsRepository([
             for (var i = 1; i <= 5; i++) suggestedUser(i),
           ]);

  final FakeSearchRepository search;
  final SuggestionsRepository suggestionsRepository;
  late TrendsCubit trends;
  late SuggestionsCubit suggestions;
  late GoRouter router;

  /// `suggestionsFor` calls of the default fake (null for another
  /// repository).
  int? get suggestionCalls {
    final repo = suggestionsRepository;
    return repo is FakeSuggestionsRepository ? repo.calls : null;
  }

  /// `GetTrends` calls.
  int get trendCalls =>
      search.calls.where((c) => c.startsWith('trends')).length;

  /// Pumps the shell at [location] in a [width] x [height] window.
  ///
  /// [flags] is the full `enabled_features` set (include `ui_shell` and
  /// `ui_tablet` yourself). [page] builds the page for a matched path;
  /// null draws the stub. [wrap] goes around the app inside the rig's
  /// providers, so a feature test can add (or override) its own.
  Future<void> pump(
    WidgetTester tester, {
    String location = '/home',
    double width = 1024,
    double height = 768,
    Set<String> flags = kContextPaneFlags,
    bool profile = true,
    double textScale = 1,
    Brightness brightness = Brightness.light,
    EdgeInsets padding = EdgeInsets.zero,
    TextDirection textDirection = TextDirection.ltr,
    Widget Function(String path)? page,
    Widget Function(Widget app)? wrap,
    int pendingFollowRequests = 0,
    bool isProtected = false,
  }) async {
    final onboarding = _MockOnboardingBloc();
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        enabledFeatures: flags,
        pendingFollowRequestCount: pendingFollowRequests,
        profile: profile
            ? identity.Profile(
                userId: 'u-alice',
                handle: 'alice',
                displayName: 'Alice A',
                isPrivate: isProtected,
              )
            : null,
      ),
    );
    final auth = _MockAuthBloc();
    whenListen(
      auth,
      const Stream<AuthState>.empty(),
      initialState: const AuthState(status: AuthStatus.authenticated),
    );
    trends = TrendsCubit(repository: search);
    addTearDown(trends.close);
    suggestions = SuggestionsCubit(repository: suggestionsRepository);
    addTearDown(suggestions.close);
    final unread = UnreadBadgeCubit(0);
    addTearDown(unread.close);
    final messages = MessagesBadgeCubit();
    addTearDown(messages.close);

    Widget stub(String path) => Scaffold(
      appBar: const AppTopBar(title: 'Page'),
      body: ListView(
        key: const Key('primary-list'),
        children: [
          Text('$path body'),
          TextButton(
            key: kPrimaryActionKey,
            onPressed: () {},
            child: const Text('Primary action'),
          ),
        ],
      ),
    );

    router = GoRouter(
      initialLocation: location,
      routes: [
        ShellRoute(
          builder: (context, state, child) =>
              MainShell(location: state.matchedLocation, child: child),
          routes: [
            for (final path in kContextPaneRigPaths)
              GoRoute(
                path: path,
                builder: (context, state) =>
                    (page ?? stub)(state.matchedLocation),
              ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, height);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<OnboardingBloc>.value(value: onboarding),
          BlocProvider<AuthBloc>.value(value: auth),
          BlocProvider<UnreadBadgeCubit>.value(value: unread),
          BlocProvider<MessagesBadgeCubit>.value(value: messages),
          BlocProvider<TrendsCubit>.value(value: trends),
          BlocProvider<SuggestionsCubit>.value(value: suggestions),
          BlocProvider<ThemeModeCubit>(
            create: (_) => ThemeModeCubit(_MemoryThemeStore()),
          ),
        ],
        child: MultiRepositoryProvider(
          providers: [
            RepositoryProvider<GraphRepository>.value(value: _MockGraph()),
            RepositoryProvider<SearchRepository>.value(value: search),
            RepositoryProvider<RecentSearchesStore>.value(
              value: FakeRecentSearchesStore(),
            ),
          ],
          child: (wrap ?? (app) => app)(
            MaterialApp.router(
              theme: buildAppTheme(brightness: brightness),
              routerConfig: router,
              builder: (context, child) => Directionality(
                textDirection: textDirection,
                child: MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(textScale),
                    padding: padding,
                    viewPadding: padding,
                  ),
                  child: child!,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }
}

/// Plan section 3's geometry for the page [primary] in a [width] dp window
/// with no side insets, on the tablet layout: the page starts after the
/// 80 dp rail and takes the whole content (no side column, no context pane).
void expectTabletPanes(WidgetTester tester, Finder primary, double width) {
  final page = tester.getRect(primary);
  expect(page.left, AppSize.railCompact, reason: 'page starts after the rail');
  expect(
    page.width,
    width - AppSize.railCompact,
    reason: 'the page takes the whole content',
  );
}
