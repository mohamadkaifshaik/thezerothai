import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:blurhash_dart/blurhash_dart.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'image_preflight.dart';
import 'image_size_plan.dart';
import 'processed_image.dart';
import 'processing_cancellation.dart';

/// Size limits the signed URLs enforce (media.proto: full <= 2 MiB,
/// thumb <= 256 KiB).
const kMaxFullBytes = 2 * 1024 * 1024;
const kMaxThumbBytes = 256 * 1024;

/// Edge lengths per purpose (post 1600/400, avatar
/// 400/96 center-cropped square).
const kPostFullEdge = 1600;
const kPostThumbEdge = 400;
const kAvatarFullEdge = 400;
const kAvatarThumbEdge = 96;

/// The banner: a center-cropped 3:1 band, full 1500 x 500 and
/// thumb 600 x 200, under the banner's own, tighter caps (1 MiB / 128 KiB).
/// The server checks the declared size: width <= 1500, height <= 500 and 3:1
/// within 2%; this processor produces exactly 3:1.
const kBannerFullWidth = 1500;
const kBannerThumbWidth = 600;
const kMaxBannerFullBytes = 1024 * 1024;
const kMaxBannerThumbBytes = 128 * 1024;

enum ImagePurpose { post, avatar, banner }

/// Turns picked bytes into an upload-ready [ProcessedImage]. An interface so
/// widget and cubit tests never decode real pixels.
///
/// Every implementation refuses inputs over the preflight bounds
/// ([preflightImage]) before decoding, and stops (throwing
/// [ImageProcessingCancelled]) once its cancellation is cancelled.
abstract interface class ImageProcessor {
  Future<ProcessedImage> process(
    Uint8List bytes,
    ImagePurpose purpose, {
    ProcessingCancellation? cancellation,
  });
}

/// Pure-Dart implementation (`package:image`) that runs decode/resize/encode
/// through `compute`.
///
/// - Android and iOS: a background isolate, so a 12 MP photo does not block
///   the UI thread. Cancelling drops the isolate's result.
/// - Web: `compute` has no isolates there and runs on the main thread, so the
///   web build uses the worker-backed `RasterImageProcessor` instead
///   (`createPlatformImageProcessor`) and keeps this one only as the fallback
///   for a browser without `Worker` / `OffscreenCanvas`.
/// - HEIC/HEIF cannot be decoded by this package. iOS' picker hands back
///   JPEG; elsewhere such a file is reported as unsupported.
class IsolateImageProcessor implements ImageProcessor {
  const IsolateImageProcessor();

  @override
  Future<ProcessedImage> process(
    Uint8List bytes,
    ImagePurpose purpose, {
    ProcessingCancellation? cancellation,
  }) async {
    // Cheap header checks first: an oversized file never reaches a decoder.
    preflightImage(bytes);
    cancellation?.throwIfCancelled();
    final work = compute(_run, (bytes, purpose));
    return cancellation == null ? work : cancellation.guard(work);
  }
}

ProcessedImage _run((Uint8List, ImagePurpose) args) =>
    processImageSync(args.$1, args.$2);

/// Synchronous core, exported for tests and for [IsolateImageProcessor].
///
/// - Decodes, applies the EXIF orientation, then **clears all EXIF**
///   (GPS and camera data never leave the device).
/// - Flattens transparency onto white (JPEG has no alpha).
/// - Downscales to the purpose's full edge (never upscales), encodes JPEG
///   stepping quality (then size) down until it fits the signed-URL cap.
/// - Avatars are center-cropped to a square first, banners to exactly 3:1.
ProcessedImage processImageSync(Uint8List bytes, ImagePurpose purpose) {
  img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } catch (_) {
    decoded = null;
  }
  if (decoded == null) throw const UnsupportedImageException();

  var source = img.bakeOrientation(decoded);
  source.exif.clear();
  source = _flattenOnWhite(source);

  final avatar = purpose == ImagePurpose.avatar;
  final banner = purpose == ImagePurpose.banner;
  if (avatar || banner) {
    // Centered square / largest centered 3:1 band (image_size_plan.dart).
    final crop = cropFor(purpose, source.width, source.height);
    source = img.copyCrop(
      source,
      x: crop.x,
      y: crop.y,
      width: crop.width,
      height: crop.height,
    );
  }
  final fullEdge = banner
      ? kBannerFullWidth
      : (avatar ? kAvatarFullEdge : kPostFullEdge);
  final thumbEdge = banner
      ? kBannerThumbWidth
      : (avatar ? kAvatarThumbEdge : kPostThumbEdge);

  final full = _encodeWithin(
    source,
    fullEdge,
    banner ? kMaxBannerFullBytes : kMaxFullBytes,
    quality: 80,
    threeToOne: banner,
  );
  final thumb = _encodeWithin(
    full.image,
    thumbEdge,
    banner ? kMaxBannerThumbBytes : kMaxThumbBytes,
    quality: 70,
    threeToOne: banner,
  );

  return ProcessedImage(
    fullBytes: full.bytes,
    thumbBytes: thumb.bytes,
    width: full.image.width,
    height: full.image.height,
    fullMd5: base64.encode(md5.convert(full.bytes).bytes),
    thumbMd5: base64.encode(md5.convert(thumb.bytes).bytes),
    blurhash: _blurhashOf(thumb.image),
  );
}

/// JPEG has no alpha: transparent pixels become white.
img.Image _flattenOnWhite(img.Image source) {
  if (!source.hasAlpha && source.numChannels == 3) return source;
  final flat = img.Image(
    width: source.width,
    height: source.height,
    numChannels: 3,
  );
  img.fill(flat, color: img.ColorRgb8(255, 255, 255));
  img.compositeImage(flat, source);
  return flat;
}

/// The BlurHash (4 x 3 components, <= 64 chars) of a thumbnail.
String _blurhashOf(img.Image thumb) {
  // Longest side 32, the other at least 1 px: a very thin strip (a 1280 x 2
  // GIF) must not round to zero.
  final longest = math.max(thumb.width, thumb.height);
  final hashSource = img.copyResize(
    thumb,
    width: math.max(1, (thumb.width * 32 / longest).round()),
    height: math.max(1, (thumb.height * 32 / longest).round()),
    interpolation: img.Interpolation.average,
  );
  return BlurHash.encode(hashSource, numCompX: 4, numCompY: 3).hash;
}

/// The server's GIF limits: checked here so a GIF the
/// server would refuse is never uploaded (and never spends a Vision unit).
const kMaxGifBytes = kMaxFullBytes;
const kMaxGifEdge = 1280;
const kMaxGifFrames = 300;

/// Why a picked file cannot be a GIF post attachment. [message] is shown to
/// the user as is.
class GifRefusedException implements Exception {
  const GifRefusedException(this.message);
  final String message;

  static const notGif = GifRefusedException("That file isn't a GIF.");
  static const tooBig = GifRefusedException('GIFs can be up to 2 MB.');
  static const tooLarge = GifRefusedException(
    'GIFs can be up to 1,280 pixels wide and tall.',
  );
  static const tooLong = GifRefusedException('GIFs can have up to 300 frames.');

  @override
  String toString() => message;
}

/// Checks a picked GIF and makes its upload: the picked bytes with only the
/// non-rendering blocks stripped (re-encoding would drop the animation)
/// plus a still first-frame JPEG
/// thumbnail. An interface so widget and cubit tests never decode pixels.
/// Throws [GifRefusedException] for a file the server would refuse.
abstract interface class GifPreparer {
  Future<ProcessedImage> prepare(Uint8List bytes);
}

/// Pure-Dart implementation run through `compute` (see [IsolateImageProcessor]
/// for the web caveat).
class IsolateGifPreparer implements GifPreparer {
  const IsolateGifPreparer();

  @override
  Future<ProcessedImage> prepare(Uint8List bytes) {
    // Cheap checks first: a 40 MB file is never shipped to an isolate.
    checkGifBytes(bytes);
    return compute(prepareGifSync, bytes);
  }
}

/// The size and signature checks that need no decoding.
void checkGifBytes(Uint8List bytes) {
  final signature = bytes.length >= 6 ? String.fromCharCodes(bytes, 0, 6) : '';
  if (signature != 'GIF87a' && signature != 'GIF89a') {
    throw GifRefusedException.notGif;
  }
  if (bytes.length > kMaxGifBytes) throw GifRefusedException.tooBig;
}

/// The loop blocks that make a GIF repeat; the only application extensions
/// kept (their sub-blocks stay intact, so looping still works).
const _kGifLoopIds = {'NETSCAPE2.0', 'ANIMEXTS1.0'};

/// Removes everything from a GIF that renders nothing, **without re-encoding**
/// (security L-4): comment (0xFE) and plain-text (0x01)
/// extensions, every application extension (0xFF) except `NETSCAPE2.0` and
/// `ANIMEXTS1.0` (XMP, ICC, ...), any extension label other than the graphic
/// control (0xF9), and every byte after the first trailer (0x3B). Frames,
/// palettes and timing are copied byte for byte; the first loop block is rewritten to `03 01 LL LL 00` (below). The server's
/// `scanGIF` refuses exactly these, so the output of this function passes it.
///
/// Returns [bytes] itself when there is nothing to remove. Throws
/// [GifRefusedException.notGif] for a file that does not parse to a trailer.
Uint8List stripGifBytes(Uint8List bytes) {
  final n = bytes.length;
  if (n < 13) throw GifRefusedException.notGif;
  var pos = 13;
  if (bytes[10] & 0x80 != 0) pos += 3 << ((bytes[10] & 7) + 1);
  if (pos > n) throw GifRefusedException.notGif;

  // Position after the sub-block run that starts at p (its zero terminator).
  int endOfSubBlocks(int p) {
    while (true) {
      if (p >= n) throw GifRefusedException.notGif;
      final size = bytes[p++];
      if (size == 0) return p;
      p += size;
    }
  }

  final out = BytesBuilder(copy: false)
    ..add(Uint8List.sublistView(bytes, 0, pos));
  var seenLoop = false;
  while (true) {
    if (pos >= n) throw GifRefusedException.notGif;
    switch (bytes[pos]) {
      case 0x3B:
        out.addByte(0x3B);
        // Identity (same instance) when nothing was dropped.
        return out.length == pos + 1 && pos + 1 == n ? bytes : out.takeBytes();
      case 0x21:
        if (pos + 2 > n) throw GifRefusedException.notGif;
        final label = bytes[pos + 1];
        final end = endOfSubBlocks(pos + 2);
        if (label == 0xF9) {
          out.add(Uint8List.sublistView(bytes, pos, end));
        } else if (label == 0xFF && _isLoopBlock(bytes, pos + 2)) {
          // Only the FIRST loop block is considered; it is rewritten
          // to the canonical form, or dropped when it has no valid loop count.
          if (!seenLoop) {
            seenLoop = true;
            final canonical = _canonicalLoopBlock(bytes, pos, end);
            if (canonical != null) out.add(canonical);
          }
        }
        pos = end;
      case 0x2C:
        var p = pos + 10;
        if (p > n) throw GifRefusedException.notGif;
        final packed = bytes[pos + 9];
        if (packed & 0x80 != 0) p += 3 << ((packed & 7) + 1);
        p++; // LZW minimum code size
        if (p > n) throw GifRefusedException.notGif;
        final end = endOfSubBlocks(p);
        out.add(Uint8List.sublistView(bytes, pos, end));
        pos = end;
      default:
        throw GifRefusedException.notGif;
    }
  }
}

/// re-review N-1: the loop block at [pos, end) (extension
/// introducer at [pos], identifier at [pos + 3, pos + 14)) rewritten to
/// `21 FF 0B <id> 03 01 LL LL 00`, byte level, with the loop count `LL LL` of
/// its first sub-block that is 3 bytes long with sub-block id 1 (what browsers
/// read); every other sub-block is dropped, because they are free space for
/// smuggled data. A block with no such sub-block is DROPPED (null): browsers
/// then play the GIF once, exactly as they treat the unreadable block, whereas
/// writing loop count 0 would make it loop forever. Returns null for a drop.
Uint8List? _canonicalLoopBlock(Uint8List bytes, int pos, int end) {
  var p = pos + 14; // first sub-block after the 11-byte identifier
  while (p < end) {
    final size = bytes[p];
    if (size == 0) return null;
    if (size == 3 && p + 4 <= end && bytes[p + 1] == 1) {
      final out = Uint8List(19)..setRange(0, 14, bytes, pos);
      out[14] = 3;
      out[15] = 1;
      out[16] = bytes[p + 2];
      out[17] = bytes[p + 3];
      return out; // out[18] is the 0 terminator
    }
    p += size + 1;
  }
  return null;
}

bool _isLoopBlock(Uint8List bytes, int at) {
  if (at + 12 > bytes.length || bytes[at] != 11) return false;
  return _kGifLoopIds.contains(String.fromCharCodes(bytes, at + 1, at + 12));
}

/// Synchronous core of [IsolateGifPreparer], exported for tests: signature,
/// size, [stripGifBytes], logical screen (<= 1,280 each side) and frame count
/// (<= 300) are read from the headers; only the first frame is decoded.
ProcessedImage prepareGifSync(Uint8List picked) {
  checkGifBytes(picked);
  // Security L-4: drop the non-rendering blocks and trailing bytes
  // byte-level BEFORE anything else reads the file, so the frame count and
  // the MD5 below describe the bytes that are uploaded and published.
  final bytes = stripGifBytes(picked);
  final decoder = img.GifDecoder();
  final img.GifInfo? info;
  try {
    info = decoder.startDecode(bytes);
  } on img.ImageException {
    // A truncated or corrupt file that still starts with the signature.
    throw GifRefusedException.notGif;
  }
  if (info == null || info.numFrames < 1) throw GifRefusedException.notGif;
  if (info.width > kMaxGifEdge || info.height > kMaxGifEdge) {
    throw GifRefusedException.tooLarge;
  }
  if (info.numFrames > kMaxGifFrames) throw GifRefusedException.tooLong;
  final img.Image? frame;
  try {
    frame = decoder.decodeFrame(0);
  } on img.ImageException {
    throw GifRefusedException.notGif;
  }
  if (frame == null) throw GifRefusedException.notGif;

  final still = _flattenOnWhite(frame);
  final thumb = _encodeWithin(
    still,
    kPostThumbEdge,
    kMaxThumbBytes,
    quality: 70,
  );
  return ProcessedImage(
    fullBytes: bytes,
    thumbBytes: thumb.bytes,
    width: info.width,
    height: info.height,
    fullMd5: base64.encode(md5.convert(bytes).bytes),
    thumbMd5: base64.encode(md5.convert(thumb.bytes).bytes),
    blurhash: _blurhashOf(thumb.image),
    contentType: kGifContentType,
    thumbContentType: 'image/jpeg',
  );
}

class _Encoded {
  const _Encoded(this.image, this.bytes);
  final img.Image image;
  final Uint8List bytes;
}

/// Fits [source] into [edge] px on its longest side and encodes it at or
/// under [maxBytes]: quality steps down first, then the image shrinks. With
/// [threeToOne] [edge] is the width of a 3:1 band (a source that is exactly
/// 3:1) and every size stays exactly 3:1. The sizes come from
/// [encodeAttempts], shared with the web worker path.
_Encoded _encodeWithin(
  img.Image source,
  int edge,
  int maxBytes, {
  required int quality,
  bool threeToOne = false,
}) {
  var current = source;
  for (final attempt in encodeAttempts(
    source.width,
    source.height,
    edge,
    quality: quality,
    threeToOne: threeToOne,
  )) {
    if (attempt.width != current.width || attempt.height != current.height) {
      // Each smaller size is resized from the previous one, as before.
      current = img.copyResize(
        current,
        width: attempt.width,
        height: attempt.height,
        interpolation: img.Interpolation.average,
      );
    }
    final out = Uint8List.fromList(
      img.encodeJpg(current, quality: attempt.quality),
    );
    if (out.length <= maxBytes) return _Encoded(current, out);
  }
  throw const UnsupportedImageException('Image is too large to upload.');
}
