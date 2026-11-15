import 'dart:async';
import 'dart:typed_data';

import 'package:blurhash_dart/blurhash_dart.dart';
import 'package:image/image.dart' as img;

import 'image_preflight.dart';
import 'image_processor.dart';
import 'image_size_plan.dart';
import 'processed_image.dart';
import 'raster_image_processor.dart';

/// [GifPreparer] over a [RasterCodec]: on the web the browser decodes the
/// GIF's first frame and encodes the JPEG still and the BlurHash pixels in a
/// worker, so the UI thread only runs the header checks and the byte-level
/// strip (a linear scan, no pixel decode). The upload is the stripped GIF
/// itself, never re-encoded. Every limit is the one [prepareGifSync] applies.
///
/// A codec that cannot finish throws [RasterUnavailableException];
/// [FallbackGifPreparer] then uses the `package:image` path.
class RasterGifPreparer implements GifPreparer {
  const RasterGifPreparer(
    RasterCodec codec, {
    Duration stepTimeout = kRasterStepTimeout,
  }) : _codec = codec,
       _stepTimeout = stepTimeout;

  final RasterCodec _codec;
  final Duration _stepTimeout;

  @override
  Future<ProcessedImage> prepare(Uint8List bytes) async {
    final headers = inspectGif(bytes);
    final session = await _codec.open();
    try {
      final source = await _step(session, session.decode(headers.bytes));
      // A first frame that is not the declared screen is not one the
      // thumbnail can honestly describe: let package:image decide.
      if (source.width != headers.width || source.height != headers.height) {
        throw const RasterUnavailableException('decoded size mismatch');
      }
      final crop = (x: 0, y: 0, width: source.width, height: source.height);
      final thumb = await _encodeThumb(session, crop);
      final hashSize = blurhashSize(thumb.width, thumb.height);
      final pixels = await _step(
        session,
        session.rgba(crop, hashSize.width, hashSize.height),
      );
      if (pixels.length != hashSize.width * hashSize.height * 4) {
        throw const RasterUnavailableException.capability('pixel buffer size');
      }
      final blurhash = BlurHash.encode(
        img.Image.fromBytes(
          width: hashSize.width,
          height: hashSize.height,
          bytes: pixels.buffer,
          bytesOffset: pixels.offsetInBytes,
          numChannels: 4,
        ),
        numCompX: 4,
        numCompY: 3,
      ).hash;
      return ProcessedImage(
        fullBytes: headers.bytes,
        thumbBytes: thumb.bytes,
        width: headers.width,
        height: headers.height,
        fullMd5: await md5Yielding(headers.bytes),
        thumbMd5: await md5Yielding(thumb.bytes),
        blurhash: blurhash,
        contentType: kGifContentType,
        thumbContentType: 'image/jpeg',
      );
    } finally {
      session.close();
    }
  }

  Future<T> _step<T>(RasterSession session, Future<T> work) {
    return work.timeout(
      _stepTimeout,
      onTimeout: () {
        session.close();
        throw const RasterUnavailableException('step timed out');
      },
    );
  }

  Future<({Uint8List bytes, int width, int height})> _encodeThumb(
    RasterSession session,
    CropRect crop,
  ) async {
    for (final attempt in encodeAttempts(
      crop.width,
      crop.height,
      kPostThumbEdge,
      quality: kPostThumbQuality,
    )) {
      final out = await _step(
        session,
        session.encodeJpeg(
          crop,
          attempt.width,
          attempt.height,
          attempt.quality,
        ),
      );
      final dims = jpegDims(out);
      if (dims == null ||
          dims.width != attempt.width ||
          dims.height != attempt.height) {
        // Never declare a guess.
        throw const RasterUnavailableException.capability(
          'encoded size mismatch',
        );
      }
      if (out.length <= kMaxThumbBytes) {
        return (bytes: out, width: attempt.width, height: attempt.height);
      }
    }
    throw GifRefusedException.notGif;
  }
}

/// Uses [primary] (the worker) and, when it is unavailable, [fallback]
/// (`package:image`): for good after a permanent failure, else for that GIF
/// only. A [GifRefusedException] is an answer, never retried. A browser
/// decode refusal ([UnsupportedImageException]) goes to the fallback too,
/// which decides that file.
class FallbackGifPreparer implements GifPreparer {
  FallbackGifPreparer({
    required GifPreparer primary,
    required GifPreparer fallback,
    void Function(Object reason)? onFallback,
  }) : _primary = primary,
       _fallback = fallback,
       _onFallback = onFallback;

  final GifPreparer _primary;
  final GifPreparer _fallback;
  final void Function(Object reason)? _onFallback;
  bool _primaryBroken = false;

  /// True once [primary] failed for good and every GIF goes to [fallback].
  bool get usingFallback => _primaryBroken;

  @override
  Future<ProcessedImage> prepare(Uint8List bytes) async {
    if (!_primaryBroken) {
      try {
        return await _primary.prepare(bytes);
      } on RasterUnavailableException catch (reason) {
        if (reason.permanent) _primaryBroken = true;
        _onFallback?.call(reason);
      } on UnsupportedImageException catch (reason) {
        _onFallback?.call(reason);
      }
    }
    return _fallback.prepare(bytes);
  }
}
