import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/widgets/app_bottom_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/communities_tablet_rig.dart';
import '../../support/lists_tablet_rig.dart';
import '../../support/profile_tablet_rig.dart';

// Phone shell: the floating bar is over the page, and the page's main scroll
// view runs to the screen's bottom edge, behind it (a `SafeArea` that keeps
// the bottom would end it at the bar's top edge and cut the content off).

const _height = 900.0;

void expectRunsBehindBar(WidgetTester tester) {
  final bar = tester.getRect(find.byType(AppBottomBar));
  expect(bar.top, lessThan(_height));
  final scrolls = [
    for (final e in find.byType(Scrollable).evaluate())
      if ((e as StatefulElement).state is ScrollableState &&
          (e.state as ScrollableState).axisDirection == AxisDirection.down)
        tester.getRect(find.byWidget(e.widget)),
  ];
  expect(scrolls, isNotEmpty);
  expect(
    scrolls.map((r) => r.bottom).reduce((a, b) => a > b ? a : b),
    _height,
    reason: 'the tallest vertical scroll view ends at the screen edge',
  );
}

void main() {
  testWidgets('Profile runs behind the bar', (tester) async {
    final rig = ProfileTabletRig();
    await rig.pump(tester, width: 390);
    expectRunsBehindBar(tester);
  });

  testWidgets('Lists runs behind the bar', (tester) async {
    final rig = ListsTabletRig();
    await rig.pump(tester, width: 390);
    expectRunsBehindBar(tester);
  });

  testWidgets('Communities runs behind the bar', (tester) async {
    final rig = CommunitiesTabletRig();
    await rig.pump(tester, width: 390, location: AppRouter.communitiesPath);
    expectRunsBehindBar(tester);
  });
}
