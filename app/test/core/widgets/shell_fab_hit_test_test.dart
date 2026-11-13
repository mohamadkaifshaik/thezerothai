import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/responsive_scaffold.dart';
import 'package:dzeroth/core/widgets/shell_fab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// The phone's floating button must take taps at the raised spot (above the
// bar), at the corner it drops to when the bar scrolls away, and while it
// moves between them; the page behind it gets none of them.

const _destinations = [
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
];

void main() {
  late int fabTaps;
  late List<int> rowTaps;

  Future<void> pump(WidgetTester tester) async {
    fabTaps = 0;
    rowTaps = [];
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(brightness: Brightness.light),
        home: ResponsiveScaffold(
          selectedIndex: 0,
          onDestinationSelected: (_) {},
          destinations: _destinations,
          floatingBar: true,
          fab: ShellFabAction(
            tooltip: 'New thing',
            icon: Icons.add,
            onPressed: () => fabTaps++,
          ),
          // Full-width rows, so one is under the button at any position.
          body: ListView.builder(
            itemCount: 60,
            itemBuilder: (context, i) => SizedBox(
              height: 60,
              child: InkWell(
                onTap: () => rowTaps.add(i),
                child: Text('row $i'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Finder fab() => find.byTooltip('New thing');

  testWidgets('the button takes taps above the bar', (tester) async {
    await pump(tester);

    await tester.tap(fab());
    expect(fabTaps, 1);
    expect(rowTaps, isEmpty);
  });

  testWidgets('the button takes taps at the corner once the bar is gone, '
      'during the drop and after it', (tester) async {
    await pump(tester);
    final raised = tester.getCenter(fab());

    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pump(const Duration(milliseconds: 60));
    // Mid-drop.
    await tester.tapAt(tester.getCenter(fab()));
    expect(fabTaps, 1, reason: 'during the animation');
    expect(rowTaps, isEmpty);

    await tester.pumpAndSettle();
    final dropped = tester.getCenter(fab());
    expect(dropped.dy, greaterThan(raised.dy), reason: 'it dropped');

    await tester.tapAt(dropped);
    expect(fabTaps, 2, reason: 'at the corner');
    expect(rowTaps, isEmpty, reason: 'the page behind gets no tap');
  });

  testWidgets('the raised spot goes to the page once the button dropped', (
    tester,
  ) async {
    await pump(tester);
    final raised = tester.getCenter(fab());
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    rowTaps.clear();

    await tester.tapAt(raised);
    expect(fabTaps, 0);
    expect(rowTaps, hasLength(1));
  });
}
