import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/shell_geometry.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/theme_harness.dart';

void main() {
  group('ShellBand', () {
    test('the bands switch at 600, 840 and 1200', () {
      expect(
        {for (final w in kBoundaryWidths) w: ShellBand.of(w)},
        {
          599.0: ShellBand.phone,
          600.0: ShellBand.medium,
          839.0: ShellBand.medium,
          840.0: ShellBand.expanded,
          1199.0: ShellBand.expanded,
          1200.0: ShellBand.desktop,
        },
      );
      expect(AppBreakpoints.expanded, 840);
      expect(ShellBand.medium.isTablet, isTrue);
      expect(ShellBand.expanded.isTablet, isTrue);
      expect(ShellBand.phone.isTablet, isFalse);
      expect(ShellBand.desktop.isTablet, isFalse);
    });
  });

  group('ShellGeometry.contextPaneWidthFor (band B, code P, T3)', () {
    // Plan section 3: pane = clamp(C - 1 - 680, 320, 440), primary = the
    // rest after the 1 dp hairline. W -> C is W - 80 with no insets.
    final table = <double, (double, double)>{
      840: (439, 320),
      1024: (623, 320),
      1133: (680, 372),
      1180: (680, 419),
      1194: (680, 433),
      1199: (680, 438),
    };
    for (final MapEntry(key: w, value: (primary, pane)) in table.entries) {
      test('${w.toInt()} dp: primary ${primary.toInt()} / pane '
          '${pane.toInt()}', () {
        final c = w - AppSize.railCompact;
        expect(ShellGeometry.contextPaneWidthFor(c), pane);
        expect(c - 1 - ShellGeometry.contextPaneWidthFor(c), primary);
      });
    }

    test('clamped to 320..440 at the extremes', () {
      expect(ShellGeometry.contextPaneWidthFor(0), AppSize.contextPaneMin);
      expect(ShellGeometry.contextPaneWidthFor(5000), AppSize.contextPaneMax);
    });
  });

  group('ShellGeometry.contentRectFor', () {
    test('tablet layout, no insets: C = W - 80 (plan section 3)', () {
      final expected = {
        600.0: 520.0,
        673.0: 593.0,
        744.0: 664.0,
        800.0: 720.0,
        834.0: 754.0,
        839.0: 759.0,
        840.0: 760.0,
        1024.0: 944.0,
        1133.0: 1053.0,
        1180.0: 1100.0,
        1194.0: 1114.0,
        1199.0: 1119.0,
      };
      for (final MapEntry(key: w, value: c) in expected.entries) {
        final g = ShellGeometry.contentRectFor(
          Size(w, 900),
          EdgeInsets.zero,
          ShellLayout.tablet,
        );
        expect(g.tablet, isTrue, reason: '$w');
        expect(g.railWidth, AppSize.railCompact, reason: '$w');
        expect(g.content, Rect.fromLTWH(80, 0, c, 900), reason: '$w');
        // No dead strip: the rail and the content make up the window.
        expect(g.railWidth + g.content.width, w, reason: '$w');
      }
    });

    test('the leading inset widens the rail; the trailing one ends the '
        'content', () {
      const padding = EdgeInsets.fromLTRB(44, 24, 30, 21);
      final ltr = ShellGeometry.contentRectFor(
        const Size(932, 430),
        padding,
        ShellLayout.tablet,
      );
      expect(ltr.band, ShellBand.expanded);
      expect(ltr.railWidth, 80 + 44);
      expect(ltr.content, const Rect.fromLTWH(124, 0, 932 - 124 - 30, 430));

      // Right to left: the rail and its inset are on the right.
      final rtl = ShellGeometry.contentRectFor(
        const Size(932, 430),
        padding,
        ShellLayout.tablet,
        textDirection: TextDirection.rtl,
      );
      expect(rtl.railWidth, 80 + 30);
      expect(rtl.content, const Rect.fromLTWH(44, 0, 932 - 110 - 44, 430));
    });

    test('phones, desktop and the legacy layout are not modelled: the whole '
        'window, no rail', () {
      for (final (width, layout) in [
        (599.0, ShellLayout.tablet),
        (1200.0, ShellLayout.tablet),
        (1440.0, ShellLayout.tablet),
        (600.0, ShellLayout.legacy),
        (834.0, ShellLayout.legacy),
        (1199.0, ShellLayout.legacy),
      ]) {
        final g = ShellGeometry.contentRectFor(
          Size(width, 800),
          const EdgeInsets.only(left: 20, right: 20),
          layout,
        );
        expect(g.tablet, isFalse, reason: '$width $layout');
        expect(g.railWidth, 0, reason: '$width $layout');
        expect(
          g.content,
          Rect.fromLTWH(0, 0, width, 800),
          reason: '$width $layout',
        );
        expect(g.band, ShellBand.of(width));
      }
    });
  });

  testWidgets('maybeOf reads the published geometry and is null without '
      'one', (tester) async {
    final data = ShellGeometry.contentRectFor(
      const Size(834, 1194),
      EdgeInsets.zero,
      ShellLayout.tablet,
    );
    ShellGeometryData? seen;
    ShellGeometryData? outside;
    await tester.pumpWidget(
      Column(
        textDirection: TextDirection.ltr,
        children: [
          Builder(
            builder: (context) {
              outside = ShellGeometry.maybeOf(context);
              return const SizedBox();
            },
          ),
          ShellGeometry(
            data: data,
            child: Builder(
              builder: (context) {
                seen = ShellGeometry.maybeOf(context);
                return const SizedBox();
              },
            ),
          ),
        ],
      ),
    );
    expect(seen, data);
    expect(outside, isNull);
  });

  testWidgets('readableInset: a 680 dp column on the tablet layout, the '
      '600 dp one everywhere else', (tester) async {
    final insets = <String, double>{};
    Widget probe(String name, double width) => Builder(
      builder: (context) {
        insets[name] = ShellGeometry.readableInset(context, width);
        return const SizedBox();
      },
    );
    ShellGeometryData geometry(double window, ShellLayout layout) =>
        ShellGeometry.contentRectFor(
          Size(window, 1194),
          EdgeInsets.zero,
          layout,
        );
    await tester.pumpWidget(
      Column(
        textDirection: TextDirection.ltr,
        children: [
          // No geometry: phones, desktop, full-screen routes.
          probe('none 754', 754),
          probe('none 520', 520),
          ShellGeometry(
            data: geometry(834, ShellLayout.tablet),
            child: probe('tablet 754', 754),
          ),
          ShellGeometry(
            data: geometry(600, ShellLayout.tablet),
            child: probe('tablet 520', 520),
          ),
          ShellGeometry(
            data: geometry(1194, ShellLayout.tablet),
            child: probe('tablet 1114', 1114),
          ),
          ShellGeometry(
            data: geometry(834, ShellLayout.legacy),
            child: probe('legacy 754', 754),
          ),
        ],
      ),
    );
    expect(insets, {
      'none 754': 77,
      'none 520': 0,
      'tablet 754': 37,
      'tablet 520': 0,
      'tablet 1114': 217,
      'legacy 754': 77,
    });
  });
}
