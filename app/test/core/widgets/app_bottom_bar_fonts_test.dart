import 'package:dzeroth/core/widgets/app_bottom_bar.dart';
import 'package:dzeroth/core/widgets/app_nav_destination.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/app_fonts.dart';
import '../../support/geometry.dart';
import '../../support/theme_harness.dart';

/// The five primaries of ADR-0034 with their bar labels.
const _five = [
  AppNavDestination(
    icon: Icons.home_outlined,
    selectedIcon: Icons.home,
    label: 'Home',
  ),
  AppNavDestination(
    icon: Icons.search,
    selectedIcon: Icons.manage_search,
    label: 'Explore',
  ),
  AppNavDestination(
    icon: Icons.event_outlined,
    selectedIcon: Icons.event,
    label: 'Plans',
  ),
  AppNavDestination(
    icon: Icons.notifications_none,
    selectedIcon: Icons.notifications,
    label: 'Notifications',
    barLabel: 'Alerts',
  ),
  AppNavDestination(
    icon: Icons.mail_outline,
    selectedIcon: Icons.mail,
    label: 'Messages',
  ),
];

Future<void> _pump(
  WidgetTester tester, {
  required double width,
  required double textScale,
  int selected = 4,
  Brightness brightness = Brightness.light,
}) => pumpThemed(
  tester,
  Align(
    alignment: Alignment.bottomCenter,
    child: AppFloatingBottomBar(
      destinations: _five,
      selectedIndex: selected,
      onSelected: (_) {},
    ),
  ),
  size: Size(width, 800),
  textScale: textScale,
  brightness: brightness,
);

/// The label / icon-only switch with the bundled fonts (the other bar tests
/// use the test font, whose glyphs are far wider). Kept in its own file: a
/// loaded font stays loaded for the rest of the file.
void main() {
  setUpAll(loadAppFonts);

  testWidgets('360dp x1.0: all five labels fit, Messages selected (bold) '
      'included', (tester) async {
    await _pump(tester, width: 360, textScale: 1);

    for (final label in ['Home', 'Explore', 'Plans', 'Alerts', 'Messages']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('Notifications'), findsNothing);
    expectNoOverflow(tester);
  });

  testWidgets('320dp x1.0: Messages no longer fits its 52.8dp cell, so the '
      'bar is icon-only', (tester) async {
    await _pump(tester, width: 320, textScale: 1);

    expect(find.text('Messages'), findsNothing);
    expect(find.text('Home'), findsNothing);
    expect(find.byTooltip('Messages'), findsOneWidget);
    expectNoOverflow(tester);
  });

  testWidgets('360dp x1.3: the scaled labels do not all fit, so the bar is '
      'icon-only', (tester) async {
    await _pump(tester, width: 360, textScale: 1.3);

    expect(find.text('Messages'), findsNothing);
    expect(find.text('Home'), findsNothing);
    expect(find.byTooltip('Messages'), findsOneWidget);
    expectNoOverflow(tester);
  });

  testWidgets('599dp x1.3: with room, the labels stay', (tester) async {
    await _pump(tester, width: 599, textScale: 1.3);

    for (final label in ['Home', 'Explore', 'Plans', 'Alerts', 'Messages']) {
      expect(find.text(label), findsOneWidget);
    }
    expectNoOverflow(tester);
  });

  testWidgets('360dp x2.0: icon-only', (tester) async {
    await _pump(tester, width: 360, textScale: 2);

    expect(find.text('Messages'), findsNothing);
    expect(find.byTooltip('Notifications'), findsOneWidget);
    expectNoOverflow(tester);
  });

  // Opt-in goldens (`RUN_GOLDENS=1`, baselines from Linux CI only; no PNG is
  // committed from Windows): the bar at 360 dp, labelled at 1.0 and
  // icon-only at 2.0, light and dark. Without the variable only the overflow
  // check runs.
  forEachThemeAndWidth(
    'golden',
    (tester, env) async {
      await _pump(
        tester,
        width: env.size.width,
        textScale: env.textScale,
        brightness: env.brightness,
        selected: 0,
      );
      expectNoOverflow(tester);
      await expectGolden(
        tester,
        find.byType(AppFloatingBottomBar),
        'floating_bar',
        env,
      );
    },
    widths: const [360],
    textScales: kRedesignTextScales,
  );
}
