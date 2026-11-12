import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dzeroth/features/media/domain/image_preflight.dart';
import 'package:dzeroth/features/media/domain/image_processor.dart';
import 'package:dzeroth/features/media/domain/processed_image.dart';
import 'package:dzeroth/features/media/domain/processing_cancellation.dart';
import 'package:dzeroth/features/media/domain/raster_image_processor.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/media_fixtures.dart';
import '../../../support/raster_fakes.dart';

void main() {
  final input = fakeJpeg(4000, 3000, padding: 64);

  group('RasterImageProcessor', () {
    test('declares exactly the size it encoded, md5 of the bytes', () async {
      final codec = FakeRasterCodec();
      final out = await RasterImageProcessor(codec)
          .process(input, ImagePurpose.post);

      expect((out.width, out.height), (1600, 1200));
      expect(jpegDims(out.fullBytes), (width: 1600, height: 1200));
      expect(jpegDims(out.thumbBytes), (width: 400, height: 300));
      expect(out.fullMd5, base64.encode(md5.convert(out.fullBytes).bytes));
      expect(out.thumbMd5, base64.encode(md5.convert(out.thumbBytes).bytes));
      expect(out.blurhash, isNotEmpty);
      expect(out.contentType, 'image/jpeg');
      // Full at quality 80, thumb at 70, both from the whole photo.
      expect([for (final e in codec.encodes) e.quality], [80, 70]);
      expect(codec.encodes.first.crop, (x: 0, y: 0, width: 4000, height: 3000));
      expect(codec.rgbaCalls.single, (width: 32, height: 24));
      expect(codec.closed, 1);
    });

    test('steps quality down, then shrinks, until under the cap', () async {
      // Over the cap at 1600 px whatever the quality; fits at 1200 x 900 / 60.
      final codec = FakeRasterCodec(
        sizeOf: (w, h, q) =>
            w <=
                kPostThumbEdge // the thumbnail always fits
            ? 100
            : (w > 1200 || q > 60 ? kMaxFullBytes + 1 : kMaxFullBytes),
      );
      final out = await RasterImageProcessor(codec)
          .process(input, ImagePurpose.post);
      expect((out.width, out.height), (1200, 900));
      expect(out.fullBytes.length, kMaxFullBytes);
      final full = codec.encodes.takeWhile((e) => e.width >= 1200).toList();
      expect(
        [for (final e in full) (e.width, e.quality)],
        [
          (1600, 80), (1600, 70), (1600, 60), (1600, 50), (1600, 40), //
          (1200, 80), (1200, 70), (1200, 60),
        ],
      );
    });

    test('an image that never fits is refused', () async {
      final codec = FakeRasterCodec(sizeOf: (_, _, _) => kMaxFullBytes + 1);
      await expectLater(
        RasterImageProcessor(codec).process(input, ImagePurpose.post),
        throwsA(isA<UnsupportedImageException>()),
      );
      expect(codec.encodes, hasLength(30));
      expect(codec.closed, 1);
    });

    test('avatar crops and sizes like processImageSync', () async {
      final avatar = FakeRasterCodec(decoded: (width: 900, height: 500));
      final a = await RasterImageProcessor(avatar)
          .process(input, ImagePurpose.avatar);
      expect((a.width, a.height), (400, 400));
      expect(avatar.encodes.first.crop, (
        x: 200,
        y: 0,
        width: 500,
        height: 500,
      ));
      expect(jpegDims(a.thumbBytes), (width: 96, height: 96));
    });

    test('a JPEG whose SOF differs from the asked size is never declared '
        '(the contract broke: unavailable)', () async {
      final codec = FakeRasterCodec(lieBy: 1);
      await expectLater(
        RasterImageProcessor(codec).process(input, ImagePurpose.post),
        throwsA(isA<RasterUnavailableException>()),
      );
      expect(codec.closed, 1);
    });

    test('preflight runs before any worker is opened', () async {
      final codec = FakeRasterCodec();
      await expectLater(
        RasterImageProcessor(codec)
            .process(fakeJpeg(12000, 9000), ImagePurpose.post),
        throwsA(same(tooLargeSource)),
      );
      expect(codec.opened, 0);
    });

    test('the decoded size is bounded too (a header it could not read)', () {
      final codec = FakeRasterCodec(decoded: (width: 10000, height: 10000));
      expect(
        RasterImageProcessor(codec)
            .process(Uint8List.fromList([1, 2, 3, 4]), ImagePurpose.post),
        throwsA(same(tooLargeSource)),
      );
    });

    test('an undecodable file is unsupported', () {
      final codec = FakeRasterCodec(decodeFails: true);
      expect(
        RasterImageProcessor(codec).process(input, ImagePurpose.post),
        throwsA(isA<UnsupportedImageException>()),
      );
    });

    test('cancelling mid-decode closes the session at once', () async {
      final codec = FakeRasterCodec(holdDecode: true);
      final cancel = ProcessingCancellation();
      final job = RasterImageProcessor(codec)
          .process(input, ImagePurpose.post, cancellation: cancel);
      await codec.decodeStarted.future;
      cancel.cancel();
      await expectLater(job, throwsA(isA<ImageProcessingCancelled>()));
      expect(codec.closed, 1);
      expect(codec.encodes, isEmpty);
    });

    test('an already cancelled job opens nothing', () async {
      final codec = FakeRasterCodec();
      final cancel = ProcessingCancellation()..cancel();
      await expectLater(
        RasterImageProcessor(codec)
            .process(input, ImagePurpose.post, cancellation: cancel),
        throwsA(isA<ImageProcessingCancelled>()),
      );
      expect(codec.opened, 0);
    });
  });

  group('FallbackImageProcessor', () {
    test('uses the worker while it works', () async {
      final fallback = FakeImageProcessor();
      final p = FallbackImageProcessor(
        primary: RasterImageProcessor(FakeRasterCodec()),
        fallback: fallback,
      );
      await p.process(input, ImagePurpose.post);
      expect(fallback.purposes, isEmpty);
      expect(p.usingFallback, isFalse);
    });

    test('switches to package:image for good when the worker is '
        'unavailable', () async {
      final fallback = FakeImageProcessor();
      final reasons = <Object>[];
      final p = FallbackImageProcessor(
        primary: RasterImageProcessor(FakeRasterCodec(unavailable: true)),
        fallback: fallback,
        onFallback: reasons.add,
      );
      await p.process(imageBytes('a'), ImagePurpose.post);
      await p.process(imageBytes('b'), ImagePurpose.avatar);
      expect(fallback.purposes, [ImagePurpose.post, ImagePurpose.avatar]);
      expect(reasons, hasLength(1));
      expect(p.usingFallback, isTrue);
    });

    test('falls back when the worker breaks the size contract', () async {
      final fallback = FakeImageProcessor();
      final p = FallbackImageProcessor(
        primary: RasterImageProcessor(FakeRasterCodec(lieBy: 2)),
        fallback: fallback,
      );
      await p.process(input, ImagePurpose.post);
      expect(fallback.purposes, [ImagePurpose.post]);
    });

    test('an unsupported file or a cancellation is an answer, not a '
        'fallback', () async {
      final fallback = FakeImageProcessor();
      final p = FallbackImageProcessor(
        primary: RasterImageProcessor(FakeRasterCodec(decodeFails: true)),
        fallback: fallback,
      );
      await expectLater(
        p.process(input, ImagePurpose.post),
        throwsA(isA<UnsupportedImageException>()),
      );
      await expectLater(
        p.process(
          input,
          ImagePurpose.post,
          cancellation: ProcessingCancellation()..cancel(),
        ),
        throwsA(isA<ImageProcessingCancelled>()),
      );
      expect(fallback.purposes, isEmpty);
    });
  });

  group('IsolateImageProcessor', () {
    test('runs the preflight before decoding', () {
      expect(
        const IsolateImageProcessor().process(
          fakeJpeg(12000, 9000),
          ImagePurpose.post,
        ),
        throwsA(same(tooLargeSource)),
      );
    });

    test('a cancelled job never starts', () {
      expect(
        const IsolateImageProcessor().process(
          fakeJpeg(100, 100),
          ImagePurpose.post,
          cancellation: ProcessingCancellation()..cancel(),
        ),
        throwsA(isA<ImageProcessingCancelled>()),
      );
    });
  });

  group('ProcessingCancellation.guard', () {
    test('passes the result through', () async {
      expect(await ProcessingCancellation().guard(Future.value(3)), 3);
    });

    test('stops waiting on cancel; a later error of the work is '
        'ignored', () async {
      final work = Completer<int>();
      final cancel = ProcessingCancellation();
      final guarded = cancel.guard(work.future);
      cancel.cancel();
      await expectLater(guarded, throwsA(isA<ImageProcessingCancelled>()));
      work.completeError(StateError('late'));
    });
  });

  test('md5Yielding equals md5 over several slices', () async {
    final bytes = Uint8List.fromList(List.generate(700 * 1024, (i) => i % 251));
    expect(await md5Yielding(bytes), base64.encode(md5.convert(bytes).bytes));
  });
}
