import 'dart:typed_data';

import 'package:dzeroth/features/media/domain/image_preflight.dart';
import 'package:dzeroth/features/media/domain/processed_image.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../../../support/raster_fakes.dart';

void main() {
  group('probeImageDims reads the header only', () {
    final source = img.Image(width: 37, height: 21);
    final cases = <String, Uint8List>{
      'jpeg': img.encodeJpg(source),
      'png': img.encodePng(source),
      'gif': img.encodeGif(source),
    };
    for (final entry in cases.entries) {
      test(entry.key, () {
        expect(probeImageDims(entry.value), (width: 37, height: 21));
      });
    }

    test('a JPEG with a large APP1 before the SOF', () {
      final jpg = jpegWithApp(fakeJpeg(1600, 1200), 60000);
      expect(probeImageDims(jpg), (width: 1600, height: 1200));
    });

    test('webp VP8X / VP8L / VP8', () {
      expect(probeImageDims(webpVp8x(5000, 3000)), (width: 5000, height: 3000));
      expect(probeImageDims(webpVp8l(300, 200)), (width: 300, height: 200));
      expect(probeImageDims(webpVp8(640, 480)), (width: 640, height: 480));
    });

    test('unknown or truncated headers are null', () {
      expect(probeImageDims(Uint8List.fromList([1, 2, 3])), isNull);
      expect(probeImageDims(Uint8List.fromList([0xFF, 0xD8, 0xFF])), isNull);
      // SOS before any SOF.
      expect(
        jpegDims(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xDA, 0, 2, 0, 0])),
        isNull,
      );
    });
  });

  group('preflightImage', () {
    test('accepts a normal photo', () {
      preflightImage(fakeJpeg(4032, 3024)); // 12 MP
    });

    test('refuses more than kMaxSourcePixels before any decode', () {
      expect(
        () => preflightImage(fakeJpeg(12000, 9000)), // 108 MP
        throwsA(same(tooLargeSource)),
      );
      expect(
        () => preflightImage(webpVp8x(10000, 10000)),
        throwsA(same(tooLargeSource)),
      );
    });

    test('refuses a file over kMaxSourceBytes', () {
      final big = Uint8List(kMaxSourceBytes + 1)..setAll(0, fakeJpeg(100, 100));
      expect(() => preflightImage(big), throwsA(same(tooLargeSource)));
    });

    test('refuses an empty file and a zero-sized header', () {
      expect(
        () => preflightImage(Uint8List(0)),
        throwsA(isA<UnsupportedImageException>()),
      );
      expect(
        () => preflightImage(fakeJpeg(0, 10)),
        throwsA(isA<UnsupportedImageException>()),
      );
    });

    test('leaves an unknown format to the decoder', () {
      preflightImage(Uint8List.fromList([1, 2, 3, 4]));
    });
  });
}
