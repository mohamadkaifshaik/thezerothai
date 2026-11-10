import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/shared/widgets/primitives/app_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/contrast.dart';
import '../../../support/geometry.dart';
import '../../../support/theme_harness.dart';

const _tabs = [
  AppTab(label: 'For you'),
  AppTab(label: 'Following'),
  AppTab(label: 'AI'),
  AppTab(label: 'Crypto'),
];

Widget _bar({
  List<AppTab> tabs = _tabs,
  int selected = 0,
  ValueChanged<int>? onChanged,
  bool equalWidth = false,
  Widget? trailing,
}) => AppTabBar(
  tabs: tabs,
  selectedIndex: selected,
  onChanged: onChanged ?? (_) {},
  equalWidth: equalWidth,
  trailing: trailing,
  semanticLabel: 'Timelines',
);

void main() {
  group('AppTabBar', () {
    forEachThemeAndWidth(
      'is at least 48dp tall, nothing overflows, targets and contrast hold',
      (tester, env) async {
        final handle = tester.ensureSemantics();
        await pumpThemed(
          tester,
          _bar(selected: 1),
          brightness: env.brightness,
          size: env.size,
          textScale: env.textScale,
        );

        final height = tester.getSize(find.byType(AppTabBar)).height;
        expect(height, greaterThanOrEqualTo(AppSpacing.minTapTarget));
        if (env.textScale == 1.0) {
          expect(height, lessThan(AppSpacing.minTapTarget + 8));
        } else {
          // Grows with the text instead of clipping.
          expect(height, greaterThan(AppSpacing.minTapTarget + 8));
        }
        expectNoOverflow(tester);
        for (final label in ['For you', 'Following']) {
          final tab = find.ancestor(
            of: find.text(label),
            matching: find.byType(InkWell),
          );
          expectMinTarget(tester, tab, reason: 'tab $label');
        }
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));

        final theme = Theme.of(tester.element(find.byType(AppTabBar)));
        final surface = theme.colorScheme.surface;
        final selected = tester.widget<Text>(find.text('Following')).style!;
        final unselected = tester.widget<Text>(find.text('For you')).style!;
        expect(contrast(selected.color!, surface), greaterThanOrEqualTo(4.5));
        expect(contrast(unselected.color!, surface), greaterThanOrEqualTo(4.5));
        expect(
          contrast(theme.extension<AppColors>()!.selectedIndicator, surface),
          greaterThanOrEqualTo(3.0),
        );
        handle.dispose();
      },
      widths: kRedesignWidths,
      textScales: kRedesignTextScales,
      heights: kRedesignHeights,
    );

    forEachThemeAndWidth(
      'four tabs: no overflow, scrollable only when needed, last tab '
      'reachable',
      (tester, env) async {
        await pumpThemed(
          tester,
          _bar(selected: 3),
          brightness: env.brightness,
          size: env.size,
          textScale: env.textScale,
        );

        expectNoOverflow(tester);
        final scroller = tester.state<ScrollableState>(find.byType(Scrollable));
        final overflows = scroller.position.maxScrollExtent > 0;
        if (env.size.width >= 834 && env.textScale == 1.0) {
          expect(overflows, isFalse);
        }
        if (env.size.width == 360 && env.textScale == 2.0) {
          // Four tabs at 2.0 cannot fit 360dp: the row scrolls.
          expect(overflows, isTrue);
          await tester.dragUntilVisible(
            find.text('Crypto'),
            find.byType(Scrollable),
            const Offset(-200, 0),
          );
          await tester.pumpAndSettle();
          expect(find.text('Crypto').hitTestable(), findsOneWidget);
          expectNoOverflow(tester);
        }
      },
      widths: kRedesignWidths,
      textScales: kRedesignTextScales,
      heights: kRedesignHeights,
    );

    forEachThemeAndWidth(
      'the indicator is 4 x 44dp in the selectedIndicator token, centred '
      'under the active tab, flush with the hairline',
      (tester, env) async {
        await pumpThemed(
          tester,
          _bar(selected: 1),
          brightness: env.brightness,
          size: env.size,
          textScale: env.textScale,
        );

        final indicator = find.byKey(const ValueKey('tab-indicator'));
        expect(indicator, findsOneWidget);
        expectSize(tester, indicator, width: 44, height: AppSize.tabIndicator);
        final decoration =
            tester.widget<Container>(indicator).decoration! as BoxDecoration;
        final tokens = env.isDark ? AppColors.dark : AppColors.light;
        expect(decoration.color, tokens.selectedIndicator);
        final tab = find.ancestor(
          of: find.text('Following'),
          matching: find.byType(InkWell),
        );
        expect(
          tester.getCenter(indicator).dx,
          closeTo(tester.getCenter(tab).dx, 0.5),
        );
        expect(
          tester.getRect(indicator).bottom,
          closeTo(tester.getRect(find.byType(AppTabBar)).bottom - 1, 1.01),
        );
      },
      widths: kRedesignWidths,
      textScales: kRedesignTextScales,
      heights: kRedesignHeights,
    );

    for (final brightness in Brightness.values) {
      testWidgets('golden: four tabs ${brightness.name}', (tester) async {
        final env = MatrixEnv(
          brightness: brightness,
          size: const Size(360, 800),
          textScale: 1.0,
        );
        await pumpThemed(
          tester,
          RepaintBoundary(child: _bar(selected: 1)),
          brightness: brightness,
          size: env.size,
        );
        await expectGolden(tester, find.byType(AppTabBar), 'app_tab_bar', env);
      });
    }

    testWidgets('equal-width: tabs share the width, indicator stays 44dp '
        'and centred in its tab', (tester) async {
      await pumpThemed(
        tester,
        _bar(
          tabs: const [
            AppTab(label: 'All'),
            AppTab(label: 'Mentions'),
          ],
          equalWidth: true,
        ),
        size: const Size(500, 800),
      );

      final all = tester.getCenter(find.text('All')).dx;
      final mentions = tester.getCenter(find.text('Mentions')).dx;
      expect(mentions - all, closeTo(250, 1));
      final indicator = find.byKey(const ValueKey('tab-indicator'));
      expectSize(tester, indicator, width: 44);
      expect(tester.getCenter(indicator).dx, closeTo(all, 0.5));
    });

    testWidgets('content-sized gap between labels is 44dp on a phone and '
        '60dp on a wide screen', (tester) async {
      await pumpThemed(tester, _bar(), size: const Size(400, 800));
      expectHorizontalGap(
        tester,
        find.text('For you'),
        find.text('Following'),
        2 * AppSize.tabPaddingNarrow,
      );
      await pumpThemed(tester, _bar(), size: const Size(1200, 800));
      expectHorizontalGap(
        tester,
        find.text('For you'),
        find.text('Following'),
        2 * AppSize.tabPaddingWide,
      );
    });

    testWidgets('a single tab is valid (Home: Following only)', (tester) async {
      await pumpThemed(tester, _bar(tabs: const [AppTab(label: 'Following')]));

      expect(find.text('Following'), findsOneWidget);
      expect(find.byKey(const ValueKey('tab-indicator')), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('selected label is w700 primary text, unselected is w600 '
        'secondary text (weight, not colour alone)', (tester) async {
      await pumpThemed(tester, _bar(), brightness: Brightness.dark);
      final colors = appDarkTheme.colorScheme;

      final active = tester.widget<Text>(find.text('For you')).style!;
      final inactive = tester.widget<Text>(find.text('Following')).style!;
      expect(active.fontWeight, FontWeight.w700);
      expect(active.color, colors.onSurface);
      expect(inactive.fontWeight, FontWeight.w600);
      expect(inactive.color, colors.onSurfaceVariant);
      expect(active.fontSize, 15);
    });

    testWidgets('tapping a tab reports its index', (tester) async {
      int? picked;
      // Wide enough that every label is on screen (test text is as wide as
      // the font size: 15dp per glyph).
      await pumpThemed(
        tester,
        _bar(onChanged: (i) => picked = i),
        size: const Size(1200, 800),
      );

      await tester.tap(find.text('Crypto'));
      expect(picked, 3);
    });

    testWidgets('overflowing content-sized tabs scroll horizontally', (
      tester,
    ) async {
      await pumpThemed(
        tester,
        _bar(tabs: [for (var i = 0; i < 8; i++) AppTab(label: 'Section $i')]),
        size: const Size(360, 800),
      );
      expectNoOverflow(tester);
      final scrollable = find.byType(Scrollable);
      expect(scrollable, findsOneWidget);
      await tester.dragUntilVisible(
        find.text('Section 7'),
        scrollable,
        const Offset(-200, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('Section 7').hitTestable(), findsOneWidget);
    });

    testWidgets('a fixed trailing widget stays at the right edge', (
      tester,
    ) async {
      await pumpThemed(
        tester,
        AppTabBar(
          tabs: [for (var i = 0; i < 8; i++) AppTab(label: 'Section $i')],
          selectedIndex: 0,
          onChanged: (_) {},
          fixedTrailing: const SizedBox(
            key: ValueKey('fixed'),
            width: 48,
            height: 48,
          ),
        ),
        size: const Size(320, 800),
      );

      expectNoOverflow(tester);
      expect(
        tester.getRect(find.byKey(const ValueKey('fixed'))).right,
        closeTo(320, 1),
      );
      // The tabs still scroll behind it.
      await tester.dragUntilVisible(
        find.text('Section 7'),
        find.byType(Scrollable),
        const Offset(-200, 0),
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('fixed'))).right,
        closeTo(320, 1),
      );
    });

    testWidgets('shows the trailing widget after the last tab', (tester) async {
      await pumpThemed(
        tester,
        _bar(
          trailing: const Padding(
            padding: EdgeInsets.all(AppSpacing.md),
            child: Icon(Icons.add, key: Key('plus')),
          ),
        ),
      );

      expect(
        tester.getRect(find.byKey(const Key('plus'))).left,
        greaterThan(tester.getRect(find.text('Crypto')).right),
      );
    });

    testWidgets('an icon is drawn before the label', (tester) async {
      await pumpThemed(
        tester,
        _bar(
          tabs: const [
            AppTab(label: 'Bookmarks', icon: Icons.bookmark_border),
            AppTab(label: 'Likes', icon: Icons.favorite_border),
          ],
          equalWidth: true,
        ),
      );

      expect(find.byIcon(Icons.bookmark_border), findsOneWidget);
      expect(
        tester.getRect(find.byIcon(Icons.bookmark_border)).right,
        lessThan(tester.getRect(find.text('Bookmarks')).left),
      );
    });

    testWidgets('semantics: a mutually exclusive group, the selected tab is '
        'flagged', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpThemed(tester, _bar(selected: 1));

      expect(
        tester.getSemantics(find.text('Following')),
        isSemantics(
          label: 'Following',
          isButton: true,
          isSelected: true,
          hasSelectedState: true,
          isInMutuallyExclusiveGroup: true,
          hasTapAction: true,
        ),
      );
      expect(
        tester.getSemantics(find.text('For you')),
        isSemantics(
          label: 'For you',
          isButton: true,
          isSelected: false,
          hasSelectedState: true,
          isInMutuallyExclusiveGroup: true,
          hasTapAction: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('arrow keys move the selection while a tab has focus', (
      tester,
    ) async {
      final picked = <int>[];
      await pumpThemed(tester, _bar(selected: 1, onChanged: picked.add));

      // Give a tab keyboard focus, then use the arrows.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);

      expect(picked, [2, 0]);
    });

    testWidgets('the arrows stop at both ends', (tester) async {
      final picked = <int>[];
      await pumpThemed(tester, _bar(selected: 3, onChanged: picked.add));

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);

      expect(picked, isEmpty);
    });
  });
}
