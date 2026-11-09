import 'dart:typed_data';

import 'package:dzeroth/features/media/domain/image_processor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../../../support/media_fixtures.dart';

/// The on-device GIF checks and thumbnail.
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

  test(
    '1.8 MiB passes the size check, 3 MiB is refused with the size message',
    () {
      final base = realGifBytes();
      Uint8List padded(int size) {
        final out = Uint8List(size)..setAll(0, base);
        // Padding after the trailer: decoders ignore it, strips it.
        return out;
      }

      expect(
        () => checkGifBytes(padded((1.8 * 1024 * 1024).round())),
        returnsNormally,
      );
      final ok = prepareGifSync(padded((1.8 * 1024 * 1024).round()));
      expect(ok.isGif, isTrue);
      expect(
        ok.fullBytes,
        base,
        reason: 'padding after the trailer is stripped',
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
    },
  );

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

  // Task 13: FinalizeUpload refuses a GIF whose declared width/height differ
  // from its logical screen (header bytes 6-9, little-endian), so the client
  // must declare exactly that, not the first frame's size.
  test('the declared size is the logical screen in the header', () {
    for (final (w, h) in [(32, 24), (1, 1), (300, 2), (1280, 3)]) {
      final bytes = realGifBytes(width: w, height: h, frames: 1);
      final out = prepareGifSync(bytes);
      final header = ByteData.sublistView(out.fullBytes, 6, 10);
      expect(out.width, header.getUint16(0, Endian.little), reason: '$w x $h');
      expect(out.height, header.getUint16(2, Endian.little), reason: '$w x $h');
      expect((out.width, out.height), (w, h));
    }
  });

  test('a first frame smaller than the logical screen still declares the '
      'screen, and the thumbnail is no larger than it', () {
    // A 20 x 15 GIF whose logical screen is widened to 40 x 30: the frame
    // sits at 0,0 inside the screen, which is valid GIF.
    final bytes = realGifBytes(width: 20, height: 15, frames: 1);
    ByteData.sublistView(bytes, 6, 10)
      ..setUint16(0, 40, Endian.little)
      ..setUint16(2, 30, Endian.little);

    final out = prepareGifSync(bytes);

    expect((out.width, out.height), (40, 30));
    final thumb = img.decodeJpg(out.thumbBytes)!;
    expect(thumb.width, lessThanOrEqualTo(40));
    expect(thumb.height, lessThanOrEqualTo(30));
  });

  test('refusal messages are the ones the user reads', () {
    expect(GifRefusedException.tooBig.message, 'GIFs can be up to 2 MB.');
    expect(GifRefusedException.notGif.toString(), "That file isn't a GIF.");
  });
}
