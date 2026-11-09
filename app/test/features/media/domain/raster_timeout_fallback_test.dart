import 'package:dzeroth/features/media/domain/image_processor.dart';
import 'package:dzeroth/features/media/domain/processing_cancellation.dart';
import 'package:dzeroth/features/media/domain/raster_image_processor.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/media_fixtures.dart';
import '../../../support/raster_fakes.dart';

/// Fix round 1: a step that never answers times out and closes the worker;
/// only capability failures and size-contract breaches switch to
/// package:image for good; a cancel that closes the worker is a cancel.
void main() {
  final input = fakeJpeg(4000, 3000, padding: 64);

  test('a step that never answers times out after kRasterStepTimeout, closes '
      'the worker, and is not permanent', () {
    fakeAsync((async) {
      final codec = FakeRasterCodec(hangSessions: 1);
      Object? error;
      RasterImageProcessor(codec)
          .process(input, ImagePurpose.post)
          .then<void>((_) {}, onError: (Object e) => error = e);

      async.elapse(kRasterStepTimeout - const Duration(seconds: 1));
      expect(error, isNull);
      async.elapse(const Duration(seconds: 2));
      expect(
        error,
        isA<RasterUnavailableException>().having(
          (e) => e.permanent,
          'permanent',
          isFalse,
        ),
      );
      expect(codec.closed, 1);
    });
  });

  test('the step timeout is injectable', () {
    fakeAsync((async) {
      final codec = FakeRasterCodec(hangSessions: 1);
      Object? error;
      RasterImageProcessor(codec, stepTimeout: const Duration(seconds: 2))
          .process(input, ImagePurpose.post)
          .then<void>((_) {}, onError: (Object e) => error = e);
      async.elapse(const Duration(seconds: 3));
      expect(error, isA<RasterUnavailableException>());
    });
  });

  test('a timeout falls back for that image only; the next image gets a '
      'fresh worker', () {
    fakeAsync((async) {
      final codec = FakeRasterCodec(hangSessions: 1);
      final fallback = FakeImageProcessor();
      final p = FallbackImageProcessor(
        primary: RasterImageProcessor(codec),
        fallback: fallback,
      );
      String? first;
      String? second;
      p
          .process(imageBytes('a'), ImagePurpose.post)
          .then((out) => first = out.fullMd5);
      async.elapse(kRasterStepTimeout + const Duration(seconds: 1));
      expect(first, 'full-a'); // the package:image fallback
      expect(p.usingFallback, isFalse);

      p
          .process(imageBytes('b'), ImagePurpose.post)
          .then((out) => second = out.fullMd5);
      async.flushMicrotasks();
      expect(codec.opened, 2);
      expect(second, isNot('full-b')); // made by the worker
      expect(second, isNotNull);
      expect(fallback.purposes, [ImagePurpose.post]);
    });
  });

  test('a size-contract breach switches to the fallback for good', () async {
    final codec = FakeRasterCodec(lieBy: 1);
    final fallback = FakeImageProcessor();
    final p = FallbackImageProcessor(
      primary: RasterImageProcessor(codec),
      fallback: fallback,
    );
    await p.process(input, ImagePurpose.post);
    await p.process(input, ImagePurpose.post);
    expect(p.usingFallback, isTrue);
    expect(codec.opened, 1);
    expect(fallback.purposes, hasLength(2));
  });

  test('cancel vs close race: the closed worker fails its pending decode, and '
      'that is a cancellation, never a fallback', () async {
    final codec = FakeRasterCodec(holdDecode: true);
    final fallback = FakeImageProcessor();
    final p = FallbackImageProcessor(
      primary: RasterImageProcessor(codec),
      fallback: fallback,
    );
    final cancel = ProcessingCancellation();
    final job = p.process(input, ImagePurpose.post, cancellation: cancel);
    await codec.decodeStarted.future;
    cancel.cancel();
    await expectLater(job, throwsA(isA<ImageProcessingCancelled>()));
    expect(fallback.purposes, isEmpty);
    expect(p.usingFallback, isFalse);
    expect(codec.closed, 1);
  });
}
