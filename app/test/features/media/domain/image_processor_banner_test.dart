import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dzeroth/features/media/domain/image_processor.dart';
import 'package:dzeroth/features/media/domain/processed_image.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// The banner purpose (ADR-0024 D1, W3-15) with real pixels: a centered 3:1
/// crop, full 1500 x 500 and thumb 600 x 200, under the banner's own caps. The
/// server rejects a declared size outside 3:1 within 2%, width > 1500 or
/// height > 500, and signs 1 MiB / 128 KiB caps.
img.Image _photo(int w, int h) {
  final image = img.Image(width: w, height: h, numChannels: 3);
  for (final p in image) {
    p
      ..r = (p.x * 255 ~/ w)
      ..g = (p.y * 255 ~/ h)
      ..b = ((p.x + p.y) % 256);
  }
  return image;
}

/// A noisy picture: the worst case for the byte caps.
img.Image _noise(int w, int h) {
  final random = math.Random(7);
  final image = img.Image(width: w, height: h, numChannels: 3);
  for (final p in image) {
    p
      ..r = random.nextInt(256)
      ..g = random.nextInt(256)
      ..b = random.nextInt(256);
  }
  return image;
}

Uint8List _jpg(img.Image image) => Uint8List.fromList(img.encodeJpg(image));

void expectThreeToOne(int width, int height) {
  expect(width, lessThanOrEqualTo(1500));
  expect(height, lessThanOrEqualTo(500));
  // The server's rule: 3*h*0.98 <= w <= 3*h*1.02.
  expect(100 * width, greaterThanOrEqualTo(294 * height));
  expect(100 * width, lessThanOrEqualTo(306 * height));
}

void main() {
  test('a large photo becomes a 1500 x 500 full and a 600 x 200 thumb', () {
    final out = processImageSync(_jpg(_photo(3000, 2000)), ImagePurpose.banner);

    expect(out.width, 1500);
    expect(out.height, 500);
    expectThreeToOne(out.width, out.height);
    final thumb = img.decodeJpg(out.thumbBytes)!;
    expect(thumb.width, 600);
    expect(thumb.height, 200);
    final full = img.decodeJpg(out.fullBytes)!;
    expect(full.width, 1500);
    expect(full.height, 500);
    expect(out.fullBytes.length, lessThanOrEqualTo(kMaxBannerFullBytes));
    expect(out.thumbBytes.length, lessThanOrEqualTo(kMaxBannerThumbBytes));
    expect(out.contentType, 'image/jpeg');
    expect(out.blurhash.length, inInclusiveRange(6, 64));
  });

  test('the crop is centered: the middle band of a tall photo survives', () {
    // Top third red, middle third green, bottom third blue.
    final source = img.Image(width: 900, height: 900, numChannels: 3);
    for (final p in source) {
      if (p.y < 300) {
        p
          ..r = 255
          ..g = 0
          ..b = 0;
      } else if (p.y < 600) {
        p
          ..r = 0
          ..g = 255
          ..b = 0;
      } else {
        p
          ..r = 0
          ..g = 0
          ..b = 255;
      }
    }

    final out = processImageSync(_jpg(source), ImagePurpose.banner);

    expect(out.width, 900);
    expect(out.height, 300);
    final full = img.decodeJpg(out.fullBytes)!;
    final middle = full.getPixel(450, 150);
    expect(middle.g, greaterThan(200));
    expect(middle.r, lessThan(60));
    expect(middle.b, lessThan(60));
  });

  test('a wide panorama is cropped on the sides, not squeezed', () {
    final out = processImageSync(_jpg(_photo(4000, 600)), ImagePurpose.banner);

    // 4000 x 600 -> the 1800 x 600 centre -> scaled down to 1500 x 500.
    expect(out.width, 1500);
    expect(out.height, 500);
    expectThreeToOne(out.width, out.height);
  });

  test('never upscales a small image, and stays exactly 3:1', () {
    final out = processImageSync(_jpg(_photo(900, 400)), ImagePurpose.banner);

    // 900 x 400 -> the 900 x 300 centre; no scaling.
    expect(out.width, 900);
    expect(out.height, 300);
    expectThreeToOne(out.width, out.height);
    final thumb = img.decodeJpg(out.thumbBytes)!;
    expect(thumb.width, 600);
    expect(thumb.height, 200);
  });

  test('an awkward size still crops to exactly three times the height', () {
    final out = processImageSync(_jpg(_photo(1001, 777)), ImagePurpose.banner);

    expect(out.width, out.height * 3);
    expectThreeToOne(out.width, out.height);
  });

  test('a noisy photo stays under the banner caps', () {
    final out = processImageSync(_jpg(_noise(3000, 1000)), ImagePurpose.banner);

    expect(out.fullBytes.length, lessThanOrEqualTo(kMaxBannerFullBytes));
    expect(out.thumbBytes.length, lessThanOrEqualTo(kMaxBannerThumbBytes));
    expectThreeToOne(out.width, out.height);
    final thumb = img.decodeJpg(out.thumbBytes)!;
    expect(thumb.width, lessThanOrEqualTo(600));
    expectThreeToOne(thumb.width, thumb.height);
  });

  test('a sliver too thin to be a banner is unusable', () {
    expect(
      () => processImageSync(_jpg(_photo(40, 10)), ImagePurpose.banner),
      throwsA(isA<UnsupportedImageException>()),
    );
  });

  test('not an image is unusable', () {
    expect(
      () =>
          processImageSync(Uint8List.fromList([1, 2, 3]), ImagePurpose.banner),
      throwsA(isA<UnsupportedImageException>()),
    );
  });

  test('avatar and post purposes are unchanged by the banner path', () {
    final avatar = processImageSync(
      _jpg(_photo(800, 600)),
      ImagePurpose.avatar,
    );
    expect(avatar.width, 400);
    expect(avatar.height, 400);
    final post = processImageSync(_jpg(_photo(3000, 2000)), ImagePurpose.post);
    expect(post.width, 1600);
    expect(post.height, 1067);
  });
}
