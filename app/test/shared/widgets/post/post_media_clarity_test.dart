import 'package:cached_network_image/cached_network_image.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/shared/widgets/post/post_media.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/theme_harness.dart';

/// Photo clarity: the feed shows `thumbUrl` unless it has too few pixels for
/// the frame, then `url` with the thumbnail as placeholder; images decode at
/// the physical size the frame needs.

common.MediaRef _ref(int w, int h, {String thumb = 'https://cdn/t.jpg'}) =>
    common.MediaRef(
      url: 'https://cdn/full.jpg',
      thumbUrl: thumb,
      width: w,
      height: h,
      contentType: 'image/jpeg',
    );

Future<void> _pump(
  WidgetTester tester,
  common.MediaRef ref, {
  double dpr = 1,
  double column = 306,
}) async {
  addTearDown(() => tester.takeException());
  await pumpThemed(
    tester,
    Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(devicePixelRatio: dpr),
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: column,
            child: PostMedia(media: [ref]),
          ),
        ),
      ),
    ),
    size: const Size(390, 900),
  );
}

List<String> _urls(WidgetTester tester) => [
  for (final w in tester.widgetList<CachedNetworkImage>(
    find.byType(CachedNetworkImage),
  ))
    w.imageUrl,
];

void main() {
  group('thumbEdgeFor', () {
    test('infers the thumb edge from the stored full edge', () {
      expect(PostMedia.thumbEdgeFor(300), 300);
      expect(PostMedia.thumbEdgeFor(1600), 400); // legacy
      expect(PostMedia.thumbEdgeFor(1601), 1080);
      expect(PostMedia.thumbEdgeFor(2048), 1080);
    });
  });

  group('thumbSuffices', () {
    test('a legacy 400 px thumb is too small for almost any frame', () {
      expect(PostMedia.thumbSuffices(_ref(1600, 1200), 306), isTrue);
      expect(PostMedia.thumbSuffices(_ref(1600, 1200), 612), isFalse);
    });

    test('a 1080 px thumb covers a phone column at 3x, not wider', () {
      final ref = _ref(2048, 1536);
      expect(PostMedia.thumbSuffices(ref, 306 * 3), isTrue);
      expect(PostMedia.thumbSuffices(ref, 1080), isTrue);
      expect(PostMedia.thumbSuffices(ref, 1081), isFalse);
    });

    test('portrait thumbs are narrower than 1080 across', () {
      final ref = _ref(1536, 2048); // thumb 810 x 1080
      expect(PostMedia.thumbSuffices(ref, 810), isTrue);
      expect(PostMedia.thumbSuffices(ref, 811), isFalse);
    });

    test('a tiny photo has a thumb as big as the full image', () {
      expect(PostMedia.thumbSuffices(_ref(300, 200), 900), isTrue);
    });

    test('an unknown size is not trusted', () {
      expect(PostMedia.thumbSuffices(_ref(0, 0), 10), isFalse);
    });
  });

  test('neededPixels counts the side crop of a panorama', () {
    // A 2:1 image in a square-ish frame is drawn wider than the frame.
    expect(PostMedia.neededPixels(const Size(300, 150), 2, 2), 600);
    expect(PostMedia.neededPixels(const Size(300, 300), 2, 1), 600);
    expect(PostMedia.neededPixels(const Size(300, 375), 0.8, 1), 300);
  });

  testWidgets('a new photo at 3x keeps the thumbnail', (tester) async {
    await _pump(tester, _ref(2048, 1536), dpr: 3);
    expect(_urls(tester), ['https://cdn/t.jpg']);
    final image = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
    // Never decoded below the physical pixels of the frame.
    expect(image.memCacheWidth, greaterThanOrEqualTo(306 * 3));
  });

  testWidgets('a legacy photo at 3x loads the full file, thumb underneath', (
    tester,
  ) async {
    await _pump(tester, _ref(1600, 1200), dpr: 3);
    expect(_urls(tester).first, 'https://cdn/full.jpg');
    final image = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage).first,
    );
    expect(image.memCacheWidth, greaterThanOrEqualTo(306 * 3));
    // The placeholder is the thumbnail.
    final holder = image.placeholder!(
      tester.element(find.byType(PostMedia)),
      '',
    );
    expect(holder, isA<ColoredBox>());
    final thumb = (holder as ColoredBox).child;
    expect(thumb, isA<CachedNetworkImage>());
    expect((thumb! as CachedNetworkImage).imageUrl, 'https://cdn/t.jpg');
  });

  testWidgets('a panorama decodes at the width its crop needs', (tester) async {
    // 2:1 stored, frame is 2:1 at most, so fits; use 3:1 -> clamped to 2:1
    // frame, image drawn 1.5x wider than the frame.
    await _pump(tester, _ref(3000, 1000), dpr: 2);
    final image = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage).first,
    );
    expect(image.memCacheWidth, greaterThanOrEqualTo(306 * 2 * 1.5));
  });

  testWidgets('the detail view decodes a panorama at its crop width too', (
    tester,
  ) async {
    addTearDown(() => tester.takeException());
    await pumpThemed(
      tester,
      Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(devicePixelRatio: 2),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 306,
              child: PostMedia(media: [_ref(3000, 1000)], useFullImage: true),
            ),
          ),
        ),
      ),
      size: const Size(390, 900),
    );
    final image = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage).first,
    );
    expect(image.imageUrl, 'https://cdn/full.jpg');
    expect(image.memCacheWidth, greaterThanOrEqualTo(306 * 2 * 1.5));
  });

  testWidgets('a ref with no thumbnail never loads the full image', (
    tester,
  ) async {
    await _pump(tester, _ref(1600, 1200, thumb: ''), dpr: 3);
    expect(find.byType(CachedNetworkImage), findsNothing);
  });
}
