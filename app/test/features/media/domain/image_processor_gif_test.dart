import 'dart:typed_data';

import 'package:dzeroth/features/media/domain/image_processor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../../../support/media_fixtures.dart';

/// The on-device GIF checks and thumbnail (W6-16, ADR-0029 D10/F10).
void main() {
  test('a GIF goes up unchanged with a JPEG still as its thumbnail', () {
    final bytes = realGifBytes(width: 32, height: 24, frames: 3);

    final out = prepareGifSync(bytes);

    expect(out.fullBytes, same(bytes), reason: 'never re-encoded');
    expect(out.contentType, 'image/gif');
    expect(out.thumbContentType, 'image/jpeg');
    expect(out.isGif, isTrue);
    expect(out.width, 32);
    expect(out.height, 24);
    expect(out.blurhash, isNotEmpty);
    expect(out.blurhash.length, lessThanOrEqualTo(64));
    expect(out.thumbBytes.length, lessThanOrEqualTo(kMaxThumbBytes));
    // The thumbnail is a JPEG (FF D8), a single still.
    expect(out.thumbBytes.sublist(0, 2), [0xFF, 0xD8]);
    expect(img.decodeJpg(out.thumbBytes), isNotNull);
    expect(out.fullMd5, isNotEmpty);
    expect(out.thumbMd5, isNot(out.fullMd5));
  });

  test('1.8 MiB is accepted, 3 MiB is refused with the size message', () {
    final base = realGifBytes();
    Uint8List padded(int size) {
      final out = Uint8List(size)..setAll(0, base);
      // Trailing bytes after the GIF trailer are ignored by decoders.
      return out;
    }

    expect(
      () => checkGifBytes(padded((1.8 * 1024 * 1024).round())),
      returnsNormally,
    );
    expect(
      () => prepareGifSync(padded(3 * 1024 * 1024)),
      throwsA(
        isA<GifRefusedException>().having(
          (e) => e.message,
          'message',
          'GIFs can be up to 2 MB.',
        ),
      ),
    );
    expect(() => checkGifBytes(padded(kMaxGifBytes)), returnsNormally);
    expect(
      () => checkGifBytes(padded(kMaxGifBytes + 1)),
      throwsA(isA<GifRefusedException>()),
    );
  });

  test('a logical screen over 1,280 px on either side is refused', () {
    expect(
      () => prepareGifSync(realGifBytes(width: 1281, height: 2)),
      throwsA(GifRefusedException.tooLarge),
    );
    expect(
      () => prepareGifSync(realGifBytes(width: 2, height: 1281)),
      throwsA(GifRefusedException.tooLarge),
    );
    expect(prepareGifSync(realGifBytes(width: 1280, height: 2)).width, 1280);
  });

  test('more than 300 frames is refused', () {
    expect(
      () => prepareGifSync(realGifBytes(width: 2, height: 2, frames: 301)),
      throwsA(GifRefusedException.tooLong),
    );
    expect(
      prepareGifSync(realGifBytes(width: 2, height: 2, frames: 300)).isGif,
      isTrue,
    );
  });

  test('a file that is not a GIF is refused before any decoding', () {
    final png = Uint8List.fromList(
      img.encodePng(img.Image(width: 4, height: 4)),
    );
    expect(() => prepareGifSync(png), throwsA(GifRefusedException.notGif));
    expect(
      () => checkGifBytes(Uint8List(0)),
      throwsA(GifRefusedException.notGif),
    );
    expect(
      () => prepareGifSync(Uint8List.fromList('GIF89a'.codeUnits)),
      throwsA(isA<GifRefusedException>()),
    );
  });

  test('refusal messages are the ones the user reads', () {
    expect(GifRefusedException.tooBig.message, 'GIFs can be up to 2 MB.');
    expect(GifRefusedException.notGif.toString(), "That file isn't a GIF.");
  });
}
