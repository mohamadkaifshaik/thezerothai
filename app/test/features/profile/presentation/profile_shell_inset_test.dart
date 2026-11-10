import 'package:dzeroth/core/widgets/app_bottom_bar.dart';
import 'package:dzeroth/core/widgets/responsive_scaffold.dart';
import 'package:dzeroth/features/timeline/presentation/widgets/feed_post_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/profile_rig.dart';

const _destinations = [
  AppNavDestination(
    icon: Icons.home_outlined,
    selectedIcon: Icons.home,
    label: 'Home',
  ),
  AppNavDestination(
    icon: Icons.notifications_none,
    selectedIcon: Icons.notifications,
    label: 'Notifications',
  ),
];

/// The profile's tabbed feed (a `TimelineFeedView` per tab, inside the
/// `TabBarView` of a `NestedScrollView`) under the phone chrome of the shell:
/// the end of a tab must clear the floating bar (`ui_shell` on), and the
/// docked bar of the legacy chrome is unchanged. The inner lists scroll at a
/// depth below the shell's scroll-hide listener, so nothing here relies on
/// the bar hiding; the tests jump instead of dragging for the same reason.
void main() {
  late W3ProfileRig rig;

  setUpAll(W3ProfileRig.registerFallbacks);
  setUp(() => rig = W3ProfileRig());
  tearDown(() => rig.dispose());

  Future<void> open(WidgetTester tester, {required bool floating}) async {
    rig.arrange(rowsPerTab: 12);
    await rig.open(
      tester,
      size: const Size(360, 800),
      wrap: (screen) => ResponsiveScaffold(
        selectedIndex: null,
        onDestinationSelected: (_) {},
        destinations: _destinations,
        floatingBar: floating,
        body: screen,
      ),
    );
  }

  /// Collapses the header, then scrolls the open tab to its end.
  Future<void> jumpToEnd(WidgetTester tester) async {
    final nested = tester.state<NestedScrollViewState>(
      find.byType(NestedScrollView),
    );
    final outer = nested.outerController;
    outer.jumpTo(outer.position.maxScrollExtent);
    await tester.pumpAndSettle();
    final inner = nested.innerController;
    for (final position in inner.positions) {
      position.jumpTo(position.maxScrollExtent);
    }
    await tester.pumpAndSettle();
  }

  testWidgets('ui_shell on: the last row of a tab ends above the pill', (
    tester,
  ) async {
    await open(tester, floating: true);
    await jumpToEnd(tester);

    final opacity = tester.widget<AnimatedOpacity>(
      find.ancestor(
        of: find.byType(AppBottomBar),
        matching: find.byType(AnimatedOpacity),
      ),
    );
    expect(opacity.opacity, 1);
    final pill = tester.getRect(
      find.descendant(
        of: find.byType(AppFloatingBottomBar),
        matching: find.byType(Material),
      ),
    );
    expect(pill.top, 800 - 90);
    final last = tester.getRect(find.byType(FeedPostRow).last);
    expect(last.bottom, lessThanOrEqualTo(pill.top));
  });

  testWidgets('ui_shell off: the tab ends at the top of the docked bar', (
    tester,
  ) async {
    await open(tester, floating: false);
    await jumpToEnd(tester);

    expect(find.byType(AppFloatingBottomBar), findsNothing);
    final barTop = tester.getRect(find.byType(AppBottomBar)).top;
    expect(barTop, 800 - 56);
    final last = tester.getRect(find.byType(FeedPostRow).last);
    expect(last.bottom, lessThanOrEqualTo(barTop));
    expect(last.bottom, greaterThan(barTop - 56));
  });
}
