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
            closeTo(height * PostMedia.frameAspect(media[i]), 0.01),
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

  group('row height rule at column 259', () {
    double h(List<common.MediaRef> m, {bool wide = false}) =>
        PostMedia.rowHeight(m, column: 259, wide: wide);

    test('three 9:16 tiles: height 272, tiles 152 wide', () {
      final media = [for (var i = 0; i < 3; i++) _photo(900, 1600, n: i)];
      expect(h(media), closeTo(272, 1));
      expect(
        PostMedia.tileSize(media.first, height: h(media)).width,
        closeTo(152, 1),
      );
    });

    test('two 9:16 tiles give the same height as three', () {
      expect(h([_photo(900, 1600), _photo(900, 1600)]), closeTo(272, 1));
    });

    test('DIVERGES from X (measured 305, tiles 140/171/204): aspects '
        '0.46/0.56/0.67 give 255 with the specified rule', () {
      final media = [
        _photo(460, 1000, n: 1),
        _photo(560, 1000, n: 2),
        _photo(670, 1000, n: 3),
      ];
      // The rule clamps each tile to 9:16 first: mean 0.598, 0.59 x 259 /
      // 0.598 = 255.4. X shows 305, so X does not follow this rule here.
      expect(h(media), closeTo(255.4, 0.1));
      expect(
        [for (final m in media) PostMedia.tileSize(m, height: h(media)).width],
        [closeTo(143.7, 0.1), closeTo(143.7, 0.1), closeTo(171.1, 0.1)],
      );
    });

    test('DIVERGES from X (measured 323, the cap): very narrow strips give '
        '272 because each tile is clamped to 9:16 first', () {
      expect(h([_photo(300, 1000), _photo(300, 1000)]), closeTo(271.7, 0.1));
      expect(h([_photo(300, 1000), _photo(300, 1000)]), lessThan(323));
    });

    test('landscape-only rows are floored at half the column', () {
      expect(h([_photo(3000, 1000), _photo(3000, 1000)]), closeTo(129.5, 0.01));
    });

    test('wide windows cap the row at the single-frame maximum', () {
      final media = [_photo(900, 1600), _photo(900, 1600)];
      expect(
        PostMedia.rowHeight(media, column: 900, wide: true),
        AppSize.postMediaMaxSingleHeight,
      );
    });

    test('per-tile widths follow each aspect', () {
      final media = [_photo(900, 1600), _photo(800, 800), _photo(1600, 900)];
      final height = h(media);
      expect(
        [for (final m in media) PostMedia.tileSize(m, height: height).width],
        [
          closeTo(height * 9 / 16, 0.01),
          closeTo(height, 0.01),
          closeTo(height * 16 / 9, 0.01),
        ],
      );
    });
  });
}
