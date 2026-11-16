import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/router/main_shell.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/theme/theme_mode_cubit.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/beacons/data/beacons_repository.dart';
import 'package:dzeroth/features/beacons/presentation/bloc/plans_session.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/lists/data/lists_repository.dart';
import 'package:dzeroth/features/messages/presentation/bloc/messages_badge_cubit.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/unread_badge_cubit.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/search/data/recent_searches_store.dart';
import 'package:dzeroth/features/search/data/search_repository.dart';
import 'package:dzeroth/features/search/presentation/bloc/trends_cubit.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/lists/v1/lists.pb.dart' as lists_pb;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/beacons_fixtures.dart';
import '../../support/fake_beacons_server.dart';
import '../../support/fake_search_repository.dart';
import '../../support/search_field_rig.dart';

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockGraph extends Mock implements GraphRepository {}

class _MockLists extends Mock implements ListsRepository {}

class _MemoryThemeStore implements ThemeModeStore {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) async {}
}

/// The desktop pages' side boxes the global column adds (the desktop mocks'
/// "Plans near you" and "Discover new Lists"): at 1440 dp, light and dark,
/// each box is on its pages with its flags, off without them, and on no
/// other page. The pages are stand-ins: the boxes belong to the shell column.
void main() {
  late _MockOnboardingBloc onboarding;
  late _MockAuthBloc auth;
  late FakeBeaconsServer beacons;
  late _MockLists lists;

  setUp(() {
    onboarding = _MockOnboardingBloc();
    auth = _MockAuthBloc();
    whenListen(
      auth,
      const Stream<AuthState>.empty(),
      initialState: const AuthState(status: AuthStatus.authenticated),
    );
    beacons = FakeBeaconsServer();
    final start = DateTime.now().add(const Duration(days: 1));
    beacons.public.addAll([
      beaconView(startAt: start, title: 'Flat white before work'),
      beaconView(
        startAt: start.add(const Duration(days: 1)),
        id: kBeaconIdB,
        title: 'Sunrise walk',
      ),
    ]);
    lists = _MockLists();
    when(
      () => lists.discoverLists(
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer(
      (_) async => ListsPage(
        lists: [
          lists_pb.ListInfo(
            listId: 'l1',
            name: 'Sunrise crew',
            memberCount: 31,
            owner: common.AuthorSnapshot(userId: 'u-riya', handle: 'riya'),
          ),
        ],
      ),
    );
  });

  Future<void> pump(
    WidgetTester tester, {
    required String location,
    required Set<String> flags,
    required Brightness brightness,
  }) async {
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        enabledFeatures: {...flags, kFeatureUiShell},
        profile: identity.Profile(
          userId: 'u-alice',
          handle: 'alice',
          displayName: 'Alice A',
        ),
      ),
    );
    GoRoute route(String path) => GoRoute(
      path: path,
      builder: (context, state) => MainShell(
        location: state.matchedLocation,
        child: Center(child: Text('page ${state.matchedLocation}')),
      ),
    );
    final router = GoRouter(
      initialLocation: location,
      routes: [
        route('/home'),
        route('/explore'),
        route('/post/:id'),
        route('/plans/mine'),
        route('/lists'),
        route('/notifications'),
        route('/profile/alice'),
      ],
    );
    addTearDown(router.dispose);
    final messages = MessagesBadgeCubit();
    addTearDown(messages.close);
    final unread = UnreadBadgeCubit();
    addTearDown(unread.close);
    final trends = TrendsCubit(repository: FakeSearchRepository());
    addTearDown(trends.close);
    final session = PlansSession(repository: beacons);
    addTearDown(session.dispose);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<OnboardingBloc>.value(value: onboarding),
          BlocProvider<AuthBloc>.value(value: auth),
          BlocProvider<UnreadBadgeCubit>.value(value: unread),
          BlocProvider<MessagesBadgeCubit>.value(value: messages),
          BlocProvider<TrendsCubit>.value(value: trends),
          BlocProvider<ThemeModeCubit>(
            create: (_) => ThemeModeCubit(_MemoryThemeStore()),
          ),
        ],
        child: MultiRepositoryProvider(
          providers: [
            RepositoryProvider<GraphRepository>.value(value: _MockGraph()),
            RepositoryProvider<SearchRepository>.value(
              value: FakeSearchRepository(),
            ),
            RepositoryProvider<RecentSearchesStore>.value(
              value: FakeRecentSearchesStore(),
            ),
            RepositoryProvider<BeaconsRepository>.value(value: beacons),
            RepositoryProvider<PlansSession>.value(value: session),
            RepositoryProvider<ListsRepository>.value(value: lists),
          ],
          child: MaterialApp.router(
            theme: buildAppTheme(brightness: brightness),
            routerConfig: router,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  const upcoming = 'Upcoming plans';
  const discover = 'Discover new Lists';

  for (final brightness in Brightness.values) {
    group('1440 dp, ${brightness.name}', () {
      for (final location in ['/explore', '/post/p1', '/plans/mine']) {
        testWidgets('$location: Upcoming plans shows with beacons', (
          tester,
        ) async {
          await pump(
            tester,
            location: location,
            flags: {'search', 'beacons'},
            brightness: brightness,
          );
          expect(find.text(upcoming), findsOneWidget);
          expect(find.text('Flat white before work'), findsOneWidget);
          expect(find.text('Sunrise walk'), findsOneWidget);
          expect(find.text('See all plans'), findsOneWidget);
          expect(tester.takeException(), isNull);
        });

        testWidgets('$location: no Upcoming plans without beacons', (
          tester,
        ) async {
          await pump(
            tester,
            location: location,
            flags: {'search'},
            brightness: brightness,
          );
          expect(find.text(upcoming), findsNothing);
          expect(beacons.calls, isEmpty);
          expect(tester.takeException(), isNull);
        });
      }

      testWidgets('Home and Lists have no Upcoming plans', (tester) async {
        for (final location in ['/home', '/lists']) {
          await pump(
            tester,
            location: location,
            flags: {'search', 'beacons'},
            brightness: brightness,
          );
          expect(find.text(upcoming), findsNothing, reason: location);
        }
      });

      testWidgets('/lists: Discover new Lists with lists + list_follows', (
        tester,
      ) async {
        await pump(
          tester,
          location: '/lists',
          flags: {'search', 'lists', 'list_follows'},
          brightness: brightness,
        );
        expect(find.text(discover), findsOneWidget);
        expect(
          find.textContaining('Sunrise crew', findRichText: true),
          findsOneWidget,
        );
        expect(find.text('Follow'), findsOneWidget);
        expect(find.text('See all'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      for (final flags in [
        {'search', 'lists'},
        {'search', 'list_follows'},
      ]) {
        testWidgets('/lists: no Discover new Lists with only $flags', (
          tester,
        ) async {
          await pump(
            tester,
            location: '/lists',
            flags: flags,
            brightness: brightness,
          );
          expect(find.text(discover), findsNothing);
          verifyNever(
            () => lists.discoverLists(
              pageSize: any(named: 'pageSize'),
              pageToken: any(named: 'pageToken'),
            ),
          );
        });
      }

      testWidgets('Discover new Lists is on no other page', (tester) async {
        await pump(
          tester,
          location: '/explore',
          flags: {'search', 'lists', 'list_follows'},
          brightness: brightness,
        );
        expect(find.text(discover), findsNothing);
      });
    });
  }
}
