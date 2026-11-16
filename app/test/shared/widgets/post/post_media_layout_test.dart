import 'package:cached_network_image/cached_network_image.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/shared/widgets/post/alt_text_chip.dart';
import 'package:dzeroth/shared/widgets/post/gif_badge.dart';
import 'package:dzeroth/shared/widgets/post/post_media.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/theme_harness.dart';

/// X-style post media: a frame is as wide as the body column (never a fixed
/// height); one image keeps its own aspect, uncropped, between 9:16 and 3:1;
/// several are tiles of one shared height (each at its own aspect) in a
/// scrollable row. Tablet and desktop cap a single frame at 520 dp tall (its
/// width shrinks to keep the ratio).

/// Window width and the body column it implies (the feed's column minus the
/// avatar gutter): phone 390 -> 306, tablet 800 -> 540, desktop 1280 -> 540.
const _layouts = <(String, double, double)>[
  ('phone', 390, 306),
  ('tablet', 800, 540),
  ('desktop', 1280, 540),
];

common.MediaRef _photo(int w, int h, {int n = 0}) => common.MediaRef(
  url: 'https://cdn.example/m/p$n.jpg',
  thumbUrl: 'https://cdn.example/m/p${n}_t.jpg',
  width: w,
  height: h,
  contentType: 'image/jpeg',
);

common.MediaRef _gif(int w, int h) => common.MediaRef(
  url: 'https://cdn.example/m/g.gif',
  thumbUrl: 'https://cdn.example/m/g_t.jpg',
  width: w,
  height: h,
  contentType: 'image/gif',
);

Future<void> _pump(
  WidgetTester tester,
  List<common.MediaRef> media, {
  required double window,
  required double column,
  Brightness brightness = Brightness.light,
  TextDirection direction = TextDirection.ltr,
  bool useFullImage = false,
  double textScale = 1,
}) async {
  // The test binding cannot download; the error widget shows instead.
  addTearDown(() => tester.takeException());
  await pumpThemed(
    tester,
    Directionality(
      textDirection: direction,
      child: Align(
        alignment: AlignmentDirectional.topStart,
        child: SizedBox(
          width: column,
          child: PostMedia(media: media, useFullImage: useFullImage),
        ),
      ),
    ),
    size: Size(window, 900),
    brightness: brightness,
    textScale: textScale,
  );
}

/// The frames' rects, in order (each has one rounded clip of its own).
List<Rect> _frames(WidgetTester tester) {
  final clips = find.descendant(
    of: find.byType(PostMedia),
    matching: find.byType(ClipRRect),
    skipOffstage: false,
  );
  return [
    for (var i = 0; i < clips.evaluate().length; i++)
      tester.getRect(clips.at(i)),
  ];
}

void main() {
  for (final (name, window, column) in _layouts) {
    final wide = window >= AppBreakpoints.mobile;
    final cap = AppSize.postMediaMaxSingleHeight;

    group('$name ($window dp window, $column dp column)', () {
      testWidgets('single 16:9 is the full column at its own ratio', (
        tester,
      ) async {
        await _pump(
          tester,
          [_photo(1600, 900)],
          window: window,
          column: column,
        );
        final frame = _frames(tester).single;
        expect(frame.left, 0);
        expect(frame.width, closeTo(column, 0.01));
        expect(frame.height, closeTo(column * 9 / 16, 0.01));
      });

      testWidgets('single 1:1 is square, capped on wide windows', (
        tester,
      ) async {
        await _pump(tester, [_photo(800, 800)], window: window, column: column);
        final frame = _frames(tester).single;
        final side = wide && column > cap ? cap : column;
        expect(frame.width, closeTo(side, 0.01));
        expect(frame.height, closeTo(side, 0.01));
      });

      testWidgets('single 4:5 is the full column at 4:5 (capped wide)', (
        tester,
      ) async {
        await _pump(
          tester,
          [_photo(800, 1000)],
          window: window,
          column: column,
        );
        final frame = _frames(tester).single;
        final height = wide && column * 1.25 > cap ? cap : column * 1.25;
        expect(frame.height, closeTo(height, 0.01));
        expect(frame.width / frame.height, closeTo(0.8, 0.001));
      });

      testWidgets('single 9:16 is the tallest frame, uncropped', (
        tester,
      ) async {
        await _pump(
          tester,
          [_photo(900, 1600)],
          window: window,
          column: column,
        );
        final frame = _frames(tester).single;
        expect(frame.width / frame.height, closeTo(9 / 16, 0.001));
        final height = column * 16 / 9;
        expect(
          frame.height,
          closeTo(wide && height > cap ? cap : height, 0.01),
        );
      });

      testWidgets('single 1:2 is clamped to 9:16 and center-cropped', (
        tester,
      ) async {
        await _pump(
          tester,
          [_photo(500, 1000)],
          window: window,
          column: column,
        );
        final frame = _frames(tester).single;
        expect(frame.width / frame.height, closeTo(9 / 16, 0.001));
        final image = tester.widget<CachedNetworkImage>(
          find.byType(CachedNetworkImage).first,
        );
        expect(image.fit, BoxFit.cover);
        expect(image.alignment, Alignment.center);
      });

      testWidgets('single 2:3 keeps its ratio', (tester) async {
        await _pump(tester, [_photo(600, 900)], window: window, column: column);
        final frame = _frames(tester).single;
        expect(frame.width / frame.height, closeTo(2 / 3, 0.001));
      });

      testWidgets('single 2.59:1 panorama is uncropped', (tester) async {
        await _pump(
          tester,
          [_photo(2590, 1000)],
          window: window,
          column: column,
        );
        final frame = _frames(tester).single;
        expect(frame.width, closeTo(column, 0.01));
        expect(frame.height, closeTo(column / 2.59, 0.01));
      });

      testWidgets('single 4:1 is clamped to 3:1 and center-cropped', (
        tester,
      ) async {
        await _pump(
          tester,
          [_photo(4000, 1000)],
          window: window,
          column: column,
        );
        final frame = _frames(tester).single;
        expect(frame.width, closeTo(column, 0.01));
        expect(frame.height, closeTo(column / 3, 0.01));
        expect(
          tester
              .widget<CachedNetworkImage>(find.byType(CachedNetworkImage))
              .fit,
          BoxFit.cover,
        );
      });

      testWidgets('an image without a size is 4:5', (tester) async {
        await _pump(tester, [_photo(0, 0)], window: window, column: column);
        final frame = _frames(tester).single;
        expect(frame.width / frame.height, closeTo(0.8, 0.001));
      });

      testWidgets('several images: one shared height, own widths, 4 dp gap', (
        tester,
      ) async {
        // Portrait and square first, so more than one tile is on screen (the
        // row builds its tiles lazily).
        final media = [
          _photo(900, 1600, n: 1),
          _photo(800, 800, n: 2),
          _photo(1600, 900, n: 3),
          _photo(0, 0, n: 4),
        ];
        await _pump(tester, media, window: window, column: column);
        final tiles = _frames(tester);
        expect(tiles.length, greaterThanOrEqualTo(2));
        final height = PostMedia.rowHeight(media, column: column, wide: wide);
        for (var i = 0; i < tiles.length; i++) {
          expect(tiles[i].height, closeTo(height, 0.01));
          expect(
            tiles[i].width,
            closeTo(height * PostMedia.rowAspect(media[i]), 0.01),
          );
        }
        expect(tiles.first.left, 0);
        expect(
          tiles[1].left,
          closeTo(tiles.first.right + AppSize.postMediaRowGap, 0.01),
        );
        final scrollable = find.descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        );
        final position = tester.state<ScrollableState>(scrollable).position;
        expect(position.maxScrollExtent, greaterThan(0));
        await tester.drag(find.byType(ListView), const Offset(-120, 0));
        await tester.pump();
        expect(position.pixels, greaterThan(0));
      });

      testWidgets('the 520 cap holds for a single frame', (tester) async {
        await _pump(
          tester,
          [_photo(800, 1000), _photo(1, 1)].take(1).toList(),
          window: window,
          column: column,
        );
        final frame = _frames(tester).single;
        if (wide) expect(frame.height, lessThanOrEqualTo(cap));
        expect(frame.width, lessThanOrEqualTo(column));
      });

      for (final brightness in Brightness.values) {
        testWidgets('no overflow in ${brightness.name}', (tester) async {
          for (final media in [
            [_photo(1600, 900)],
            [_photo(900, 1600)],
            [_photo(1, 1), _photo(1, 1), _photo(1, 1)],
            [_gif(100, 100)..altText = 'a cat'],
          ]) {
            await _pump(
              tester,
              media,
              window: window,
              column: column,
              brightness: brightness,
              textScale: 2,
            );
            expect(tester.takeException(), isNull);
          }
        });
      }
    });
  }

  testWidgets('the 520 cap shrinks the width, keeping the ratio', (
    tester,
  ) async {
    await _pump(tester, [_photo(800, 800)], window: 1280, column: 700);
    final frame = _frames(tester).single;
    expect(frame.size, const Size(520, 520));
    expect(frame.left, 0);
  });

  testWidgets('a frame sits at the start edge in RTL', (tester) async {
    await _pump(
      tester,
      [_photo(800, 800)],
      window: 1280,
      column: 700,
      direction: TextDirection.rtl,
    );
    expect(
      _frames(tester).single.right,
      closeTo(tester.getRect(find.byType(PostMedia)).right, 0.01),
    );
  });

  testWidgets('frames are rounded 16 dp, row tiles 8 dp', (tester) async {
    await _pump(tester, [_photo(1600, 900)], window: 390, column: 306);
    final clip = tester.widget<ClipRRect>(
      find.descendant(
        of: find.byType(PostMedia),
        matching: find.byType(ClipRRect),
      ),
    );
    expect(clip.borderRadius, BorderRadius.circular(AppRadius.postMedia));
    expect(AppRadius.postMedia, 16);
    await _pump(
      tester,
      [_photo(900, 1600), _photo(900, 1600)],
      window: 390,
      column: 306,
    );
    final tile = tester.widget<ClipRRect>(
      find
          .descendant(
            of: find.byType(PostMedia),
            matching: find.byType(ClipRRect),
          )
          .first,
    );
    expect(tile.borderRadius, BorderRadius.circular(8));
  });

  group('GIFs use the same frame', () {
    testWidgets('a GIF fills a single 16:9 frame with its badge', (
      tester,
    ) async {
      await _pump(tester, [_gif(160, 90)], window: 390, column: 306);
      expect(find.byType(GifBadge), findsOneWidget);
      final frame = _frames(tester).single;
      expect(frame.width, closeTo(306, 0.01));
      expect(frame.height, closeTo(306 * 9 / 16, 0.01));
    });

    for (final direction in TextDirection.values) {
      testWidgets('a tiny GIF with ALT text at text x2 (${direction.name}) '
          'fits its controls in the frame', (tester) async {
        await _pump(
          tester,
          [_gif(10, 10)..altText = 'a cat'],
          window: 390,
          column: 306,
          direction: direction,
          textScale: 2,
        );
        expect(tester.takeException(), isNull);
        final play = tester.getRect(
          find
              .ancestor(
                of: find.byIcon(Icons.play_arrow_rounded),
                matching: find.byType(SizedBox),
              )
              .first,
        );
        expect(play.shortestSide, greaterThanOrEqualTo(48));
        final frame = _frames(tester).single;
        expect(frame.contains(play.topLeft), isTrue);
        expect(frame.contains(play.bottomRight - const Offset(1, 1)), isTrue);
        final chip = tester.getRect(
          find
              .descendant(
                of: find.byType(AltTextChip),
                matching: find.byType(ConstrainedBox),
              )
              .first,
        );
        expect(chip.overlaps(play), isFalse, reason: 'chip $chip play $play');
        final badge = tester.getRect(find.byType(GifBadge));
        expect(badge.overlaps(play), isFalse, reason: 'badge $badge');
        expect(badge.overlaps(chip), isFalse, reason: 'badge $badge');
      });
    }

    testWidgets('a GIF keeps its frame when play swaps the still for the '
        'full file and back', (tester) async {
      await _pump(tester, [_gif(320, 240)], window: 390, column: 306);
      final still = _frames(tester);
      await tester.tap(find.byIcon(Icons.play_arrow_rounded));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
      expect(_frames(tester), still);
    });
  });

  group('no layout jump', () {
    for (final ref in [_photo(1200, 900), _photo(1000, 4000), _gif(100, 80)]) {
      testWidgets('${ref.contentType} ${ref.width}x${ref.height}: the frame '
          'is final before the image resolves', (tester) async {
        await _pump(tester, [ref], window: 390, column: 306);
        final before = _frames(tester);
        await tester.pumpAndSettle();
        expect(_frames(tester), before);
      });
    }

    testWidgets('the detail view (full image) has the same frame as the '
        'list', (tester) async {
      await _pump(tester, [_photo(1200, 900)], window: 390, column: 306);
      final list = _frames(tester);
      await _pump(
        tester,
        [_photo(1200, 900)],
        window: 390,
        column: 306,
        useFullImage: true,
      );
      expect(_frames(tester), list);
    });
  });

  test('the sizing helpers', () {
    expect(PostMedia.frameAspect(_photo(1, 100)), closeTo(9 / 16, 1e-9));
    expect(PostMedia.frameAspect(_photo(100, 1)), closeTo(3, 1e-9));
    expect(PostMedia.frameAspect(_photo(0, 80)), closeTo(4 / 5, 1e-9));
    expect(
      PostMedia.tileSize(_photo(900, 1600), height: 272),
      Size(272 * 9 / 16, 272),
    );
  });

  group('row height rule (measured on X)', () {
    // A ref of natural aspect [a] (width / height).
    common.MediaRef ref(double a, {int n = 0}) =>
        _photo((a * 10000).round(), 10000, n: n);
    List<common.MediaRef> row(List<double> aspects) => [
      for (var i = 0; i < aspects.length; i++) ref(aspects[i], n: i),
    ];
    double h(List<double> aspects, double c, {bool wide = false}) =>
        PostMedia.rowHeight(row(aspects), column: c, wide: wide);
    const gap = 4.0;

    group('two tiles fill the column (c = 518)', () {
      for (final (aspects, measured) in [
        ([0.75, 0.728], 346.0),
        ([0.75, 0.563], 390.0),
        ([0.565, 0.563], 455.0),
      ]) {
        test('$aspects: H about $measured, widths sum to c - gap', () {
          final media = row(aspects);
          final height = PostMedia.rowHeight(media, column: 518, wide: false);
          // The measured aspects are rounded, so allow a couple of dp.
          expect(height, closeTo(measured, 2.5));
          final widths = [
            for (final m in media) PostMedia.tileSize(m, height: height).width,
          ];
          expect(widths.reduce((a, b) => a + b), closeTo(518 - gap, 0.01));
        });
      }
    });

    group('three or more: 0.591 c / mean of the first two aspects', () {
      for (final c in [518.0, 259.0]) {
        for (final (aspect, fraction) in [
          (0.5625, 1.054),
          (0.513, 1.154),
          (0.667, 0.889),
          (0.8, 0.739),
        ]) {
          test('uniform $aspect at c=$c: ${fraction}c', () {
            final height = h([aspect, aspect, aspect], c);
            expect(height / c, closeTo(fraction, 0.01));
          });
        }
        test('narrow strips hit the cap 1.243c at c=$c', () {
          expect(h([0.1, 0.1, 0.1, 0.1], c), closeTo(1.243 * c, 0.01));
        });
      }

      test('phone c=259: all 9:16 gives 272, strips give 322', () {
        expect(h([9 / 16, 9 / 16, 9 / 16], 259), closeTo(272, 1));
        expect(h([0.05, 0.05, 0.05], 259), closeTo(322, 1));
      });

      test('mixed rows are within 3% of what X showed', () {
        // [0.562, 0.474, ...]: measured 1.125c, rule 1.141c.
        expect(h([0.562, 0.474, 0.6, 0.6], 518) / 518, closeTo(1.125, 0.034));
        // [0.461, 0.561, 0.671, ...]: measured 1.182c, rule 1.157c.
        expect(h([0.461, 0.561, 0.671, 0.6], 518) / 518, closeTo(1.182, 0.036));
      });
    });

    test('tile widths are the height times the tile\'s own aspect', () {
      final media = row([0.5625, 1.0, 16 / 9]);
      final height = PostMedia.rowHeight(media, column: 259, wide: false);
      expect(
        [for (final m in media) PostMedia.tileSize(m, height: height).width],
        [
          closeTo(height * 0.5625, 0.01),
          closeTo(height, 0.01),
          closeTo(height * 16 / 9, 0.01),
        ],
      );
    });

    group('extreme aspects', () {
      test('a wide tile is held at 3:1 for the height and its width', () {
        // [0.5625, 20]: the 20:1 tile counts as 3:1, so the row does not
        // collapse and the two tiles still fill the column.
        final media = [
          _photo(9, 16),
          _photo(2000, 100, n: 1),
        ];
        expect(PostMedia.rowAspect(media[1]), 3);
        final height = PostMedia.rowHeight(media, column: 259, wide: false);
        expect(height, closeTo((259 - 4) / (0.5625 + 3), 0.01));
        final widths = [
          for (final m in media) PostMedia.tileSize(m, height: height).width,
        ];
        expect(widths.reduce((a, b) => a + b), closeTo(255, 0.01));
        expect(widths[1], closeTo(height * 3, 0.01));
      });

      test('three 20:1 tiles keep a tappable row (at least 48 dp)', () {
        final media = [for (var i = 0; i < 3; i++) _photo(2000, 100, n: i)];
        // 0.591 x 259 / 3 = 51: above the floor; a narrow column hits it.
        expect(
          PostMedia.rowHeight(media, column: 259, wide: false),
          closeTo(51.0, 0.1),
        );
        expect(
          PostMedia.rowHeight(media, column: 100, wide: false),
          AppSpacing.minTapTarget,
        );
      });

      test('an absurd ref (beyond 1:200 or 50:1) is treated as unknown', () {
        expect(PostMedia.rowAspect(_photo(1, 1000000)), closeTo(0.8, 1e-9));
        expect(PostMedia.rowAspect(_photo(1000000, 1)), closeTo(0.8, 1e-9));
        final media = [
          _photo(1, 1000000),
          _photo(1000000, 1, n: 1),
          _photo(800, 800, n: 2),
        ];
        final height = PostMedia.rowHeight(media, column: 259, wide: false);
        expect(height.isFinite, isTrue);
        expect(height, closeTo(0.591 * 259 / 0.8, 0.01));
      });

      test('narrow tiles stay uncropped down to 1:200', () {
        expect(PostMedia.rowAspect(_photo(20, 1000)), closeTo(0.02, 1e-9));
        expect(PostMedia.rowAspect(_photo(75, 1000)), closeTo(0.075, 1e-9));
      });
    });

    test('an unknown size counts as 4:5', () {
      expect(PostMedia.rowAspect(_photo(0, 0)), closeTo(0.8, 1e-9));
    });

    test('phones have no 520 cap, wide windows do', () {
      final aspects = [0.5625, 0.5625, 0.5625];
      expect(h(aspects, 900), greaterThan(AppSize.postMediaMaxSingleHeight));
      expect(h(aspects, 900, wide: true), AppSize.postMediaMaxSingleHeight);
    });
  });

  testWidgets('a 20:1 tile in a row is held at 3:1 and center-cropped', (
    tester,
  ) async {
    await _pump(
      tester,
      [_photo(900, 1600, n: 1), _photo(2000, 100, n: 2)],
      window: 390,
      column: 306,
    );
    expect(tester.takeException(), isNull);
    final frames = _frames(tester);
    expect(frames, hasLength(2));
    expect(frames[1].width / frames[1].height, closeTo(3, 0.01));
    final image = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage).last,
    );
    expect(image.fit, BoxFit.cover);
  });

  testWidgets('a 0.075 tile is drawn at its own aspect, uncropped', (
    tester,
  ) async {
    await _pump(
      tester,
      [_photo(75, 1000, n: 1), _photo(75, 1000, n: 2), _photo(800, 800, n: 3)],
      window: 390,
      column: 306,
    );
    final first = _frames(tester).first;
    expect(first.width / first.height, closeTo(0.075, 0.001));
    final image = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage).first,
    );
    // The frame has the picture's own aspect, so cover crops nothing.
    expect(image.fit, BoxFit.cover);
  });
}
