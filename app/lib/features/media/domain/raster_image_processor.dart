import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:blurhash_dart/blurhash_dart.dart';
import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;

import 'image_preflight.dart';
import 'image_processor.dart';
import 'image_size_plan.dart';
import 'processed_image.dart';
import 'processing_cancellation.dart';

/// A decoder/encoder that runs somewhere other than the UI thread (on web: a
/// Web Worker with `createImageBitmap` + `OffscreenCanvas`). One session
/// handles one image; [RasterSession.close] frees it (terminates the worker).
abstract interface class RasterCodec {
  /// Opens a session. Throws [RasterUnavailableException] when this browser
  /// cannot run it (no worker, no OffscreenCanvas, script not served).
  Future<RasterSession> open();
}

abstract interface class RasterSession {
  /// Decodes [bytes] with the EXIF orientation applied and returns the
  /// oriented size. Throws [UnsupportedImageException] for a file that is not
  /// a decodable image.
  Future<({int width, int height})> decode(Uint8List bytes);

  /// The [crop] of the decoded image drawn onto white at exactly [width] x
  /// [height] and encoded as a JPEG (no metadata) at [quality] (0..100).
  Future<Uint8List> encodeJpeg(
    CropRect crop,
    int width,
    int height,
    int quality,
  );

  /// The [crop] drawn onto white at [width] x [height], as RGBA bytes.
  Future<Uint8List> rgba(CropRect crop, int width, int height);

  void close();
}

/// The codec could not finish this image. [FallbackImageProcessor] then uses
/// the `package:image` path: for good when [permanent] (this browser cannot
/// run it, or it broke the size contract), else for this image only (a
/// timeout or a one-off failure; the next image gets a fresh worker).
class RasterUnavailableException implements Exception {
  const RasterUnavailableException(this.reason, {this.permanent = false});

  /// No Worker / OffscreenCanvas, a protocol mismatch, a script that is not
  /// served, or a JPEG whose size is not the size asked for.
  const RasterUnavailableException.capability(this.reason) : permanent = true;

  final String reason;
  final bool permanent;

  @override
  String toString() =>
      'Raster codec unavailable${permanent ? ' (permanent)' : ''}: $reason';
}

/// How long one codec step (decode, one encode, the BlurHash pixels) may
/// take before the worker is closed and the image falls back. A hung
/// `createImageBitmap` / `convertToBlob`, or a worker killed for memory
/// without an error event, must never freeze the tile (and, as photos are
/// prepared one at a time, every photo after it).
const kRasterStepTimeout = Duration(seconds: 30);

/// [ImageProcessor] over a [RasterCodec]: the browser decodes, resizes and
/// encodes in a worker, while every size decision is made here, in
/// [image_size_plan.dart], identically to [processImageSync]. The output's
/// declared width x height are checked against the JPEG's own SOF before it
/// is returned, so what is declared is what was encoded (server B14).
///
/// Re-encoding through a canvas drops all metadata (EXIF, GPS, ICC), and the
/// canvas is filled white first, so transparency flattens like the
/// `package:image` path.
class RasterImageProcessor implements ImageProcessor {
  const RasterImageProcessor(
    RasterCodec codec, {
    Duration stepTimeout = kRasterStepTimeout,
  }) : _codec = codec,
       _stepTimeout = stepTimeout;

  final RasterCodec _codec;
  final Duration _stepTimeout;

  @override
  Future<ProcessedImage> process(
    Uint8List bytes,
    ImagePurpose purpose, {
    ProcessingCancellation? cancellation,
  }) async {
    preflightImage(bytes);
    final cancel = cancellation ?? ProcessingCancellation();
    try {
      return await _process(bytes, purpose, cancel);
    } on RasterUnavailableException {
      // Cancelling closes the worker, which fails its pending step: that is
      // the cancellation, not a broken codec.
      cancel.throwIfCancelled();
      rethrow;
    }
  }

  /// [work] under [cancel] and the per-step timeout; a timed-out step closes
  /// [session] (terminating the worker).
  Future<T> _step<T>(
    RasterSession session,
    ProcessingCancellation cancel,
    Future<T> work,
  ) {
    return cancel
        .guard(work)
        .timeout(
          _stepTimeout,
          onTimeout: () {
            session.close();
            throw const RasterUnavailableException('step timed out');
          },
        );
  }

  Future<ProcessedImage> _process(
    Uint8List bytes,
    ImagePurpose purpose,
    ProcessingCancellation cancel,
  ) async {
    cancel.throwIfCancelled();
    final opening = _codec.open();
    final RasterSession session;
    try {
      session = await cancel.guard(opening);
    } on ImageProcessingCancelled {
      // A worker that starts after the cancel is closed as soon as it does.
      unawaited(opening.then((s) => s.close(), onError: (Object _) {}));
      rethrow;
    }
    // Cancelling closes the session at once: the worker stops mid-step.
    final closeOnCancel = cancel.whenCancelled.then((_) => session.close());
    try {
      final source = await _step(session, cancel, session.decode(bytes));
      checkSourceDims(source.width, source.height);
      final spec = PurposeSpec.of(purpose);
      final crop = cropFor(purpose, source.width, source.height);

      final full = await _encodeWithin(
        session,
        cancel,
        crop,
        crop.width,
        crop.height,
        spec.fullEdge,
        spec.maxFullBytes,
        PurposeSpec.fullQuality,
        spec.threeToOne,
      );
      final thumb = await _encodeWithin(
        session,
        cancel,
        crop,
        full.width,
        full.height,
        spec.thumbEdge,
        spec.maxThumbBytes,
        PurposeSpec.thumbQuality,
        spec.threeToOne,
      );

      final hashSize = blurhashSize(thumb.width, thumb.height);
      final pixels = await _step(
        session,
        cancel,
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

      final fullMd5 = await md5Yielding(full.bytes);
      final thumbMd5 = await md5Yielding(thumb.bytes);
      cancel.throwIfCancelled();
      return ProcessedImage(
        fullBytes: full.bytes,
        thumbBytes: thumb.bytes,
        width: full.width,
        height: full.height,
        fullMd5: fullMd5,
        thumbMd5: thumbMd5,
        blurhash: blurhash,
      );
    } finally {
      session.close();
      unawaited(closeOnCancel);
    }
  }

  Future<({Uint8List bytes, int width, int height})> _encodeWithin(
    RasterSession session,
    ProcessingCancellation cancel,
    CropRect crop,
    int width,
    int height,
    int edge,
    int maxBytes,
    int quality,
    bool threeToOne,
  ) async {
    for (final attempt in encodeAttempts(
      width,
      height,
      edge,
      quality: quality,
      threeToOne: threeToOne,
    )) {
      final out = await _step(
        session,
        cancel,
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
        // Never declare a guess: the caller falls back to package:image.
        throw const RasterUnavailableException.capability(
          'encoded size mismatch',
        );
      }
      if (out.length <= maxBytes) {
        return (bytes: out, width: attempt.width, height: attempt.height);
      }
    }
    throw const UnsupportedImageException('Image is too large to upload.');
  }
}

/// Base64 MD5 of [bytes], computed in 256 KiB slices with a yield between
/// them, so a 2 MiB file never holds the UI thread for one long task.
Future<String> md5Yielding(Uint8List bytes) async {
  const slice = 256 * 1024;
  late Digest digest;
  final sink = md5.startChunkedConversion(
    ChunkedConversionSink<Digest>.withCallback((d) => digest = d.single),
  );
  for (var at = 0; at < bytes.length; at += slice) {
    final end = at + slice < bytes.length ? at + slice : bytes.length;
    sink.add(Uint8List.sublistView(bytes, at, end));
    if (end < bytes.length) await Future<void>.delayed(Duration.zero);
  }
  sink.close();
  return base64.encode(digest.bytes);
}

/// Uses [primary] (the worker) and, when it fails, [fallback]
/// (`package:image`): from then on when the failure is permanent (this
/// browser cannot run it, or it broke the size contract), else for that
/// image only.
/// Undecodable files, too-large files and cancellation are answers, not
/// failures: they are passed through, never retried on the fallback.
class FallbackImageProcessor implements ImageProcessor {
  FallbackImageProcessor({
    required ImageProcessor primary,
    required ImageProcessor fallback,
    void Function(Object reason)? onFallback,
  }) : _primary = primary,
       _fallback = fallback,
       _onFallback = onFallback;

  final ImageProcessor _primary;
  final ImageProcessor _fallback;
  final void Function(Object reason)? _onFallback;
  bool _primaryBroken = false;

  /// True once [primary] failed for good and every job goes to [fallback].
  bool get usingFallback => _primaryBroken;

  @override
  Future<ProcessedImage> process(
    Uint8List bytes,
    ImagePurpose purpose, {
    ProcessingCancellation? cancellation,
  }) async {
    if (!_primaryBroken) {
      try {
        return await _primary.process(
          bytes,
          purpose,
          cancellation: cancellation,
        );
      } on RasterUnavailableException catch (reason) {
        // A cancel closes the worker; never fall back for a cancelled job.
        if (cancellation?.isCancelled ?? false) {
          throw const ImageProcessingCancelled();
        }
        // Only a capability failure or a contract breach is for good; a
        // timeout or one-off failure falls back for this image only, and the
        // next image gets a fresh worker.
        if (reason.permanent) _primaryBroken = true;
        _onFallback?.call(reason);
      }
    }
    return _fallback.process(bytes, purpose, cancellation: cancellation);
  }
}
