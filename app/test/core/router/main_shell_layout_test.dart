import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/router/main_shell.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/unread_badge_cubit.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/shared/widgets/app_side_column.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

class MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

/// Layout of the shell at phone, tablet and desktop widths: the centred main
/// column, the rail (brand, compose entry), the desktop side column. Behaviour
/// that predates the layout (flag gating, badge, navigation) stays covered by
/// `main_shell_compose_test.dart`.
void main() {
  late MockOnboardingBloc onboardingBloc;

  setUpAll(() => registerFallbackValue(const OnboardingUserSignedOut()));

  setUp(() => onboardingBloc = MockOnboardingBloc());

  final profile = identity.Profile(
    userId: 'u1',
    handle: 'alex',
    displayName: 'Alex Rivera',
  );

  Future<void> pump(
    WidgetTester tester, {
    required double width,
    double height = 900,
    double textScale = 1,
    Set<String> flags = const {'posts', 'notifications'},
    identity.Profile? withProfile,
    String location = '/home',
    UnreadBadgeCubit? badge,
    Brightness brightness = Brightness.dark,
  }) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    whenListen(
      onboardingBloc,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        enabledFeatures: flags,
        profile: withProfile,
      ),
    );
    Widget shell(String loc) => MainShell(
      location: loc,
      child: const SizedBox.expand(key: Key('body'), child: Text('body')),
    );
    final router = GoRouter(
      initialLocation: location,
      routes: [
        GoRoute(path: '/home', builder: (c, s) => shell('/home')),
        GoRoute(path: '/settings', builder: (c, s) => shell('/settings')),
        GoRoute(
          path: '/profile/:handle',
          builder: (c, s) => shell('/profile/${s.pathParameters['handle']}'),
        ),
        GoRoute(path: '/compose', builder: (c, s) => const Text('compose')),
      ],
    );
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<OnboardingBloc>.value(value: onboardingBloc),
          BlocProvider<UnreadBadgeCubit>.value(
            value: badge ?? UnreadBadgeCubit(0),
          ),
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

  double bodyWidth(WidgetTester tester) =>
      tester.getSize(find.byKey(const Key('body'))).width;

  group('main column', () {
    testWidgets('fills the width on a phone', (tester) async {
      await pump(tester, width: 390);
      expect(bodyWidth(tester), 390);
    });

    for (final width in [768.0, 1280.0, 1440.0]) {
      testWidgets('is at most ${AppLayout.mainColumnMaxWidth}dp and centred at '
          '${width.toInt()}dp', (tester) async {
        await pump(tester, width: width, withProfile: profile);
        expect(bodyWidth(tester), AppLayout.mainColumnMaxWidth);
        final rect = tester.getRect(find.byKey(const Key('body')));
        // Centred between the rail (left) and the side column (right, desktop).
        final railRight = tester.getRect(find.byType(NavigationRail)).right;
        final rightEdge = width >= AppBreakpoints.tablet
            ? width - AppLayout.sideColumnWidth
            : width;
        expect(rect.left - railRight, closeTo(rightEdge - rect.right, 1));
      });
    }

    testWidgets('has 1dp borders on both sides from 600dp', (tester) async {
      await pump(tester, width: 768);
      final decorated = find.ancestor(
        of: find.byKey(const Key('body')),
        matching: find.byType(DecoratedBox),
      );
      final border =
          (tester.widget<DecoratedBox>(decorated.first).decoration
                      as BoxDecoration)
                  .border!
              as Border;
      expect(border.left.width, 1);
      expect(border.right.width, 1);
    });
  });

  group('rail', () {
    testWidgets('shows the Dzeroth brand as a header', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester, width: 1280);
      expect(find.text('Dzeroth'), findsOneWidget);
      expect(find.bySemanticsLabel('Dzeroth'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('collapsed rail shows a single D', (tester) async {
      await pump(tester, width: 768);
      expect(find.text('Dzeroth'), findsNothing);
      expect(find.text('D'), findsOneWidget);
    });

    testWidgets('labels are visible from 1200dp only', (tester) async {
      await pump(tester, width: 1200);
      expect(
        tester.widget<NavigationRail>(find.byType(NavigationRail)).extended,
        isTrue,
      );
      await pump(tester, width: 1199);
      expect(
        tester.widget<NavigationRail>(find.byType(NavigationRail)).extended,
        isFalse,
      );
    });

    testWidgets('destination order and labels are unchanged', (tester) async {
      await pump(tester, width: 1280);
      final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(
        [for (final d in rail.destinations) (d.label as Text).data],
        ['Home', 'Notifications', 'Profile', 'Settings'],
      );
    });

    testWidgets('selected index follows the location', (tester) async {
      await pump(tester, width: 1280, location: '/settings');
      expect(
        tester
            .widget<NavigationRail>(find.byType(NavigationRail))
            .selectedIndex,
        3,
      );
      await pump(tester, width: 1280, withProfile: profile);
      expect(
        tester
            .widget<NavigationRail>(find.byType(NavigationRail))
            .selectedIndex,
        0,
      );
    });

    testWidgets('selected index follows the location on a phone', (
      tester,
    ) async {
      await pump(tester, width: 390, location: '/settings');
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        3,
      );
    });

    testWidgets('notification badge still shows on the extended rail', (
      tester,
    ) async {
      final badge = UnreadBadgeCubit(7);
      addTearDown(badge.close);
      await pump(tester, width: 1280, badge: badge);
      expect(find.text('7'), findsWidgets);
    });

    testWidgets('destinations keep 48dp targets', (tester) async {
      await pump(tester, width: 1280);
      final centers = [
        for (final label in ['Home', 'Notifications', 'Profile', 'Settings'])
          tester
              .getCenter(
                find.descendant(
                  of: find.byType(NavigationRail),
                  matching: find.text(label),
                ),
              )
              .dy,
      ];
      for (var i = 1; i < centers.length; i++) {
        expect(
          centers[i] - centers[i - 1],
          greaterThanOrEqualTo(AppSpacing.minTapTarget),
        );
      }
    });
  });

  group('compose entry', () {
    testWidgets('phone: the floating button', (tester) async {
      await pump(tester, width: 390);
      expect(find.byType(FloatingActionButton), findsOneWidget);
      expect(find.byTooltip('New post'), findsOneWidget);
    });

    testWidgets('tablet: an icon button, no floating button', (tester) async {
      await pump(tester, width: 768);
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(find.byTooltip('New post'), findsOneWidget);
      expect(find.text('Post'), findsNothing);
      await tester.tap(find.byTooltip('New post'));
      await tester.pumpAndSettle();
      expect(find.text('compose'), findsOneWidget);
    });

    testWidgets('desktop: a "Post" gradient button', (tester) async {
      await pump(tester, width: 1440);
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(find.text('Post'), findsOneWidget);
      await tester.tap(find.text('Post'));
      await tester.pumpAndSettle();
      expect(find.text('compose'), findsOneWidget);
    });

    for (final width in [390.0, 768.0, 1440.0]) {
      testWidgets('absent with the posts flag off at ${width.toInt()}dp', (
        tester,
      ) async {
        await pump(tester, width: width, flags: const {});
        expect(find.byType(FloatingActionButton), findsNothing);
        expect(find.byTooltip('New post'), findsNothing);
        expect(find.text('Post'), findsNothing);
      });

      testWidgets('absent on Settings at ${width.toInt()}dp', (tester) async {
        await pump(tester, width: width, location: '/settings');
        expect(find.byType(FloatingActionButton), findsNothing);
        expect(find.byTooltip('New post'), findsNothing);
        expect(find.text('Post'), findsNothing);
      });
    }
  });

  group('side column', () {
    testWidgets('absent below 1200dp', (tester) async {
      await pump(tester, width: 1199, withProfile: profile);
      expect(find.byType(AppSideColumn), findsNothing);
      expect(find.text('@alex'), findsNothing);
    });

    for (final width in [1200.0, 1280.0, 1440.0]) {
      testWidgets('present at ${width.toInt()}dp with the profile card and '
          'real links only', (tester) async {
        final handle = tester.ensureSemantics();
        await pump(tester, width: width, withProfile: profile);
        expect(find.byType(AppSideColumn), findsOneWidget);
        expect(find.text('Alex Rivera'), findsOneWidget);
        expect(find.text('@alex'), findsOneWidget);
        expect(
          find.bySemanticsLabel('Your profile, Alex Rivera, @alex'),
          findsOneWidget,
        );
        expect(find.text('Settings'), findsWidgets);
        expect(find.text('Privacy Policy'), findsOneWidget);
        // No placeholder for a feature that has no route.
        for (final text in [
          'Search',
          'Trends',
          'Who to follow',
          'Premium',
          'Terms',
        ]) {
          expect(find.textContaining(text), findsNothing, reason: text);
        }
        expect(find.byType(TextField), findsNothing);
        handle.dispose();
      });
    }

    testWidgets('the profile card opens the own profile', (tester) async {
      await pump(tester, width: 1280, withProfile: profile);
      await tester.tap(find.text('@alex'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<NavigationRail>(find.byType(NavigationRail))
            .selectedIndex,
        2,
      );
    });

    testWidgets('no loaded profile: no card, nothing fetched', (tester) async {
      await pump(tester, width: 1280);
      expect(find.byType(AppSideColumn), findsOneWidget);
      expect(find.textContaining('@'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      verifyNever(() => onboardingBloc.add(any()));
    });

    testWidgets('quick link Settings navigates to /settings', (tester) async {
      await pump(tester, width: 1280, withProfile: profile);
      final link = find.descendant(
        of: find.byType(AppSideColumn),
        matching: find.text('Settings'),
      );
      await tester.tap(link);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<NavigationRail>(find.byType(NavigationRail))
            .selectedIndex,
        3,
      );
    });
  });

  group('no overflow', () {
    for (final width in [390.0, 768.0, 1280.0, 1440.0]) {
      for (final brightness in Brightness.values) {
        testWidgets('${width.toInt()}dp, ${brightness.name}, text scale 2', (
          tester,
        ) async {
          await pump(
            tester,
            width: width,
            textScale: 2,
            withProfile: profile,
            brightness: brightness,
          );
          expect(tester.takeException(), isNull);
        });
      }
    }
  });
}
