import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/shared/widgets/post/alt_text_chip.dart';
import 'package:dzeroth/shared/widgets/post/gif_badge.dart';
import 'package:dzeroth/shared/widgets/post/post_media.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/theme_harness.dart';

/// A list card's media row: every picture whole (its tile has exactly its
/// aspect ratio, so nothing is cropped and there are no bars), as tall as the
/// row for the window width, swipeable when there are several.

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
        child: PostMedia(media: media, row: true, onOpenImage: onOpen),
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
  final heights = {360.0: 220.0, 700.0: 260.0, 1300.0: 280.0};

  test('the row heights are 220 / 260 / 280 by window width', () {
    expect(AppSize.postMediaRowHeight(320), 220);
    expect(AppSize.postMediaRowHeight(599), 220);
    expect(AppSize.postMediaRowHeight(600), 260);
    expect(AppSize.postMediaRowHeight(1199), 260);
    expect(AppSize.postMediaRowHeight(1200), 280);
  });

  final cases = <(String, int, int)>[
    ('1:1', 400, 400),
    ('4:5', 800, 1000),
    ('16:9', 1600, 900),
    ('3:1 panorama', 3000, 1000),
    ('1:3 tall', 400, 1200),
    ('missing size', 0, 0),
  ];
  for (final window in heights.keys) {
    final rowHeight = heights[window]!;
    for (final (name, w, h) in cases) {
      testWidgets('one $name picture at ${window}dp: whole, left-aligned, '
          'row height $rowHeight', (tester) async {
        await _pump(tester, [_photo(w, h)], window: window);
        expect(tester.takeException(), isNull);
        final tile = _tiles(tester).single;
        final max = window - 2 * _gutter;
        final aspect = w > 0 && h > 0 ? w / h : 1.0;
        final wanted = rowHeight * aspect <= max
            ? Size(rowHeight * aspect, rowHeight)
            : Size(max, max / aspect);
        expect(tile.width, closeTo(wanted.width, 0.01));
        expect(tile.height, closeTo(wanted.height, 0.01));
        // No crop: the tile's ratio is the picture's.
        expect(tile.width / tile.height, closeTo(aspect, 0.001));
        // Left-aligned at the body's edge.
        expect(tile.left, closeTo(_gutter, 0.01));
        expect(
          tile.top,
          closeTo(tester.getTopLeft(find.byType(PostMedia)).dy, 0.01),
        );
      });
    }
  }

  testWidgets('a panorama wider than the body is capped to it, shorter, '
      'still whole', (tester) async {
    await _pump(tester, [_photo(3000, 1000)]);
    final tile = _tiles(tester).single;
    expect(tile.width, 320);
    expect(tile.height, closeTo(320 / 3, 0.01));
  });

  testWidgets('a tall picture keeps a narrow tile, never cropped', (
    tester,
  ) async {
    await _pump(tester, [_photo(400, 1200)]);
    expect(_tiles(tester).single.size, const Size(220 / 3, 220));
  });

  testWidgets('several pictures: a row of tiles with a gap, shorter tiles at '
      'the top', (tester) async {
    await _pump(tester, [_photo(400, 400, n: 1), _photo(3000, 1000, n: 2)]);
    final tiles = _tiles(tester);
    expect(tiles, hasLength(2));
    expect(tiles[0].left, closeTo(_gutter, 0.01));
    expect(tiles[0].height, 220);
    expect(
      tiles[1].left,
      closeTo(tiles[0].right + AppSize.postMediaRowGap, 0.01),
    );
    // The panorama is capped to the body width and shorter than the row, at
    // its top.
    expect(tiles[1].width, 320);
    expect(tiles[1].height, closeTo(320 / 3, 0.01));
    expect(tiles[1].top, tiles[0].top);
  });

  testWidgets('four pictures scroll horizontally, freely (no snapping), and '
      'a tap on the third reports index 2', (tester) async {
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
    // 391 + 8 per tile; a drag of 150 dp stays where it is put.
    await tester.drag(list, const Offset(-150, 0));
    await tester.pumpAndSettle();
    expect(offset(), greaterThan(100)); // the touch slop eats a little
    expect(offset(), lessThan(151));
    final third = find.byWidgetPredicate(
      (w) => w is CachedNetworkImage && w.imageUrl.endsWith('p2_t.jpg'),
    );
    // Scroll the third tile (it starts 798 dp in) well into view and tap it.
    await tester.drag(list, const Offset(-650, 0));
    await tester.pumpAndSettle();
    expect(third, findsOneWidget);
    await tester.tapAt(Offset(120, tester.getCenter(third).dy));
    await tester.pump();
    expect(opened, [2]);
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
    ]);
    expect(find.byType(GifBadge), findsOneWidget);
    // 100 px stays a 220 dp tile; no 2x letterbox inside it.
    expect(_tiles(tester).single.size, const Size(220, 220));
    expect(find.byKey(const ValueKey('gif-pixels')), findsNothing);
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
