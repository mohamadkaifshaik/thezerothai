import 'package:cached_network_image/cached_network_image.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/shared/widgets/post/post_media.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/theme_harness.dart';

/// X shows a row of 38 x 2048 strips uncropped, one row, nothing scrolling.

common.MediaRef _photo(int w, int h, {int n = 0}) => common.MediaRef(
  url: 'https://cdn.example/m/p$n.jpg',
  thumbUrl: 'https://cdn.example/m/p${n}_t.jpg',
  width: w,
  height: h,
  contentType: 'image/jpeg',
);

const _strip = 38 / 2048;

void main() {
  test('1:150 is trusted, 1:300 and 1:1e6 are unknown, wide end unchanged', () {
    expect(kMinTrustedAspect, 1 / 200);
    expect(PostMedia.rowAspect(_photo(38, 2048)), closeTo(_strip, 1e-9));
    expect(PostMedia.rowAspect(_photo(10, 1500)), closeTo(1 / 150, 1e-9));
    expect(PostMedia.rowAspect(_photo(10, 3000)), closeTo(0.8, 1e-9));
    expect(PostMedia.rowAspect(_photo(1, 1000000)), closeTo(0.8, 1e-9));
    expect(PostMedia.rowAspect(_photo(51, 1)), closeTo(0.8, 1e-9));
    expect(PostMedia.rowAspect(_photo(0, 2048)), closeTo(0.8, 1e-9));
  });

  test('five 38 x 2048 tiles: the row is 1.243 x column and fits', () {
    for (final c in [330.0, 518.0]) {
      final media = [for (var i = 0; i < 5; i++) _photo(38, 2048, n: i)];
      final h = PostMedia.rowHeight(media, column: c, wide: false);
      expect(h, closeTo(1.243 * c, 1e-9));
      final w = PostMedia.tileSize(media.first, height: h).width;
      expect(w, closeTo(h * _strip, 1e-9));
      expect(5 * w + 4 * AppSize.postMediaRowGap, lessThan(c));
    }
  });

  test('wide windows keep the 520 dp cap on the row height', () {
    final media = [for (var i = 0; i < 4; i++) _photo(38, 2048, n: i)];
    expect(PostMedia.rowHeight(media, column: 518, wide: true), 520);
  });

  Future<List<int>> pump(
    WidgetTester tester, {
    required double window,
    required double column,
    int count = 4,
    double inset = 0,
  }) async {
    addTearDown(() => tester.takeException());
    final opened = <int>[];
    await pumpThemed(
      tester,
      Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: column + inset,
          child: PostMedia(
            insetStart: inset,
            media: [for (var i = 0; i < count; i++) _photo(38, 2048, n: i)],
            onOpenImage: opened.add,
          ),
        ),
      ),
      size: Size(window, 900),
    );
    return opened;
  }

  List<Rect> tiles(WidgetTester tester) {
    final clips = find.descendant(
      of: find.byType(PostMedia),
      matching: find.byType(ClipRRect),
    );
    return [
      for (var i = 0; i < clips.evaluate().length; i++)
        tester.getRect(clips.at(i)),
    ];
  }

  for (final (name, window, column, wide) in [
    ('phone', 390.0, 330.0, false),
    ('desktop', 1280.0, 518.0, true),
  ]) {
    testWidgets('$name: strips are uncropped, one row, nothing scrolls', (
      tester,
    ) async {
      await pump(tester, window: window, column: column);
      // The 520 dp cap of wide windows is the existing rule.
      final expected = wide ? 520.0 : 1.243 * column;
      final rects = tiles(tester);
      expect(rects.length, 4);
      for (final r in rects) {
        expect(r.height, closeTo(expected, 0.5));
        expect(r.width, closeTo(expected * 38 / 2048, 0.5));
        expect(r.width / r.height, closeTo(_strip, 0.002));
      }
      expect(rects.last.right, lessThan(column));
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      expect(position.maxScrollExtent, 0);
      for (final image in tester.widgetList<CachedNetworkImage>(
        find.byType(CachedNetworkImage),
      )) {
        expect(image.memCacheWidth, greaterThanOrEqualTo(1));
      }
    });
  }

  testWidgets('a tap on or near tile 3 opens index 2', (tester) async {
    final opened = await pump(tester, window: 390, column: 330);
    final r = tiles(tester)[2];
    await tester.tapAt(r.center);
    expect(opened, [2]);
    // Left of the tile, in the gap: nearest is tile 3 (index 2) past the
    // middle of the gap, tile 2 (index 1) before it.
    await tester.tapAt(Offset(r.left - 1, r.center.dy));
    await tester.tapAt(Offset(r.right + 1, r.center.dy));
    expect(opened, [2, 2, 2]);
  });

  testWidgets('beside the first and last strip still opens them', (
    tester,
  ) async {
    final opened = await pump(tester, window: 390, column: 330, inset: 16);
    final all = tiles(tester);
    await tester.tapAt(Offset(all.first.left - 10, all.first.center.dy));
    await tester.tapAt(Offset(all.last.right + 10, all.last.center.dy));
    expect(opened, [0, 3]);
    // Far from the strips nothing opens (the card's own tap decides).
    await tester.tapAt(Offset(all.last.right + 60, all.last.center.dy));
    expect(opened, [0, 3]);
  });
}
