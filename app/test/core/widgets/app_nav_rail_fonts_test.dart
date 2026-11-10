import 'package:dzeroth/core/widgets/app_nav_rail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/app_fonts.dart';
import '../../support/geometry.dart';
import '../../support/theme_harness.dart';

/// The five primaries of ADR-0034.
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
    icon: Icons.track_changes,
    selectedIcon: Icons.adjust,
    label: 'Plans',
  ),
  AppNavDestination(
    icon: Icons.notifications_none,
    selectedIcon: Icons.notifications,
    label: 'Notifications',
  ),
  AppNavDestination(
    icon: Icons.mail_outline,
    selectedIcon: Icons.mail,
    label: 'Messages',
  ),
];

/// With the bundled DM Sans (the default test font draws every glyph 1 em
/// wide, so the label widths are only real here).
void main() {
  setUpAll(loadAppFonts);

  Future<void> pumpRail(
    WidgetTester tester, {
    int? selected,
    double textScale = 1,
  }) => pumpThemed(
    tester,
    Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 80,
          child: AppNavRail(
            destinations: _five,
            selectedIndex: selected,
            onDestinationSelected: _ignore,
          ),
        ),
      ],
    ),
    size: const Size(834, 1194),
    textScale: textScale,
  );

  for (final selected in [null, 3]) {
    testWidgets('at 1.0 every label is drawn at its own 12 sp size, selected '
        '(w800) or not, and fits the item [selected $selected]', (
      tester,
    ) async {
      await pumpRail(tester, selected: selected);

      for (final d in _five) {
        final text = find.text(d.label);
        expect(text, findsOneWidget, reason: d.label);
        // Never scaled to fit: no FittedBox, the 16 dp line of 12 sp.
        expect(
          find.ancestor(of: text, matching: find.byType(FittedBox)),
          findsNothing,
          reason: d.label,
        );
        expect(tester.getSize(text).height, 16, reason: d.label);
        expect(tester.getSize(text).width, lessThanOrEqualTo(78));
      }
      expectNoOverflow(tester);
    });
  }

  testWidgets('at 1.3 "Notifications" no longer fits: icon-only with '
      'tooltips, never a shrunk label', (tester) async {
    await pumpRail(tester, selected: 3, textScale: 1.3);

    for (final d in _five) {
      expect(find.text(d.label), findsNothing, reason: d.label);
      expect(find.byTooltip(d.label), findsOneWidget, reason: d.label);
    }
    expectNoOverflow(tester);
  });
}

void _ignore(int _) {}
