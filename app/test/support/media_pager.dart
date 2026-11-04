import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Helpers for the swipeable image pages of `PostMedia` (2-4 images).

/// The number of pages the media pager is built for, or null when there is no
/// pager (zero or one image).
int? mediaPageCount(WidgetTester tester) {
  final finder = find.byType(PageView);
  if (finder.evaluate().isEmpty) return null;
  final delegate = tester.widget<PageView>(finder).childrenDelegate;
  return (delegate as SliverChildBuilderDelegate).childCount;
}

/// The page the pager is settled on (0-based), from its scroll offset.
int currentMediaPage(WidgetTester tester) {
  final scrollable = find.descendant(
    of: find.byType(PageView),
    matching: find.byType(Scrollable),
  );
  final pixels = tester.state<ScrollableState>(scrollable).position.pixels;
  final width = tester.getSize(find.byType(PageView)).width;
  return (pixels / width).round();
}

/// Drags the pager by three quarters of a page and settles, so it lands on
/// the neighbouring page exactly (a fling could skip several).
Future<void> _swipe(WidgetTester tester, double direction) async {
  final width = tester.getSize(find.byType(PageView)).width;
  await tester.drag(find.byType(PageView), Offset(direction * width * 0.75, 0));
  await tester.pumpAndSettle();
}

/// Swipes one page forward (finger moves left) and settles.
Future<void> swipeToNextMediaPage(WidgetTester tester) => _swipe(tester, -1);

/// Swipes one page back and settles.
Future<void> swipeToPreviousMediaPage(WidgetTester tester) => _swipe(tester, 1);
