import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

/// Helpers for the swipeable tile row of `PostMedia` (2-4 images).

Finder get _strip => find.byType(ListView);

/// The number of tiles the media row is built for, or null when there is no
/// row (zero or one image).
int? mediaPageCount(WidgetTester tester) {
  final finder = _strip;
  if (finder.evaluate().isEmpty) return null;
  final delegate = tester.widget<ListView>(finder.first).childrenDelegate;
  return (delegate as SliverChildBuilderDelegate).childCount;
}

double _step(WidgetTester tester) {
  // Tiles of the test rows share one aspect, so one step fits them all.
  final tile = tester.getSize(
    find.descendant(of: _strip.first, matching: find.byType(ClipRRect)).first,
  );
  return tile.width + AppSize.postMediaRowGap;
}

/// The tile the row is scrolled to (0-based), from its scroll offset; the last
/// tile counts once the row cannot scroll further.
int currentMediaPage(WidgetTester tester) {
  final scrollable = find.descendant(
    of: _strip.first,
    matching: find.byType(Scrollable),
  );
  final position = tester.state<ScrollableState>(scrollable).position;
  final count = mediaPageCount(tester)!;
  if (position.maxScrollExtent > 0 &&
      position.pixels >= position.maxScrollExtent - 0.5) {
    return count - 1;
  }
  return (position.pixels / _step(tester)).round();
}

/// Drags the row by one tile step and settles.
Future<void> _swipe(WidgetTester tester, double direction) async {
  final step = _step(tester);
  await tester.drag(_strip.first, Offset(direction * step, 0));
  await tester.pumpAndSettle();
}

/// Swipes one tile forward (finger moves left) and settles.
Future<void> swipeToNextMediaPage(WidgetTester tester) => _swipe(tester, -1);

/// Swipes one tile back and settles.
Future<void> swipeToPreviousMediaPage(WidgetTester tester) => _swipe(tester, 1);
