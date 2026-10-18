import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dzeroth/features/media/domain/image_processor.dart';
import 'package:dzeroth/features/media/domain/processed_image.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

img.Image _photo(int w, int h, {int channels = 3}) {
  final image = img.Image(width: w, height: h, numChannels: channels);
  for (final p in image) {
    p
      ..r = (p.x * 255 ~/ w)
      ..g = (p.y * 255 ~/ h)
      ..b = ((p.x + p.y) % 256);
    if (channels == 4) p.a = 128;
  }
  return image;
}

bool _contains(Uint8List bytes, String needle) {
  final n = ascii.encode(needle);
  for (var i = 0; i + n.length <= bytes.length; i++) {
    var ok = true;
    for (var j = 0; j < n.length; j++) {
      if (bytes[i + j] != n[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return true;
  }
  return false;
}

void main() {
  test('a large post photo is resized to 1600/400 JPEGs under the caps', () {
    final source = Uint8List.fromList(img.encodeJpg(_photo(3000, 2000)));

    final out = processImageSync(source, ImagePurpose.post);

    expect(out.contentType, 'image/jpeg');
    expect(out.width, 1600);
    expect(out.height, 1067);
    expect(out.fullBytes.length, lessThanOrEqualTo(kMaxFullBytes));
    expect(out.thumbBytes.length, lessThanOrEqualTo(kMaxThumbBytes));
    final thumb = img.decodeJpg(out.thumbBytes)!;
    expect(thumb.width, 400);
    expect(out.fullBytes.take(2), [0xFF, 0xD8]);
    expect(out.blurhash.length, inInclusiveRange(6, 64));
  });

  test('never upscales a small image', () {
    final source = Uint8List.fromList(img.encodePng(_photo(200, 100)));

    final out = processImageSync(source, ImagePurpose.post);

    expect(out.width, 200);
    expect(out.height, 100);
    expect(img.decodeJpg(out.thumbBytes)!.width, 200);
  });

  test('MD5 values are base64 of the exact bytes', () {
    final out = processImageSync(
      Uint8List.fromList(img.encodePng(_photo(300, 300))),
      ImagePurpose.post,
    );

    expect(out.fullMd5, base64.encode(md5.convert(out.fullBytes).bytes));
    expect(out.thumbMd5, base64.encode(md5.convert(out.thumbBytes).bytes));
  });

  test('EXIF (camera data, GPS) never reaches the output', () {
    final image = _photo(800, 600);
    image.exif.imageIfd.make = 'SECRETCAM';
    image.exif.imageIfd.software = 'LEAKYSOFT';
    image.exif.gpsIfd.data[0x0001] = img.IfdValueAscii('N');
    final source = Uint8List.fromList(img.encodeJpg(image));
    expect(_contains(source, 'SECRETCAM'), isTrue, reason: 'fixture check');

    final out = processImageSync(source, ImagePurpose.post);

    for (final bytes in [out.fullBytes, out.thumbBytes]) {
      expect(_contains(bytes, 'SECRETCAM'), isFalse);
      expect(_contains(bytes, 'LEAKYSOFT'), isFalse);
      expect(_contains(bytes, 'Exif'), isFalse);
      expect(img.decodeJpg(bytes)!.exif.isEmpty, isTrue);
    }
  });

  test('transparent PNG is flattened onto white', () {
    final source = Uint8List.fromList(
      img.encodePng(_photo(100, 100, channels: 4)),
    );

    final out = processImageSync(source, ImagePurpose.post);

    final decoded = img.decodeJpg(out.fullBytes)!;
    expect(decoded.numChannels, 3);
    expect(decoded.width, 100);
  });

  test('an avatar is a centred 400 px square with a 96 px thumb', () {
    final source = Uint8List.fromList(img.encodeJpg(_photo(1200, 800)));

    final out = processImageSync(source, ImagePurpose.avatar);

    expect(out.width, 400);
    expect(out.height, 400);
    final thumb = img.decodeJpg(out.thumbBytes)!;
    expect([thumb.width, thumb.height], [96, 96]);
  });

  test('bytes that are not an image are rejected', () {
    expect(
      () => processImageSync(
        Uint8List.fromList(utf8.encode('definitely not an image')),
        ImagePurpose.post,
      ),
      throwsA(isA<UnsupportedImageException>()),
    );
    expect(
      () => processImageSync(Uint8List(0), ImagePurpose.post),
      throwsA(isA<UnsupportedImageException>()),
    );
  });
}
