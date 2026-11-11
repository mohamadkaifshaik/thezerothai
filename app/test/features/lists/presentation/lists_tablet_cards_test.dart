import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/lists/presentation/widgets/home_tabs_preview.dart';
import 'package:dzeroth/features/lists/presentation/widgets/lists_owner_card.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/shared/widgets/primitives/app_surface.dart';
import 'package:dzeroth/shared/widgets/primitives/app_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/theme_harness.dart';

/// Whether the chevron under [icon] is drawn pointing left: its glyph, then
/// the mirror `Icon` applies itself in RTL when `matchTextDirection` is set.
bool _pointsLeft(WidgetTester tester, Finder icon) {
  final widget = tester.widget<Icon>(icon);
  final mirrored = find
      .descendant(
        of: icon,
        matching: find.byWidgetPredicate(
          (w) => w is Transform && w.transform.storage[0] < 0,
        ),
      )
      .evaluate()
      .isNotEmpty;
  final glyphLeft = widget.icon == Icons.chevron_left;
  return glyphLeft != mirrored;
}

Future<void> _pumpCard(
  WidgetTester tester,
  Widget card, {
  TextDirection direction = TextDirection.ltr,
  double textScale = 1,
}) => pumpThemed(
  tester,
  Directionality(
    textDirection: direction,
    child: Align(
      alignment: Alignment.topCenter,
      child: SizedBox(width: 320, child: card),
    ),
  ),
  size: const Size(400, 800),
  textScale: textScale,
);

/// The T8b UX review items on the Lists cards (owner card, Home tabs
/// preview).
void main() {
  final owner = common.AuthorSnapshot(
    userId: 'o1',
    handle: 'olivia',
    displayName: 'Olivia Owner',
  );

  for (final direction in TextDirection.values) {
    testWidgets('owner card, ${direction.name}: the chevron points to the '
        'reading end (drawn mirrored once at most)', (tester) async {
      await _pumpCard(
        tester,
        ListsOwnerCard(owner: owner, onTap: () {}),
        direction: direction,
      );
      final chevron = find.descendant(
        of: find.byType(ListsOwnerCard),
        matching: find.byWidgetPredicate(
          (w) =>
              w is Icon &&
              (w.icon == Icons.chevron_right || w.icon == Icons.chevron_left),
        ),
      );
      expect(chevron, findsOneWidget);
      expect(_pointsLeft(tester, chevron), direction == TextDirection.rtl);
    });
  }

  for (final scale in [1.0, 2.0]) {
    testWidgets('Home tabs preview at $scale: the bar sits inside the card, '
        'clear of its border and corners', (tester) async {
      await _pumpCard(
        tester,
        const HomeTabsPreviewCard(labels: ['Friends', 'Books']),
        textScale: scale,
      );
      final card = tester.getRect(find.byType(AppSurface));
      final bar = tester.getRect(find.byType(AppTabBar));
      expect(bar.left, greaterThanOrEqualTo(card.left + AppSpacing.sm));
      expect(bar.right, lessThanOrEqualTo(card.right - AppSpacing.sm));
      expect(bar.bottom, lessThanOrEqualTo(card.bottom - AppSpacing.sm));
    });

    testWidgets('Home tabs preview at $scale: the placeholder is the card\'s '
        'height, so nothing jumps when the page lends it', (tester) async {
      await _pumpCard(
        tester,
        const Column(
          children: [
            HomeTabsPreviewPlaceholder(),
            HomeTabsPreviewCard(labels: ['Friends']),
          ],
        ),
        textScale: scale,
      );
      final placeholder = tester.getSize(
        find.byType(HomeTabsPreviewPlaceholder),
      );
      final card = tester.getSize(find.byType(HomeTabsPreviewCard));
      expect(placeholder.height, card.height);
    });
  }
}
