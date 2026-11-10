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

  for (final selected in [null, 3]) {
    testWidgets('at 1.0 every label is drawn at its full 12 sp, selected '
        '(w800) or not: none is shrunk to fit the 80 dp rail '
        '[selected $selected]', (tester) async {
      await pumpThemed(
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
      );

      for (final d in _five) {
        final fitted = find.ancestor(
          of: find.text(d.label),
          matching: find.byType(FittedBox),
        );
        final text = tester.getSize(find.text(d.label));
        // The FittedBox is as wide as its child: scale 1.
        expect(tester.getSize(fitted).width, text.width, reason: d.label);
        expect(text.height, 16, reason: d.label);
      }
      expectNoOverflow(tester);
    });
  }

  testWidgets('at 1.3 the long label shrinks to the item and never wraps', (
    tester,
  ) async {
    await pumpThemed(
      tester,
      const Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 80,
            child: AppNavRail(
              destinations: _five,
              selectedIndex: 3,
              onDestinationSelected: _ignore,
            ),
          ),
        ],
      ),
      size: const Size(834, 1194),
      textScale: 1.3,
    );

    final label = tester.getRect(find.text('Notifications'));
    expect(find.text('Notifications'), findsOneWidget);
    expect(
      tester
          .getSize(
            find.ancestor(
              of: find.text('Notifications'),
              matching: find.byType(FittedBox),
            ),
          )
          .width,
      lessThanOrEqualTo(78),
    );
    expect(label.height, greaterThan(16));
    expectNoOverflow(tester);
  });
}

void _ignore(int _) {}
