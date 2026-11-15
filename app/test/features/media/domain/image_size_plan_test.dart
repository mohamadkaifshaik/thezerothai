import 'dart:typed_data';

import 'package:dzeroth/features/media/domain/image_preflight.dart';
import 'package:dzeroth/features/media/domain/image_processor.dart';
import 'package:dzeroth/features/media/domain/image_size_plan.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

Uint8List _jpg(int w, int h) => img.encodeJpg(img.Image(width: w, height: h));

void main() {
  group('cropFor', () {
    test('post keeps the whole image', () {
      expect(cropFor(ImagePurpose.post, 300, 200), (
        x: 0,
        y: 0,
        width: 300,
        height: 200,
      ));
    });
    test('avatar is the centered square', () {
      expect(cropFor(ImagePurpose.avatar, 300, 200), (
        x: 50,
        y: 0,
        width: 200,
        height: 200,
      ));
    });
  });

  group('fitWithin', () {
    final cases = <String, (int, int, int, int, int)>{
      'landscape down': (4000, 3000, 2048, 2048, 1536),
      'portrait down': (3000, 4000, 2048, 1536, 2048),
      'square down': (2000, 2000, 400, 400, 400),
      'never upscales': (800, 600, 2048, 800, 600),
      'thin strip keeps 1 px': (5000, 1, 2048, 2048, 1),
      'rounding 1001 x 777': (1001, 777, 400, 400, 310),
    };
    cases.forEach((name, c) {
      test(name, () {
        expect(fitWithin(c.$1, c.$2, c.$3), (width: c.$4, height: c.$5));
      });
    });
  });

  test(
    'post sizes: 2048 full at q88, 1080 thumb at q75; avatars unchanged',
    () {
      expect((kPostFullEdge, kPostThumbEdge), (2048, 1080));
      final post = PurposeSpec.of(ImagePurpose.post);
      expect((post.fullEdge, post.thumbEdge), (2048, 1080));
      expect((post.fullQuality, post.thumbQuality), (88, 75));
      // The server's caps still apply (the ladder fits them).
      expect(
        (post.maxFullBytes, post.maxThumbBytes),
        (2 * 1024 * 1024, 256 * 1024),
      );
      final avatar = PurposeSpec.of(ImagePurpose.avatar);
      expect((avatar.fullEdge, avatar.thumbEdge), (400, 96));
      expect((avatar.fullQuality, avatar.thumbQuality), (80, 70));
    },
  );

  test('the ladder: quality 88..48, then 75 % shrinks, six sizes', () {
    final attempts = encodeAttempts(4000, 3000, 2048, quality: 88).toList();
    expect(attempts, hasLength(6 * 5));
    expect(attempts.first, (width: 2048, height: 1536, quality: 88));
    expect(attempts[4], (width: 2048, height: 1536, quality: 48));
    expect(attempts[5], (width: 1536, height: 1152, quality: 88));
    expect(attempts.last.quality, 48);
  });

  test('the thumb ladder starts at q75 and steps down to 45', () {
    final attempts = encodeAttempts(2048, 1536, 1080, quality: 75).toList();
    expect(attempts.first, (width: 1080, height: 810, quality: 75));
    expect([for (final a in attempts.take(4)) a.quality], [75, 65, 55, 45]);
  });

  test('blurhashSize: longest side 32, at least 1 px', () {
    expect(blurhashSize(400, 300), (width: 32, height: 24));
    expect(blurhashSize(400, 2), (width: 32, height: 1));
  });

  // Parity: the package:image path now takes its sizes from the plan, and
  // the declared size is the encoded JPEG's own SOF (B14).
  group('processImageSync declares its encoded size', () {
    final cases = <String, (int, int, ImagePurpose)>{
      'post landscape': (2400, 1800, ImagePurpose.post),
      'post portrait odd': (1001, 1777, ImagePurpose.post),
      'post small': (300, 200, ImagePurpose.post),
      'avatar': (900, 500, ImagePurpose.avatar),
    };
    cases.forEach((name, c) {
      test(name, () {
        final out = processImageSync(_jpg(c.$1, c.$2), c.$3);
        final spec = PurposeSpec.of(c.$3);
        final crop = cropFor(c.$3, c.$1, c.$2);
        final planned = fitWithin(crop.width, crop.height, spec.fullEdge);
        expect((width: out.width, height: out.height), planned);
        expect(jpegDims(out.fullBytes), planned);
        final thumb = jpegDims(out.thumbBytes)!;
        expect(thumb, fitWithin(planned.width, planned.height, spec.thumbEdge));
      });
    });
  });
}
