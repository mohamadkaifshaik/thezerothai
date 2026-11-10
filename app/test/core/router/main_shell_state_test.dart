import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/router/main_shell.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/app_nav_rail.dart';
import 'package:dzeroth/core/widgets/context_pane.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/messages/presentation/bloc/messages_badge_cubit.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/unread_badge_cubit.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockGraph extends Mock implements GraphRepository {}

/// A page-scoped cubit, created once per mount of the page.
class _ProbeCubit extends Cubit<int> {
  _ProbeCubit() : super(0);
}

/// Tablet plan section 5.2, the T1 proof: a page of the `ShellRoute` keeps its
/// state (scroll offset, a `TextField` value, its page-scoped cubit) when the
/// window crosses a layout boundary, because go_router gives the shell's
/// `Navigator` a `GlobalKey` and `ResponsiveScaffold` re-parents it instead of
/// rebuilding it (fact F4). Run in every chrome the shell can draw: legacy
/// (`ui_shell` off), the redesign without the tablet layout, and the tablet
/// layout (`ui_shell` + `ui_tablet`), whose band B also adds the context
/// pane (T3).
void main() {
  late _MockOnboardingBloc onboarding;
  late _MockAuthBloc auth;

  setUp(() {
    onboarding = _MockOnboardingBloc();
    auth = _MockAuthBloc();
    whenListen(
      auth,
      const Stream<AuthState>.empty(),
      initialState: const AuthState(status: AuthStatus.authenticated),
    );
  });

  const modes = <String, Set<String>>{
    'ui_shell off': {'posts'},
    'ui_shell on, ui_tablet off': {'posts', kFeatureUiShell},
    'ui_shell + ui_tablet': {'posts', kFeatureUiShell, kFeatureUiTablet},
  };

  // Each pair straddles one boundary: phone / tablet, band A / band B,
  // tablet / desktop.
  const crossings = <(double, double)>[
    (599, 600),
    (AppBreakpoints.expanded - 1, AppBreakpoints.expanded),
    (AppBreakpoints.tablet - 1, AppBreakpoints.tablet),
  ];

  for (final MapEntry(key: mode, value: flags) in modes.entries) {
    final tablet = flags.containsAll({kFeatureUiShell, kFeatureUiTablet});
    for (final (below, above) in crossings) {
      testWidgets('$mode: a shell page keeps its scroll offset, field text '
          'and cubit across ${below.toInt()} <-> ${above.toInt()} dp', (
        tester,
      ) async {
        whenListen(
          onboarding,
          const Stream<OnboardingState>.empty(),
          initialState: OnboardingState(
            status: OnboardingStatus.ready,
            enabledFeatures: flags,
            profile: identity.Profile(
              userId: 'u-alice',
              handle: 'alice',
              displayName: 'Alice A',
            ),
          ),
        );
        var creates = 0;
        final router = GoRouter(
          initialLocation: '/home',
          routes: [
            ShellRoute(
              builder: (context, state, child) =>
                  MainShell(location: state.matchedLocation, child: child),
              routes: [
                GoRoute(
                  path: '/home',
                  builder: (context, state) => BlocProvider(
                    create: (_) {
                      creates++;
                      return _ProbeCubit();
                    },
                    child: Scaffold(
                      body: Column(
                        children: [
                          const TextField(key: Key('field')),
                          Expanded(
                            child: ListView.builder(
                              key: const Key('list'),
                              itemExtent: 60,
                              itemCount: 100,
                              itemBuilder: (context, i) => Text('row $i'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        );
        addTearDown(router.dispose);
        final unread = UnreadBadgeCubit(0);
        addTearDown(unread.close);
        final messages = MessagesBadgeCubit();
        addTearDown(messages.close);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(below, 900);
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MultiBlocProvider(
            providers: [
              BlocProvider<OnboardingBloc>.value(value: onboarding),
              BlocProvider<AuthBloc>.value(value: auth),
              BlocProvider<UnreadBadgeCubit>.value(value: unread),
              BlocProvider<MessagesBadgeCubit>.value(value: messages),
            ],
            child: RepositoryProvider<GraphRepository>.value(
              value: _MockGraph(),
              child: MaterialApp.router(
                theme: buildAppTheme(brightness: Brightness.light),
                routerConfig: router,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.enterText(find.byKey(const Key('field')), 'draft text');
        final scrollable = find.descendant(
          of: find.byKey(const Key('list')),
          matching: find.byType(Scrollable),
        );
        tester.state<ScrollableState>(scrollable).position.jumpTo(600);
        await tester.pump();
        final fieldState = tester.state(find.byType(EditableText));
        final scrollState = tester.state<ScrollableState>(scrollable);
        final cubit = BlocProvider.of<_ProbeCubit>(
          tester.element(find.byKey(const Key('field'))),
        );
        expect(creates, 1);

        for (final width in [above, below, above]) {
          tester.view.physicalSize = Size(width, 900);
          await tester.pumpAndSettle();

          final reason = '$mode at ${width.toInt()} dp';
          // The chrome really changed shape around the page.
          final tabletBand =
              width >= AppBreakpoints.mobile && width < AppBreakpoints.tablet;
          expect(
            find.byType(AppNavRail),
            tablet && tabletBand ? findsOneWidget : findsNothing,
            reason: reason,
          );
          expect(
            find.byType(NavigationRail),
            width >= AppBreakpoints.mobile && !(tablet && tabletBand)
                ? findsOneWidget
                : findsNothing,
            reason: reason,
          );
          // Band B adds the context pane beside the page (T3); the page
          // still keeps its state.
          expect(
            find.byType(ContextPane),
            tablet && tabletBand && width >= AppBreakpoints.expanded
                ? findsOneWidget
                : findsNothing,
            reason: reason,
          );
          expect(
            tester.state(find.byType(EditableText)),
            same(fieldState),
            reason: reason,
          );
          expect(find.text('draft text'), findsOneWidget, reason: reason);
          expect(
            tester.state<ScrollableState>(scrollable),
            same(scrollState),
            reason: reason,
          );
          expect(scrollState.position.pixels, 600, reason: reason);
          expect(
            BlocProvider.of<_ProbeCubit>(
              tester.element(find.byKey(const Key('field'))),
            ),
            same(cubit),
            reason: reason,
          );
          expect(creates, 1, reason: reason);
          expect(tester.takeException(), isNull, reason: reason);
        }
      });
    }
  }
}
