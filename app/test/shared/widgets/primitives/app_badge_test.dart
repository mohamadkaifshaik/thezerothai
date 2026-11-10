import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/shared/widgets/primitives/app_badge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/theme_harness.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

Widget _row() => const Align(
  alignment: Alignment.topLeft,
  child: Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      AppCountBadge(count: 120, semanticsLabel: '120 unread notifications'),
      AppCountBadge(
        count: 3,
        semanticsLabel: '3 unread messages',
        onNavy: true,
      ),
      AppUnreadDot(semanticsLabel: 'Unread'),
      AppTintBadge(label: 'Verified creator'),
      AppTintBadge(label: 'Muted', tone: AppTintTone.neutral),
    ],
  ),
);

void main() {
  forEachThemeAndWidth(
    'badges fit, announce their labels and grow with text',
    (tester, env) async {
      final handle = tester.ensureSemantics();
      await pumpThemed(
        tester,
        _row(),
        brightness: env.brightness,
        size: env.size,
        textScale: env.textScale,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('99+'), findsOneWidget);
      expect(find.bySemanticsLabel('120 unread notifications'), findsOneWidget);
      expect(find.bySemanticsLabel('3 unread messages'), findsOneWidget);
      expect(find.bySemanticsLabel('Unread'), findsOneWidget);
      expect(find.bySemanticsLabel('Verified creator'), findsOneWidget);
      // The digits alone are not announced a second time.
      expect(find.bySemanticsLabel('99+'), findsNothing);
      final count = tester.getSize(find.byType(AppCountBadge).first);
      expect(count.height, greaterThanOrEqualTo(AppCountBadge.minSize));
      expect(
        tester.getSize(find.byType(AppTintBadge).first).height,
        greaterThanOrEqualTo(AppTintBadge.minHeight),
      );
      if (env.textScale == 2.0) {
        expect(count.height, greaterThan(AppCountBadge.minSize));
      }
      await expectGolden(tester, find.byType(Scaffold), 'badges', env);
      handle.dispose();
    },
    widths: kRedesignWidths,
    textScales: kRedesignTextScales,
    heights: kRedesignHeights,
  );

  test('format caps at 99+', () {
    expect(AppCountBadge.format(0), '0');
    expect(AppCountBadge.format(99), '99');
    expect(AppCountBadge.format(100), '99+');
    expect(AppCountBadge.format(7, max: 5), '5+');
  });

  testWidgets('a zero count renders nothing and no semantics', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpThemed(
      tester,
      const AppCountBadge(count: 0, semanticsLabel: 'No unread'),
    );
    expect(find.bySemanticsLabel('No unread'), findsNothing);
    expect(find.byType(Text), findsNothing);
    handle.dispose();
  });

  for (final brightness in Brightness.values) {
    final theme = buildAppTheme(brightness: brightness);
    final colors = theme.extension<AppColors>()!;
    final page = theme.colorScheme.surface;
    final name = brightness.name;

    test('tint badge accent label >= 4.5:1 on its tint ($name)', () {
      expect(
        _contrast(colors.accentText, AppTintBadge.accentFill(page)),
        greaterThanOrEqualTo(4.5),
      );
    });

    test('tint badge neutral label >= 4.5:1 ($name)', () {
      expect(
        _contrast(
          colors.secondaryOnRaised,
          theme.colorScheme.surfaceContainerHigh,
        ),
        greaterThanOrEqualTo(4.5),
      );
    });

    test('count badge pair >= 4.5:1 and distinct from the page ($name)', () {
      expect(
        _contrast(colors.strongPillLabel, colors.strongPillFill),
        greaterThanOrEqualTo(4.5),
      );
      expect(_contrast(colors.strongPillFill, page), greaterThanOrEqualTo(3));
    });

    test('unread dot is >= 3:1 against its ring ($name)', () {
      expect(_contrast(colors.accentText, page), greaterThanOrEqualTo(3));
    });
  }

  test('on-navy count badge pair', () {
    expect(_contrast(AppPalette.navy, AppPalette.pearl), greaterThan(4.5));
    expect(_contrast(AppPalette.pearl, AppPalette.navy), greaterThan(3));
  });

  testWidgets('the tint badge can exclude its semantics', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpThemed(
      tester,
      const AppTintBadge(label: 'Coming soon', excludeSemantics: true),
    );
    expect(find.bySemanticsLabel('Coming soon'), findsNothing);
    handle.dispose();
  });

  testWidgets('the unread dot is an 8dp core inside a 2dp ring', (
    tester,
  ) async {
    await pumpThemed(tester, const AppUnreadDot(semanticsLabel: 'Unread'));
    expect(tester.getSize(find.byType(AppUnreadDot)), const Size(12, 12));
  });
}
