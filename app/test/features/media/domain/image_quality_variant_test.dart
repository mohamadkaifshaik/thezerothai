import 'dart:typed_data';

import 'package:dzeroth/features/media/domain/image_preflight.dart';
import 'package:dzeroth/features/media/domain/image_processor.dart';
import 'package:dzeroth/features/media/domain/image_size_plan.dart';
import 'package:dzeroth/features/media/domain/processed_image.dart';
import 'package:dzeroth/features/media/domain/processing_cancellation.dart';
import 'package:dzeroth/features/media/domain/quality_aware_image_processor.dart';
import 'package:dzeroth/features/media/domain/raster_image_processor.dart';
import 'package:dzeroth/shared/widgets/post/post_media.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../../../support/raster_fakes.dart';

/// The standard (lighter) post photo size that Settings > Data usage picks
/// when high-quality uploads are not allowed on the connection.

Uint8List _jpg(int w, int h) => img.encodeJpg(img.Image(width: w, height: h));

class _Recording implements ImageProcessor {
  final List<ImageQuality?> seen = [];

  @override
  Future<ProcessedImage> process(
    Uint8List bytes,
    ImagePurpose purpose, {
    ProcessingCancellation? cancellation,
    ImageQuality? quality,
  }) async {
    seen.add(quality);
    throw UnimplementedError();
  }
}

void main() {
  test('standard post spec: 1800 full at q80, thumb 1080 at q75', () {
    final standard = PurposeSpec.of(
      ImagePurpose.post,
      quality: ImageQuality.standard,
    );
    expect((standard.fullEdge, standard.thumbEdge), (1800, 1080));
    expect((standard.fullQuality, standard.thumbQuality), (80, 75));
    final high = PurposeSpec.of(ImagePurpose.post);
    expect((high.fullEdge, high.fullQuality), (2048, 88));
  });

  test('avatars ignore the quality', () {
    final a = PurposeSpec.of(
      ImagePurpose.avatar,
      quality: ImageQuality.standard,
    );
    expect((a.fullEdge, a.thumbEdge), (400, 96));
    expect((a.fullQuality, a.thumbQuality), (80, 70));
  });

  test('the standard ladder starts at q80 and steps down to 40', () {
    final attempts = encodeAttempts(4000, 3000, 1600, quality: 80).toList();
    expect(attempts.first, (width: 1600, height: 1200, quality: 80));
    expect([for (final a in attempts.take(5)) a.quality], [80, 70, 60, 50, 40]);
  });

  test('processImageSync honours the variant (isolate path)', () {
    final source = _jpg(3000, 2000);
    final high = processImageSync(source, ImagePurpose.post);
    final standard = processImageSync(
      source,
      ImagePurpose.post,
      quality: ImageQuality.standard,
    );
    expect((high.width, high.height), (2048, 1365));
    expect((standard.width, standard.height), (1800, 1200));
    expect(jpegDims(standard.fullBytes), (width: 1800, height: 1200));
    expect(jpegDims(standard.thumbBytes), (width: 1080, height: 720));
  });

  test('RasterImageProcessor (web worker path) encodes 1800 at q80', () async {
    final codec = FakeRasterCodec();
    final out = await RasterImageProcessor(
      codec,
    ).process(_jpg(40, 30), ImagePurpose.post, quality: ImageQuality.standard);
    expect((out.width, out.height), (1800, 1350));
    expect([for (final e in codec.encodes) e.quality], [80, 75]);
  });

  test('the quality is chosen when the photo is processed', () async {
    final inner = _Recording();
    var next = ImageQuality.high;
    final processor = QualityAwareImageProcessor(inner, () => next);
    Future<void> run([ImageQuality? q]) => processor
        .process(Uint8List(1), ImagePurpose.post, quality: q)
        .then((_) {}, onError: (_) {});
    await run();
    next = ImageQuality.standard;
    await run();
    await run(ImageQuality.high); // a caller's own choice wins
    expect(inner.seen, [
      ImageQuality.high,
      ImageQuality.standard,
      ImageQuality.high,
    ]);
  });

  test('a standard upload is read by the feed as having a 1080 px thumb', () {
    // The feed infers the thumbnail from the full size: 1600 px or less is a
    // legacy 400 px thumb, which would make it load the full file.
    expect(kPostStandardFullEdge, greaterThan(1600));
    expect(PostMedia.thumbEdgeFor(kPostStandardFullEdge), kPostThumbEdge);
  });
}
