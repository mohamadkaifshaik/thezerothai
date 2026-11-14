import 'dart:typed_data';

import 'package:dzeroth/features/media/domain/image_preflight.dart';
import 'package:dzeroth/features/media/domain/image_processor.dart';
import 'package:dzeroth/features/media/domain/processed_image.dart';
import 'package:dzeroth/features/media/domain/raster_gif_preparer.dart';
import 'package:dzeroth/features/media/domain/raster_image_processor.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/media_fixtures.dart';
import '../../../support/raster_fakes.dart';

/// The web GIF path: the codec (a worker in the browser) makes the still, the
/// upload stays the stripped GIF. Fakes only; no pixels, no isolate.
void main() {
  final gif = realGifBytes(width: 32, height: 24, frames: 3);

  group('RasterGifPreparer', () {
    test(
      'thumbnail and BlurHash come from the codec, the GIF is kept',
      () async {
        final codec = FakeRasterCodec(decoded: (width: 32, height: 24));
        final out = await RasterGifPreparer(codec).prepare(gif);

        expect(out.isGif, isTrue);
        expect(out.thumbContentType, 'image/jpeg');
        expect(out.fullBytes, gif);
        expect((out.width, out.height), (32, 24));
        expect(jpegDims(out.thumbBytes), (width: 32, height: 24));
        expect(out.blurhash, isNotEmpty);
        expect(codec.encodes.single.quality, 70);
        expect(codec.encodes.single.crop, (x: 0, y: 0, width: 32, height: 24));
        expect(codec.closed, 1);
      },
    );

    test('limits are refused before any worker opens', () async {
      final codec = FakeRasterCodec();
      await expectLater(
        RasterGifPreparer(codec).prepare(realGifBytes(width: 1281, height: 2)),
        throwsA(GifRefusedException.tooLarge),
      );
      await expectLater(
        RasterGifPreparer(codec).prepare(Uint8List.fromList([1, 2, 3])),
        throwsA(GifRefusedException.notGif),
      );
      expect(codec.opened, 0);
    });

    test('a first frame of another size is the fallback, not declared', () {
      final codec = FakeRasterCodec(decoded: (width: 10, height: 10));
      expect(
        RasterGifPreparer(codec).prepare(gif),
        throwsA(isA<RasterUnavailableException>()),
      );
    });
  });

  group('FallbackGifPreparer', () {
    test('an unavailable worker falls back, permanently for a capability '
        'failure', () async {
      final codec = FakeRasterCodec(unavailable: true);
      final fallback = _CountingPreparer();
      final reasons = <Object>[];
      final preparer = FallbackGifPreparer(
        primary: RasterGifPreparer(codec),
        fallback: fallback,
        onFallback: reasons.add,
      );

      await preparer.prepare(gif);
      await preparer.prepare(gif);

      expect(fallback.calls, 2);
      expect(preparer.usingFallback, isTrue);
      expect(reasons, hasLength(1), reason: 'the broken worker is not retried');
    });

    test('a refused GIF is an answer, never retried on the fallback', () {
      final fallback = _CountingPreparer();
      final preparer = FallbackGifPreparer(
        primary: RasterGifPreparer(FakeRasterCodec()),
        fallback: fallback,
      );
      expect(
        preparer.prepare(realGifBytes(width: 2, height: 2, frames: 301)),
        throwsA(GifRefusedException.tooLong),
      );
      expect(fallback.calls, 0);
    });

    test(
      'a browser decode refusal goes to package:image for that file',
      () async {
        final fallback = _CountingPreparer();
        final preparer = FallbackGifPreparer(
          primary: RasterGifPreparer(
            FakeRasterCodec(
              decoded: (width: 32, height: 24),
              decodeFails: true,
            ),
          ),
          fallback: fallback,
        );
        await preparer.prepare(gif);
        expect(fallback.calls, 1);
        expect(preparer.usingFallback, isFalse);
      },
    );
  });
}

class _CountingPreparer implements GifPreparer {
  int calls = 0;

  @override
  Future<ProcessedImage> prepare(Uint8List bytes) async {
    calls++;
    return prepareGifSync(bytes);
  }
}
