import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/responsive_scaffold.dart';
import 'package:dzeroth/core/widgets/tablet_modal.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

/// Dialogs, sheets and snack bars on the tablet layout (tablet plan section
/// 5.4): a window of a given size and safe area, the `ui_shell` /
/// `ui_tablet` flags from a mocked `OnboardingBloc` above the app (so routes
/// on the root navigator see them too), and a trigger either on a shell page
/// (inside `ResponsiveScaffold`, with the rail) or on a full-screen route.

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

/// Both flags of the tablet layout.
const kTabletFlags = {kFeatureUiShell, kFeatureUiTablet};

/// Key of the trigger's wrapper on the page.
const kTabletTriggerKey = Key('tablet-modal-trigger');

/// The rail destinations of the harness shell; selecting one records it.
final tabletHarnessSelections = <int>[];

/// Pumps [trigger] on a page of a [width] x [height] window with the
/// safe-area [padding], under [flags]. [inShell] puts it in the shell body
/// (the tablet shell when both flags are on, the legacy chrome otherwise);
/// off, it is a full-screen route with no rail. [wrap] adds providers above
/// the app (repositories, cubits).
Future<void> pumpTabletModalHost(
  WidgetTester tester, {
  required WidgetBuilder trigger,
  double width = 834,
  double height = 1194,
  Set<String> flags = kTabletFlags,
  bool inShell = true,
  EdgeInsets padding = EdgeInsets.zero,
  EdgeInsets viewInsets = EdgeInsets.zero,
  TextDirection textDirection = TextDirection.ltr,
  Brightness brightness = Brightness.light,
  double textScale = 1,
  Widget Function(Widget app)? wrap,
}) async {
  tabletHarnessSelections.clear();
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, height);
  tester.view.padding = FakeViewPadding(
    left: padding.left,
    top: padding.top,
    right: padding.right,
    bottom: padding.bottom,
  );
  tester.view.viewPadding = FakeViewPadding(
    left: padding.left,
    top: padding.top,
    right: padding.right,
    bottom: padding.bottom,
  );
  tester.view.viewInsets = FakeViewPadding(bottom: viewInsets.bottom);
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  final onboarding = _MockOnboardingBloc();
  whenListen(
    onboarding,
    const Stream<OnboardingState>.empty(),
    initialState: OnboardingState(
      status: OnboardingStatus.ready,
      enabledFeatures: flags,
      profile: identity.Profile(userId: 'u1', handle: 'alice'),
    ),
  );

  final page = Scaffold(
    body: Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(top: 200),
        child: KeyedSubtree(
          key: kTabletTriggerKey,
          child: Builder(builder: trigger),
        ),
      ),
    ),
  );
  final tablet =
      flags.contains(kFeatureUiShell) && flags.contains(kFeatureUiTablet);
  final home = inShell
      ? ResponsiveScaffold(
          selectedIndex: 0,
          onDestinationSelected: tabletHarnessSelections.add,
          layout: tablet ? ShellLayout.tablet : ShellLayout.legacy,
          redesignedRail: true,
          floatingBar: true,
          onCompose: () {},
          destinations: const [
            AppNavDestination(
              icon: Icons.home_outlined,
              selectedIcon: Icons.home,
              label: 'Home',
            ),
            AppNavDestination(
              icon: Icons.search,
              selectedIcon: Icons.search,
              label: 'Explore',
            ),
            AppNavDestination(
              icon: Icons.event_outlined,
              selectedIcon: Icons.event,
              label: 'Plans',
            ),
          ],
          body: page,
        )
      : page;
  final app = BlocProvider<OnboardingBloc>.value(
    value: onboarding,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(brightness: brightness),
      // As in `App`: full-screen routes' snack bars on the tablet layout.
      builder: (context, child) => Directionality(
        textDirection: textDirection,
        child: TabletRouteSnackBars(child: child!),
      ),
      home: home,
    ),
  );
  await tester.pumpWidget(wrap == null ? app : wrap(app));
  await tester.pumpAndSettle();
}

/// The content area of the tablet shell for a window (`C = W - 80 - insets`,
/// the rail on the leading side).
Rect tabletContentRect(
  Size window, {
  EdgeInsets padding = EdgeInsets.zero,
  TextDirection textDirection = TextDirection.ltr,
}) {
  final ltr = textDirection == TextDirection.ltr;
  final leading = ltr ? padding.left : padding.right;
  final trailing = ltr ? padding.right : padding.left;
  final rail = AppSize.railCompact + leading;
  final width = window.width - rail - trailing;
  return Rect.fromLTWH(ltr ? rail : trailing, 0, width, window.height);
}

/// The visible box of the open dialog (its `Material`, inside the inset
/// padding).
Rect openDialogRect(WidgetTester tester) => tester.getRect(
  find
      .descendant(of: find.byType(Dialog), matching: find.byType(Material))
      .first,
);
