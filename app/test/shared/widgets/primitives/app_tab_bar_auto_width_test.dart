import 'package:dzeroth/shared/widgets/primitives/app_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/theme_harness.dart';

// The one alignment rule of the tab bars under the main headers (Home,
// Explore, Notifications): spread evenly with 4 or fewer tabs, scrollable and
// start-aligned with more. The indicator is the bar's own and unchanged.

List<AppTab> _tabs(int n) => [
  for (var i = 1; i <= n; i++) AppTab(label: 'T$i'),
];

Widget _bar(int n, {int selected = 0}) => AppTabBar(
  tabs: _tabs(n),
  selectedIndex: selected,
  onChanged: (_) {},
  autoWidth: true,
);

Finder _tab(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(InkWell));

void main() {
  const size = Size(390, 844);

  for (final n in [1, 2, 3, 4]) {
    testWidgets('$n tabs spread evenly across the width', (tester) async {
      await pumpThemed(tester, _bar(n), size: size);
      final bar = tester.getRect(find.byType(AppTabBar));
      for (var i = 1; i <= n; i++) {
        final r = tester.getRect(_tab('T$i'));
        expect(r.width, closeTo(bar.width / n, 0.5), reason: 'T$i width');
        expect(r.left, closeTo(bar.left + (i - 1) * bar.width / n, 0.5));
      }
      expect(find.byType(SingleChildScrollView), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('5 tabs scroll, start-aligned, content-sized', (tester) async {
    await pumpThemed(tester, _bar(5), size: size);
    final bar = tester.getRect(find.byType(AppTabBar));
    expect(find.byType(SingleChildScrollView), findsOneWidget);
    final first = tester.getRect(_tab('T1'));
    expect(first.left, closeTo(bar.left, 0.5));
    // Content-sized: far narrower than a fifth of the bar plus padding.
    final second = tester.getRect(_tab('T2'));
    expect(second.left, closeTo(first.right, 0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('more than 4 tabs that overflow scroll on a phone', (
    tester,
  ) async {
    await pumpThemed(
      tester,
      AppTabBar(
        tabs: [for (var i = 1; i <= 8; i++) AppTab(label: 'Pinned list $i')],
        selectedIndex: 0,
        onChanged: (_) {},
        autoWidth: true,
      ),
      size: size,
    );
    final scroller = tester.widget<SingleChildScrollView>(
      find.byType(SingleChildScrollView),
    );
    expect(scroller.scrollDirection, Axis.horizontal);
    expect(tester.getRect(_tab('Pinned list 1')).left, 0);
    expect(tester.getRect(_tab('Pinned list 8')).left, greaterThan(390));
  });

  testWidgets('3 labels that do not fit their share at 2x text scroll '
      'instead of being ellipsized', (tester) async {
    await pumpThemed(
      tester,
      AppTabBar(
        tabs: const [
          AppTab(label: 'Everything'),
          AppTab(label: 'Mentions'),
          AppTab(label: 'Plans'),
        ],
        selectedIndex: 0,
        onChanged: (_) {},
        autoWidth: true,
      ),
      size: const Size(360, 800),
      textScale: 2,
    );
    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the indicator is unchanged: 4 dp under the selected tab', (
    tester,
  ) async {
    await pumpThemed(tester, _bar(3, selected: 1), size: size);
    final indicator = find.byKey(const ValueKey('tab-indicator'));
    expect(indicator, findsOneWidget);
    expect(tester.getSize(indicator).width, 44);
    final tab = tester.getRect(_tab('T2'));
    expect(tester.getRect(indicator).center.dx, closeTo(tab.center.dx, 0.5));
  });

  test('tabsSpread: the rule is at most 4 tabs', () {
    expect(kMaxSpreadTabs, 4);
  });
}
