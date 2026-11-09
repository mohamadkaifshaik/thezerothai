import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/shared/widgets/post/alt_text_chip.dart';
import 'package:dzeroth/shared/widgets/post/gif_badge.dart';
import 'package:dzeroth/shared/widgets/post/post_media.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The frame a post's media gets is laid out from the stored width/height
/// (server-verified, Task 13) before any byte loads, clamped for very tall
/// and very wide images, and a small GIF is not blown up past twice its size.

const _column = 360.0;

common.MediaRef _photo(int w, int h) => common.MediaRef(
  url: 'https://cdn.example/m/p.jpg',
  thumbUrl: 'https://cdn.example/m/p_t.jpg',
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

Widget _host(Widget child, {TextDirection direction = TextDirection.ltr}) =>
    MaterialApp(
      theme: appDarkTheme,
      home: Directionality(
        textDirection: direction,
        child: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: _column,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [child],
              ),
            ),
          ),
        ),
      ),
    );

Rect _frame(WidgetTester tester) => tester.getRect(find.byType(AspectRatio));

void main() {
  void swallowImageErrors(WidgetTester tester) {
    // The test binding cannot download; the error widget shows instead.
    addTearDown(() => tester.takeException());
  }

  group('single item frame from the stored size', () {
    final cases = <(String, common.MediaRef, Size)>[
      // Landscape photo: its own 4:3 across the column.
      ('landscape photo', _photo(1200, 900), const Size(_column, 270)),
      // Very wide (4:1) is capped at 16:9 and letterboxed.
      ('very wide photo', _photo(4000, 1000), const Size(_column, 202.5)),
      // Very tall (1:4) is capped at 4:5 and letterboxed.
      ('very tall photo', _photo(1000, 4000), const Size(_column, 450)),
      // Huge sizes are the same shapes, not larger frames.
      ('huge portrait GIF', _gif(1000, 1280), const Size(_column, 450)),
      ('huge landscape GIF', _gif(1280, 640), const Size(_column, 202.5)),
      // A small GIF is held to twice its own size, start-aligned.
      ('small GIF', _gif(160, 120), const Size(320, 240)),
      ('small portrait GIF', _gif(120, 150), const Size(240, 300)),
      // A tiny GIF gets the frame floor for its controls.
      ('tiny GIF', _gif(10, 10), const Size(200, 200)),
      ('tiny wide GIF', _gif(40, 10), const Size(355.56, 200)),
      // Unknown size (older refs): 16:9 across the column, as before.
      ('photo without a size', _photo(0, 0), const Size(_column, 202.5)),
      ('GIF without a size', _gif(0, 0), const Size(_column, 202.5)),
    ];
    for (final (name, ref, want) in cases) {
      testWidgets(
        '$name ${ref.width}x${ref.height} -> '
        '${want.width.toStringAsFixed(1)}x${want.height.toStringAsFixed(1)}',
        (tester) async {
          swallowImageErrors(tester);
          await tester.pumpWidget(_host(PostMedia(media: [ref])));
          expect(tester.takeException(), isNull);
          final frame = _frame(tester);
          expect(frame.width, closeTo(want.width, 0.5));
          expect(frame.height, closeTo(want.height, 0.5));
          // Start-aligned with the column (LTR).
          expect(frame.left, closeTo(0, 0.5));
        },
      );
    }

    testWidgets('a capped GIF sits at the start edge in RTL', (tester) async {
      swallowImageErrors(tester);
      await tester.pumpWidget(
        _host(PostMedia(media: [_gif(160, 120)]), direction: TextDirection.rtl),
      );
      final frame = _frame(tester);
      expect(frame.width, closeTo(320, 0.5));
      expect(frame.right, closeTo(_column, 0.5));
    });

    testWidgets('a tiny GIF\'s pixels stay within twice its size inside the '
        'floor frame', (tester) async {
      swallowImageErrors(tester);
      await tester.pumpWidget(_host(PostMedia(media: [_gif(10, 10)])));
      final pixels = tester.getSize(find.byKey(const ValueKey('gif-pixels')));
      expect(pixels.width, lessThanOrEqualTo(20));
      expect(pixels.height, lessThanOrEqualTo(20));
      expect(_frame(tester).size, const Size(200, 200));
    });

    for (final direction in TextDirection.values) {
      testWidgets('a tiny GIF with ALT text at text x2 (${direction.name}) '
          'fits its controls in the floor frame', (tester) async {
        swallowImageErrors(tester);
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: _host(
              PostMedia(media: [_gif(10, 10)..altText = 'a cat']),
              direction: direction,
            ),
          ),
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
        final frame = _frame(tester);
        expect(frame.contains(play.topLeft), isTrue);
        expect(frame.contains(play.bottomRight - const Offset(1, 1)), isTrue);
        // The ALT chip's 48dp target does not cover the play control.
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
        expect(frame.contains(badge.topLeft), isTrue);
        expect(badge.overlaps(play), isFalse, reason: 'badge $badge');
        expect(badge.overlaps(chip), isFalse, reason: 'badge $badge');
      });
    }

    testWidgets('the GIF frame helper matches the laid-out frame', (
      tester,
    ) async {
      expect(PostMedia.gifMaxFrameWidth(_gif(160, 120)), 320);
      expect(
        PostMedia.gifMaxFrameWidth(_gif(10, 10)),
        PostMedia.minGifFrameEdge,
      );
      expect(PostMedia.gifMaxFrameWidth(_gif(0, 80)), isNull);
      expect(PostMedia.frameAspect(_photo(1, 100)), closeTo(4 / 5, 1e-9));
      expect(PostMedia.frameAspect(_photo(100, 1)), closeTo(16 / 9, 1e-9));
    });
  });

  group('no layout jump', () {
    for (final ref in [_photo(1200, 900), _photo(1000, 4000), _gif(100, 80)]) {
      testWidgets('${ref.contentType} ${ref.width}x${ref.height}: the frame '
          'is final before the image resolves', (tester) async {
        swallowImageErrors(tester);
        await tester.pumpWidget(_host(PostMedia(media: [ref])));
        final before = _frame(tester);
        // The binding cannot download: the image resolves to its error
        // widget, the same thing that happens to a slow or failed load.
        await tester.pumpAndSettle();
        expect(_frame(tester), before);
      });
    }

    testWidgets('the detail view (full image) has the same frame as the list', (
      tester,
    ) async {
      swallowImageErrors(tester);
      await tester.pumpWidget(_host(PostMedia(media: [_photo(1200, 900)])));
      final list = _frame(tester);
      await tester.pumpWidget(
        _host(PostMedia(media: [_photo(1200, 900)], useFullImage: true)),
      );
      expect(_frame(tester), list);
    });

    testWidgets('a GIF keeps its frame when play swaps the still for the '
        'full file and back', (tester) async {
      swallowImageErrors(tester);
      await tester.pumpWidget(_host(PostMedia(media: [_gif(320, 240)])));
      final still = _frame(tester);
      await tester.tap(find.byIcon(Icons.play_arrow_rounded));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
      expect(_frame(tester), still);
      await tester.tap(find.byType(AspectRatio));
      await tester.pumpAndSettle();
      expect(_frame(tester), still);
    });

    testWidgets('the frame does not depend on the still having a URL', (
      tester,
    ) async {
      swallowImageErrors(tester);
      await tester.pumpWidget(_host(PostMedia(media: [_gif(100, 80)])));
      final withThumb = _frame(tester);
      await tester.pumpWidget(
        _host(PostMedia(media: [_gif(100, 80)..thumbUrl = ''])),
      );
      expect(_frame(tester), withThumb);
    });
  });

  testWidgets('several items keep the 16:9 pager across the column, GIF '
      'cap or not', (tester) async {
    swallowImageErrors(tester);
    await tester.pumpWidget(
      _host(PostMedia(media: [_photo(10, 10), _photo(1000, 4000)])),
    );
    final frame = _frame(tester);
    expect(frame.width, closeTo(_column, 0.5));
    expect(frame.height, closeTo(_column * 9 / 16, 0.5));
  });
}
