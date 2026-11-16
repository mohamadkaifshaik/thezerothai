import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/shared/widgets/post/alt_text_chip.dart';
import 'package:dzeroth/shared/widgets/post/gif_badge.dart';
import 'package:dzeroth/shared/widgets/post/post_media.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/theme_harness.dart';

/// A post's several-images row: tiles of one height at their own aspects,
/// swipeable, each tile tappable and labelled.

const _gutter = 20.0;

common.MediaRef _photo(int w, int h, {int n = 0, String alt = ''}) =>
    common.MediaRef(
      url: 'https://cdn.example/m/p$n.jpg',
      thumbUrl: 'https://cdn.example/m/p${n}_t.jpg',
      width: w,
      height: h,
      contentType: 'image/jpeg',
      altText: alt,
    );

Future<void> _pump(
  WidgetTester tester,
  List<common.MediaRef> media, {
  double window = 360,
  ValueChanged<int>? onOpen,
}) async {
  // The test binding cannot download; the error widget shows instead.
  addTearDown(() => tester.takeException());
  await pumpThemed(
    tester,
    Align(
      alignment: Alignment.topLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: _gutter),
        child: PostMedia(media: media, onOpenImage: onOpen),
      ),
    ),
    size: Size(window, 900),
  );
}

/// The tiles' sizes, in order (each has one rounded clip of its own).
List<Rect> _tiles(WidgetTester tester) {
  final tiles = find.descendant(
    of: find.byType(PostMedia),
    matching: find.byType(ClipRRect),
    skipOffstage: false,
  );
  return [
    for (var i = 0; i < tiles.evaluate().length; i++)
      tester.getRect(tiles.at(i)),
  ];
}

void main() {
  testWidgets('several pictures: one height, own widths, at the body edge '
      'with a 4 dp gap', (tester) async {
    final media = [_photo(400, 400, n: 1), _photo(3000, 1000, n: 2)];
    await _pump(tester, media);
    final tiles = _tiles(tester);
    expect(tiles, hasLength(2));
    final column = 360 - 2 * _gutter;
    final height = PostMedia.rowHeight(media, column: column);
    expect(tiles[0].left, closeTo(_gutter, 0.01));
    expect(tiles[0].size, Size(height, height));
    expect(tiles[1].size, Size(height * 3, height));
    expect(
      tiles[1].left,
      closeTo(tiles[0].right + AppSize.postMediaRowGap, 0.01),
    );
    expect(tiles[1].top, tiles[0].top);
  });

  testWidgets('the row spans the given width and scrolls through the insets '
      'while the first tile stays on the body text', (tester) async {
    addTearDown(() => tester.takeException());
    final opened = <int>[];
    await pumpThemed(
      tester,
      Align(
        alignment: Alignment.topLeft,
        child: PostMedia(
          media: [for (var i = 0; i < 3; i++) _photo(900, 1600, n: i)],
          insetStart: _gutter,
          insetEnd: _gutter,
          onOpenImage: opened.add,
        ),
      ),
      size: const Size(360, 900),
    );
    final list = tester.getRect(find.byType(ListView));
    expect(list.left, 0);
    expect(list.right, 360);
    expect(_tiles(tester).first.left, closeTo(_gutter, 0.01));
    // Row height follows the column (360 - 2 x 20), not the full width.
    final height = PostMedia.rowHeight(
      [for (var i = 0; i < 3; i++) _photo(900, 1600, n: i)],
      column: 320,
    );
    expect(list.height, closeTo(height, 0.01));
    // Scrolled, a tile passes the body's start edge into the padding, and a
    // tap there (inside the old padding) still opens it.
    await tester.drag(find.byType(ListView), const Offset(-100, 0));
    await tester.pump();
    final first = _tiles(tester).first;
    expect(first.left, lessThan(_gutter - 50));
    await tester.tapAt(Offset(5, first.center.dy));
    await tester.pump();
    expect(opened, isNotEmpty);
  });

  testWidgets('four pictures scroll horizontally, freely, and '
      'a tap reports the tile index', (tester) async {
    final opened = <int>[];
    await _pump(tester, [
      for (var i = 0; i < 4; i++) _photo(1600, 900, n: i),
    ], onOpen: opened.add);
    final list = find.byType(ListView);
    expect(list, findsOneWidget);
    final scrollable = find.descendant(
      of: list,
      matching: find.byType(Scrollable),
    );
    double offset() =>
        tester.state<ScrollableState>(scrollable).position.pixels;
    expect(offset(), 0);
    // A drag of 150 dp stays where it is put (no snapping).
    await tester.drag(list, const Offset(-150, 0));
    await tester.pumpAndSettle();
    expect(offset(), greaterThan(100)); // the touch slop eats a little
    expect(offset(), lessThan(151));
    // Scroll back to the start and tap the first tile, then the second.
    await tester.drag(list, const Offset(1000, 0));
    await tester.pumpAndSettle();
    final first = find.byWidgetPredicate(
      (w) => w is CachedNetworkImage && w.imageUrl.endsWith('p0_t.jpg'),
    );
    await tester.tapAt(tester.getCenter(first));
    await tester.pump();
    expect(opened, [0]);
    final second = find.byWidgetPredicate(
      (w) => w is CachedNetworkImage && w.imageUrl.endsWith('p1_t.jpg'),
    );
    await tester.tapAt(tester.getTopLeft(second) + const Offset(5, 5));
    await tester.pump();
    expect(opened, [0, 1]);
  });

  testWidgets('the row exposes scroll semantics', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, [for (var i = 0; i < 3; i++) _photo(1600, 900, n: i)]);
    await tester.pump();
    var found = false;
    void visit(SemanticsNode node) {
      final data = node.getSemanticsData();
      if (data.hasAction(ui.SemanticsAction.scrollLeft)) found = true;
      node.visitChildren((child) {
        visit(child);
        return true;
      });
    }

    visit(tester.getSemantics(find.byType(PostMedia)));
    expect(found, isTrue, reason: 'a node offers scrollLeft');
    handle.dispose();
  });

  testWidgets('each tile keeps its alt text as a semantics label and its '
      'ALT chip', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, [
      _photo(1000, 1000, n: 1, alt: 'a red door'),
      _photo(1000, 1000, n: 2, alt: 'a blue door'),
    ]);
    expect(find.bySemanticsLabel('a red door'), findsOneWidget);
    expect(find.byType(AltTextChip), findsNWidgets(2));
    handle.dispose();
  });

  testWidgets('a GIF tile keeps its badge and fills its tile', (tester) async {
    await _pump(tester, [
      common.MediaRef(
        url: 'https://cdn.example/m/g.gif',
        thumbUrl: 'https://cdn.example/m/g_t.jpg',
        width: 100,
        height: 100,
        contentType: 'image/gif',
      ),
      _photo(100, 100),
    ]);
    expect(find.byType(GifBadge), findsOneWidget);
    expect(_tiles(tester).first.size.aspectRatio, closeTo(1, 0.001));
  });

  for (final window in const [320.0, 360.0, 400.0, 700.0, 1100.0, 1300.0]) {
    testWidgets('no overflow at ${window}dp with mixed ratios and a '
        'panorama', (tester) async {
      await _pump(tester, [
        _photo(3000, 1000, n: 1),
        _photo(400, 1200, n: 2),
        _photo(0, 0, n: 3),
        _photo(800, 1000, n: 4),
      ], window: window);
      expect(tester.takeException(), isNull);
      final tiles = _tiles(tester);
      expect(tiles, isNotEmpty);
      expect(tiles.first.left, closeTo(_gutter, 0.01));
    });
  }
}
