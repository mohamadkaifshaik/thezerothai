import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/app_drawer.dart';
import 'package:dzeroth/core/widgets/app_shell_scope.dart';
import 'package:dzeroth/core/widgets/app_top_bar.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/shared/widgets/app_avatar.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/geometry.dart';
import '../../support/suggestions_fixtures.dart' show suggestedUser;
import '../../support/theme_harness.dart';

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockGraph extends Mock implements GraphRepository {}

Widget _withGraph(GraphRepository? repository, Widget child) =>
    repository == null
    ? child
    : RepositoryProvider<GraphRepository>.value(
        value: repository,
        child: child,
      );

final _alice = identity.Profile(
  userId: 'u-alice',
  handle: 'alice',
  displayName: 'Alice A',
  followingCount: Int64(341),
  followersCount: Int64(12),
);

void main() {
  late _MockOnboardingBloc onboarding;
  late _MockAuthBloc auth;
  late GoRouter router;
  Object? lastExtra;

  setUpAll(() => registerFallbackValue(const AuthSignOutRequested()));

  setUp(() {
    onboarding = _MockOnboardingBloc();
    auth = _MockAuthBloc();
    lastExtra = null;
    whenListen(
      auth,
      const Stream<AuthState>.empty(),
      initialState: const AuthState(status: AuthStatus.authenticated),
    );
  });

  Future<void> pump(
    WidgetTester tester, {
    identity.Profile? profile,
    Set<String> flags = const {},
    Size size = const Size(360, 800),
    int pending = 0,
    Brightness brightness = Brightness.light,
    double textScale = 1,
    GraphRepository? graphRepository,
  }) async {
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        profile: profile,
        enabledFeatures: flags,
        pendingFollowRequestCount: pending,
      ),
    );
    router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const _Home(),
          routes: [
            GoRoute(
              path: 'profile/:handle',
              builder: (context, state) =>
                  Text('profile ${state.pathParameters['handle']}'),
              routes: [
                GoRoute(
                  path: 'following',
                  builder: (context, state) {
                    lastExtra = state.extra;
                    return const Text('following list');
                  },
                ),
                GoRoute(
                  path: 'followers',
                  builder: (context, state) {
                    lastExtra = state.extra;
                    return const Text('followers list');
                  },
                ),
              ],
            ),
            GoRoute(
              path: 'follow-requests',
              builder: (context, state) => const Text('requests page'),
            ),
            GoRoute(
              path: 'bookmarks',
              builder: (context, state) => const Text('bookmarks page'),
            ),
            GoRoute(
              path: 'lists',
              builder: (context, state) => const Text('lists page'),
            ),
            GoRoute(
              path: 'settings',
              builder: (context, state) => const Text('settings page'),
            ),
          ],
        ),
      ],
    );
    // The entry also reads the 10-minute backoff (W3-34b): not backed off
    // unless a test passes its own repository.
    final graphRepo = graphRepository ?? _MockGraph();
    if (graphRepository == null) {
      when(() => graphRepo.followRequestsUnavailable).thenReturn(false);
    }
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _withGraph(
        graphRepo,
        MultiBlocProvider(
          providers: [
            BlocProvider<OnboardingBloc>.value(value: onboarding),
            BlocProvider<AuthBloc>.value(value: auth),
          ],
          child: MaterialApp.router(
            theme: buildAppTheme(brightness: brightness),
            routerConfig: router,
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

  Future<void> openDrawer(WidgetTester tester) async {
    await tester.tap(find.bySemanticsLabel('Account menu'));
    await tester.pumpAndSettle();
  }

  group('AppDrawer', () {
    testWidgets('opens from the avatar button and shows the account block', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(tester, profile: _alice);
      expect(find.byType(AppDrawer), findsNothing);

      await openDrawer(tester);

      expect(find.byType(AppDrawer), findsOneWidget);
      expect(find.text('Alice A'), findsOneWidget);
      expect(find.text('@alice'), findsOneWidget);
      expect(find.text('341 Following', findRichText: true), findsOneWidget);
      expect(find.text('12 Followers', findRichText: true), findsOneWidget);
      handle.dispose();
    });

    testWidgets('is 277dp wide and the rows are 56dp tall', (tester) async {
      await pump(tester, profile: _alice);
      await openDrawer(tester);

      expectSize(tester, find.byType(Drawer), width: AppSize.drawerWidth);
      for (final label in ['Profile', 'Settings', 'Sign out']) {
        final row = find.ancestor(
          of: find.text(label),
          matching: find.byType(ConstrainedBox),
        );
        final height = row
            .evaluate()
            .map((e) => (e.renderObject! as RenderBox).size.height)
            .reduce((a, b) => a > b ? a : b);
        expect(height, greaterThanOrEqualTo(AppSize.drawerRow), reason: label);
      }
    });

    group('Follow requests row (W3-34)', () {
      final protectedAlice = _alice.deepCopy()..isPrivate = true;

      testWidgets('absent for a public account with nothing pending', (
        tester,
      ) async {
        await pump(tester, profile: _alice, flags: {'graph'});
        await openDrawer(tester);
        expect(find.text('Follow requests'), findsNothing);
      });

      testWidgets('shown to a protected caller even with every flag off '
          'but graph, with no badge at 0', (tester) async {
        await pump(tester, profile: protectedAlice, flags: {'graph'});
        await openDrawer(tester);
        expect(find.text('Follow requests'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('drawer-follow-requests')),
          findsOneWidget,
        );
        expect(find.text('0'), findsNothing);
      });

      testWidgets('absent while graph is off', (tester) async {
        await pump(tester, profile: protectedAlice, pending: 3);
        await openDrawer(tester);
        expect(find.text('Follow requests'), findsNothing);
      });

      testWidgets('shows the pending count, says it, opens the screen', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        await pump(
          tester,
          profile: protectedAlice,
          flags: {'graph'},
          pending: 7,
        );
        await openDrawer(tester);
        expect(find.text('7'), findsOneWidget);
        expect(
          find.bySemanticsLabel('Follow requests, 7 pending'),
          findsOneWidget,
        );
        final y = [
          for (final l in ['Profile', 'Follow requests', 'Settings'])
            tester.getTopLeft(find.text(l)).dy,
        ];
        expect(y[0], lessThan(y[1]));
        expect(y[1], lessThan(y[2]));

        await tester.tap(find.text('Follow requests'));
        await tester.pumpAndSettle();
        expect(find.text('requests page'), findsOneWidget);
        expect(find.byType(AppDrawer), findsNothing);
        semantics.dispose();
      });

      testWidgets('the cap shows 1000+ and is spoken as 1000 or more', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        await pump(
          tester,
          profile: protectedAlice,
          flags: {'graph'},
          pending: 1000,
        );
        await openDrawer(tester);
        expect(find.text('1000+'), findsOneWidget);
        expect(
          find.bySemanticsLabel('Follow requests, 1000 or more pending'),
          findsOneWidget,
        );
        expect(followRequestBadgeText(999), '999');
        semantics.dispose();
      });

      // W3-35c: the badge row in every cell of the W3-21 matrix.
      for (final pending in [7, 1000]) {
        forEachThemeAndWidth(
          'badge row with $pending pending fits the drawer and keeps 56dp',
          (tester, env) async {
            await pump(
              tester,
              profile: protectedAlice,
              flags: {'graph'},
              pending: pending,
              size: env.size,
              brightness: env.brightness,
              textScale: env.textScale,
            );
            await openDrawer(tester);
            expectNoOverflow(tester);

            final drawer = tester.getRect(find.byType(Drawer));
            final row = find.byKey(const ValueKey('drawer-follow-requests'));
            expect(
              tester.getSize(row).height,
              greaterThanOrEqualTo(AppSize.drawerRow - 0.5),
              reason: 'row height',
            );
            final label = find.text('Follow requests');
            final badge = find.text(followRequestBadgeText(pending));
            expect(badge, findsOneWidget);
            for (final part in [label, badge]) {
              final rect = tester.getRect(part);
              expect(rect.left, greaterThanOrEqualTo(drawer.left - 0.5));
              expect(rect.right, lessThanOrEqualTo(drawer.right + 0.5));
            }
            expect(
              tester.getRect(label).overlaps(tester.getRect(badge)),
              isFalse,
              reason: 'badge over the label',
            );
          },
          // The drawer is a phone surface: below 600 dp only (wide layouts
          // use the rail and the account chip, see D-2 in the W3-35c report).
          widths: const [360],
          textScales: kMatrixTextScalesLarge,
        );
      }

      testWidgets('the badge is the GetMe count and nothing else: a long '
          'list is never fetched to count it', (tester) async {
        final graphRepo = _MockGraph();
        when(
          () => graphRepo.listFollowRequests(
            pageSize: any(named: 'pageSize'),
            pageToken: any(named: 'pageToken'),
          ),
        ).thenAnswer(
          (_) async => GraphPage(
            items: [for (var i = 1; i <= 20; i++) suggestedUser(i)],
            nextPageToken: 'more',
          ),
        );
        when(() => graphRepo.followRequestsUnavailable).thenReturn(false);
        await pump(
          tester,
          profile: protectedAlice,
          flags: {'graph'},
          pending: 3,
          graphRepository: graphRepo,
        );
        await openDrawer(tester);
        expect(find.text('3'), findsOneWidget);
        expect(find.text('20'), findsNothing);
        verifyNever(
          () => graphRepo.listFollowRequests(
            pageSize: any(named: 'pageSize'),
            pageToken: any(named: 'pageToken'),
          ),
        );
      });

      // D-3 (low): after ListFollowRequests answers FEATURE_DISABLED or
      // UNIMPLEMENTED the repository is "unavailable" for 10 minutes
      // (`followRequestsUnavailable`), but nothing outside it reads that, so
      // a protected caller keeps the drawer entry and the tap lands on "not
      // available". Plan W3-34: "FEATURE_DISABLED hides it with a 10-minute
      // backoff". Flip to false when the owner resolves it.
      const d3Open = false;
      testWidgets(
        'D-3: while the repository is backed off the entry is hidden',
        (tester) async {
          final graphRepo = _MockGraph();
          when(() => graphRepo.followRequestsUnavailable).thenReturn(true);
          await pump(
            tester,
            profile: protectedAlice,
            flags: {'graph'},
            pending: 3,
            graphRepository: graphRepo,
          );
          await openDrawer(tester);
          expect(find.text('Follow requests'), findsNothing);
        },
        skip: d3Open,
      );

      // D-1 (low): the drawer shows the entry for any count above 0, while
      // the router redirects a public caller without `private_accounts` Home
      // (app_drawer.dart:45-47 vs app_router.dart:495-498). The plan's W3-34
      // states both rules. Flip to false when the owner resolves it.
      const d1Open = false;
      testWidgets('D-1: a public account with a stale count and '
          'private_accounts off has no entry that the router sends Home', (
        tester,
      ) async {
        await pump(tester, profile: _alice, flags: {'graph'}, pending: 3);
        await openDrawer(tester);
        expect(find.text('Follow requests'), findsNothing);
      }, skip: d1Open);
      testWidgets('fits and keeps a 56dp row at 360dp x2.0 in dark', (
        tester,
      ) async {
        await pump(
          tester,
          profile: protectedAlice,
          flags: {'graph'},
          pending: 1000,
          brightness: Brightness.dark,
          textScale: 2,
        );
        await openDrawer(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('1000+'), findsOneWidget);
      });
    });

    group('Bookmarks row (W2-7)', () {
      testWidgets('needs both bookmarks and posts: absent otherwise', (
        tester,
      ) async {
        for (final flags in <Set<String>>[
          const {},
          const {'bookmarks'},
          const {'posts'},
          // W3-18/W3-21: `likes_list` opens the Likes tab by link, but the
          // History entry itself still needs `bookmarks` and `posts`.
          const {'likes_list'},
          const {'posts', 'likes_list'},
          const {'bookmarks', 'likes_list'},
        ]) {
          await pump(tester, profile: _alice, flags: flags);
          await openDrawer(tester);
          expect(find.text('History'), findsNothing, reason: '$flags');
          expect(find.text('Settings'), findsOneWidget);
        }
      });

      testWidgets('sits between Profile and Settings, is 56dp, closes the '
          'drawer and opens /bookmarks', (tester) async {
        await pump(tester, profile: _alice, flags: {'posts', 'bookmarks'});
        await openDrawer(tester);

        final y = [
          for (final l in ['Profile', 'History', 'Settings'])
            tester.getTopLeft(find.text(l)).dy,
        ];
        expect(y[0], lessThan(y[1]));
        expect(y[1], lessThan(y[2]));
        expect(find.byIcon(Icons.bookmark_border), findsOneWidget);

        await tester.tap(find.text('History'));
        await tester.pumpAndSettle();

        expect(find.byType(AppDrawer), findsNothing);
        expect(find.text('bookmarks page'), findsOneWidget);
      });
    });

    group('Lists row (W5-11)', () {
      testWidgets('needs the lists flag: absent otherwise', (tester) async {
        for (final flags in <Set<String>>[
          const {},
          const {'posts', 'bookmarks'},
        ]) {
          await pump(tester, profile: _alice, flags: flags);
          await openDrawer(tester);
          expect(find.text('Lists'), findsNothing, reason: '$flags');
        }
      });

      testWidgets('with lists: sits before Settings, closes the drawer and '
          'opens /lists', (tester) async {
        await pump(tester, profile: _alice, flags: {'lists'});
        await openDrawer(tester);

        expect(
          tester.getTopLeft(find.text('Lists')).dy,
          lessThan(tester.getTopLeft(find.text('Settings')).dy),
        );
        await tester.tap(find.text('Lists'));
        await tester.pumpAndSettle();

        expect(find.byType(AppDrawer), findsNothing);
        expect(find.text('lists page'), findsOneWidget);
      });
    });

    testWidgets('never exceeds 85 % of a very narrow screen', (tester) async {
      await pump(tester, profile: _alice, size: const Size(300, 700));
      await openDrawer(tester);

      expectSize(tester, find.byType(Drawer), width: 255);
    });

    testWidgets('labels are bold 20dp and the icons are 24dp', (tester) async {
      await pump(tester, profile: _alice);
      await openDrawer(tester);

      final style = tester.widget<Text>(find.text('Profile')).style!;
      expect(style.fontSize, 20);
      expect(style.fontWeight, FontWeight.w700);
      // (person_outline is also the avatar fallback; settings_outlined is
      // unique to a row.)
      expect(
        tester.widget<Icon>(find.byIcon(Icons.settings_outlined)).size,
        AppIconSize.lg,
      );
    });

    testWidgets('Profile closes the drawer and opens /profile/<handle>', (
      tester,
    ) async {
      await pump(tester, profile: _alice);
      await openDrawer(tester);

      await tester.tap(find.text('Profile'));
      await tester.pumpAndSettle();

      expect(find.text('profile alice'), findsOneWidget);
      expect(find.byType(AppDrawer), findsNothing);
    });

    testWidgets('Settings closes the drawer and opens /settings', (
      tester,
    ) async {
      await pump(tester, profile: _alice);
      await openDrawer(tester);

      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();

      expect(find.text('settings page'), findsOneWidget);
      expect(find.byType(AppDrawer), findsNothing);
    });

    testWidgets('Sign out closes the drawer and dispatches the sign-out '
        'event', (tester) async {
      await pump(tester, profile: _alice);
      await openDrawer(tester);

      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();

      verify(() => auth.add(const AuthSignOutRequested())).called(1);
      expect(find.byType(AppDrawer), findsNothing);
    });

    testWidgets('the counts open the lists of the profile with its user id', (
      tester,
    ) async {
      await pump(tester, profile: _alice);
      await openDrawer(tester);
      await tester.tap(find.text('341 Following', findRichText: true));
      await tester.pumpAndSettle();
      expect(find.text('following list'), findsOneWidget);
      expect(lastExtra, 'u-alice');

      router.pop();
      await tester.pumpAndSettle();
      await openDrawer(tester);
      await tester.tap(find.text('12 Followers', findRichText: true));
      await tester.pumpAndSettle();
      expect(find.text('followers list'), findsOneWidget);
      expect(lastExtra, 'u-alice');
    });

    testWidgets('without a profile there is no account block and no Profile '
        'row, only Settings and Sign out', (tester) async {
      await pump(tester);
      await openDrawer(tester);

      expect(find.text('Profile'), findsNothing);
      expect(find.text('Following', findRichText: true), findsNothing);
      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('Sign out'), findsOneWidget);
    });

    testWidgets('a profile without a display name shows the handle as the '
        'name', (tester) async {
      await pump(tester, profile: identity.Profile(handle: 'bob'));
      await openDrawer(tester);

      expect(find.text('@bob'), findsNWidgets(2));
    });

    testWidgets('closes on a tap on the scrim', (tester) async {
      await pump(tester, profile: _alice);
      await openDrawer(tester);

      await tester.tapAt(const Offset(350, 400));
      await tester.pumpAndSettle();

      expect(find.byType(AppDrawer), findsNothing);
    });

    testWidgets('closes on the system back action', (tester) async {
      await pump(tester, profile: _alice);
      await openDrawer(tester);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.byType(AppDrawer), findsNothing);
      // Back closed the drawer only; the page is still the home page.
      expect(find.byType(_Home), findsOneWidget);
    });

    testWidgets('closes on Escape', (tester) async {
      await pump(tester, profile: _alice);
      await openDrawer(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.byType(AppDrawer), findsNothing);
    });

    testWidgets('the scrim is the theme scrim', (tester) async {
      await pump(tester, profile: _alice, brightness: Brightness.dark);
      await openDrawer(tester);

      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is ColoredBox && widget.color == AppColors.dark.scrim,
        ),
        findsOneWidget,
      );
    });

    testWidgets('focus returns to the avatar button after the drawer closes', (
      tester,
    ) async {
      await pump(tester, profile: _alice);
      await openDrawer(tester);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      // The focused node is the avatar button (an ancestor of the avatar).
      final focused = FocusManager.instance.primaryFocus!.context!;
      var onAvatarButton = false;
      tester.element(find.byType(AppAvatar)).visitAncestorElements((element) {
        if (element == focused) {
          onAvatarButton = true;
          return false;
        }
        return true;
      });
      expect(onAvatarButton, isTrue);
      expect(find.byType(AppDrawer), findsNothing);
    });

    for (final dark in [false, true]) {
      for (final scale in [1.0, 1.3, 2.0]) {
        testWidgets('does not overflow (dark: $dark, text scale $scale)', (
          tester,
        ) async {
          await pump(
            tester,
            profile: _alice,
            brightness: dark ? Brightness.dark : Brightness.light,
            textScale: scale,
            size: const Size(320, 640),
          );
          await openDrawer(tester);

          expectNoOverflow(tester);
        });
      }
    }
  });
}

/// A page with the top bar (whose avatar button opens the drawer) inside a
/// shell scope and a Scaffold that owns the drawer, like the real shell.
class _Home extends StatefulWidget {
  const _Home();

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  final _key = GlobalKey<ScaffoldState>();

  @override
  Widget build(BuildContext context) {
    return AppShellScope(
      openDrawer: () => _key.currentState!.openDrawer(),
      child: Scaffold(
        key: _key,
        drawer: const AppDrawer(),
        appBar: const AppTopBar(title: 'Home'),
        body: const SizedBox.expand(),
      ),
    );
  }
}
