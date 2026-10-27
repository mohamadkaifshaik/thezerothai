import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/app_drawer.dart';
import 'package:dzeroth/core/widgets/app_shell_scope.dart';
import 'package:dzeroth/core/widgets/app_top_bar.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
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

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

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
    Brightness brightness = Brightness.light,
    double textScale = 1,
  }) async {
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        profile: profile,
        enabledFeatures: flags,
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
              path: 'bookmarks',
              builder: (context, state) => const Text('bookmarks page'),
            ),
            GoRoute(
              path: 'settings',
              builder: (context, state) => const Text('settings page'),
            ),
          ],
        ),
      ],
    );
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
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
