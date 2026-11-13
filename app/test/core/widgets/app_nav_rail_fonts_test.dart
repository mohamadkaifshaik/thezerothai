import 'package:dzeroth/core/widgets/app_nav_rail.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

/// With the bundled Inter (the default test font draws every glyph 1 em
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
      _expectUnclipped(tester);
    });
  }

  // Owner decision 2026-11-10: a label may wrap to two lines.
  for (final scale in [1.1, 1.3]) {
    testWidgets('at $scale "Notifications" wraps to two lines at the full '
        'scale and every label shows; the others stay one line', (
      tester,
    ) async {
      await pumpRail(tester, selected: 3, textScale: scale);

      final line = (12 * scale * 1.33).roundToDouble();
      for (final d in _five) {
        final text = find.text(d.label);
        expect(text, findsOneWidget, reason: d.label);
        expect(
          find.ancestor(of: text, matching: find.byType(FittedBox)),
          findsNothing,
          reason: d.label,
        );
        // Inter is wider than the old body font: "Messages" also wraps (two
        // balanced lines) from 1.3.
        final lines =
            d.label == 'Notifications' ||
                (d.label == 'Messages' && scale >= 1.3)
            ? 2
            : 1;
        expect(
          tester.getSize(text).height,
          closeTo(lines * line, 1),
          reason: d.label,
        );
        expect(tester.getSize(text).width, lessThanOrEqualTo(78));
      }
      expectNoOverflow(tester);
      _expectUnclipped(tester);
    });
  }

  // Every scale from 1.00 to 1.30 in 0.01 steps, with Notifications
  // selected (w800) and not (w600, laid out at the shared balanced width):
  // every label shows, none is clipped, none is shrunk.
  for (final selected in [3, 0]) {
    testWidgets('1.00 to 1.30: every label shows in full, Notifications '
        '${selected == 3 ? 'selected' : 'unselected'}', (tester) async {
      for (var step = 0; step <= 30; step++) {
        final scale = 1 + step / 100;
        await pumpRail(tester, selected: selected, textScale: scale);

        final line = 12 * scale * 1.33;
        for (final d in _five) {
          final text = find.text(d.label);
          expect(text, findsOneWidget, reason: '${d.label} x$scale');
          final paragraph = tester.renderObject<RenderParagraph>(text);
          expect(
            paragraph.didExceedMaxLines,
            isFalse,
            reason: '${d.label} x$scale',
          );
          final size = tester.getSize(text);
          expect(
            size.width,
            lessThanOrEqualTo(78),
            reason: '${d.label} x$scale',
          );
          // At most two lines at the user's scale: never shrunk.
          expect(
            size.height,
            lessThanOrEqualTo(2 * line.ceilToDouble() + 1),
            reason: '${d.label} x$scale',
          );
          expect(
            size.height,
            greaterThanOrEqualTo(line.floorToDouble()),
            reason: '${d.label} x$scale',
          );
        }
        expectNoOverflow(tester);
        _expectUnclipped(tester);
      }
    });
  }

  testWidgets('1.00 to 1.30: "Notifications" breaks at the same point '
      'selected and unselected, and its item keeps its height', (tester) async {
    const label = 'Notifications';
    // The index of the first character on the second line (none: length).
    int breakAt() {
      final paragraph = tester.renderObject<RenderParagraph>(find.text(label));
      double top(int i) => paragraph
          .getBoxesForSelection(
            TextSelection(baseOffset: i, extentOffset: i + 1),
          )
          .first
          .top;
      for (var i = 1; i < label.length; i++) {
        if (top(i) > top(0) + 1) return i;
      }
      return label.length;
    }

    double itemHeight() => tester
        .getSize(
          find
              .ancestor(of: find.text(label), matching: find.byType(InkWell))
              .first,
        )
        .height;

    for (var step = 0; step <= 30; step++) {
      final scale = 1 + step / 100;
      await pumpRail(tester, selected: 3, textScale: scale);
      final selected = (breakAt(), itemHeight());
      await pumpRail(tester, selected: 0, textScale: scale);
      expect((breakAt(), itemHeight()), selected, reason: 'x$scale');
      // Balanced from the first wrap on: never "Notification / s".
      if (selected.$1 < label.length) {
        expect(selected.$1, inInclusiveRange(5, 8), reason: 'x$scale');
      }
    }
  });

  testWidgets('above 1.3 the rail is icon-only with tooltips', (tester) async {
    await pumpRail(tester, selected: 3, textScale: 1.31);

    for (final d in _five) {
      expect(find.text(d.label), findsNothing, reason: d.label);
      expect(find.byTooltip(d.label), findsOneWidget, reason: d.label);
    }
    expectNoOverflow(tester);
    _expectUnclipped(tester);
  });
}

void _ignore(int _) {}

/// Every text the rail draws is drawn in full: no label needs more lines
/// than it may show (a clipped label would pass the size and overflow
/// checks).
void _expectUnclipped(WidgetTester tester) {
  final paragraphs = find.descendant(
    of: find.byType(AppNavRail),
    matching: find.byType(RichText),
  );
  for (final element in paragraphs.evaluate()) {
    final paragraph = element.renderObject! as RenderParagraph;
    expect(
      paragraph.didExceedMaxLines,
      isFalse,
      reason: paragraph.text.toPlainText(),
    );
  }
}
