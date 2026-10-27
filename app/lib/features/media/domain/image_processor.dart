import 'dart:convert';
import 'dart:math' as math;

import 'package:blurhash_dart/blurhash_dart.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'processed_image.dart';

/// Size limits the signed URLs enforce (media.proto: full <= 2 MiB,
/// thumb <= 256 KiB).
const kMaxFullBytes = 2 * 1024 * 1024;
const kMaxThumbBytes = 256 * 1024;

/// Edge lengths per purpose (media-pipeline skill: post 1600/400, avatar
/// 400/96 center-cropped square).
const kPostFullEdge = 1600;
const kPostThumbEdge = 400;
const kAvatarFullEdge = 400;
const kAvatarThumbEdge = 96;

/// The banner (ADR-0024 D1): a center-cropped 3:1 band, full 1500 x 500 and
/// thumb 600 x 200, under the banner's own, tighter caps (1 MiB / 128 KiB).
/// The server checks the declared size: width <= 1500, height <= 500 and 3:1
/// within 2%; this processor produces exactly 3:1.
const kBannerFullWidth = 1500;
const kBannerThumbWidth = 600;
const kMaxBannerFullBytes = 1024 * 1024;
const kMaxBannerThumbBytes = 128 * 1024;

/// The smallest banner height worth cropping (a 48 x 16 band); anything
/// thinner is reported as unusable instead of upscaled.
const _kMinBannerHeight = 16;

enum ImagePurpose { post, avatar, banner }

/// Turns picked bytes into an upload-ready [ProcessedImage]. An interface so
/// widget and cubit tests never decode real pixels.
abstract interface class ImageProcessor {
  Future<ProcessedImage> process(Uint8List bytes, ImagePurpose purpose);
}

/// Pure-Dart implementation (`package:image`) that runs decode/resize/encode
/// through `compute`.
///
/// - Android and iOS: a background isolate, so a 12 MP photo does not block
///   the UI thread.
/// - Web: `compute` has no isolates there and runs on the main thread, so a
///   large photo can drop frames while it is processed (one image at a time,
///   see `AttachmentsCubit`). Accepted for Stage 0.
/// - HEIC/HEIF cannot be decoded by this package. iOS' picker hands back
///   JPEG; elsewhere such a file is reported as unsupported.
class IsolateImageProcessor implements ImageProcessor {
  const IsolateImageProcessor();

  @override
  Future<ProcessedImage> process(Uint8List bytes, ImagePurpose purpose) {
    return compute(_run, (bytes, purpose));
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
  if (source.hasAlpha || source.numChannels != 3) {
    final flat = img.Image(
      width: source.width,
      height: source.height,
      numChannels: 3,
    );
    img.fill(flat, color: img.ColorRgb8(255, 255, 255));
    img.compositeImage(flat, source);
    source = flat;
  }

  final avatar = purpose == ImagePurpose.avatar;
  final banner = purpose == ImagePurpose.banner;
  if (avatar) {
    final side = math.min(source.width, source.height);
    source = img.copyCrop(
      source,
      x: (source.width - side) ~/ 2,
      y: (source.height - side) ~/ 2,
      width: side,
      height: side,
    );
  } else if (banner) {
    source = _cropToBanner(source);
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

  final hashSource = img.copyResize(
    thumb.image,
    width: thumb.image.width >= thumb.image.height ? 32 : null,
    height: thumb.image.height > thumb.image.width ? 32 : null,
    interpolation: img.Interpolation.average,
  );
  final blurhash = BlurHash.encode(hashSource, numCompX: 4, numCompY: 3).hash;

  return ProcessedImage(
    fullBytes: full.bytes,
    thumbBytes: thumb.bytes,
    width: full.image.width,
    height: full.image.height,
    fullMd5: base64.encode(md5.convert(full.bytes).bytes),
    thumbMd5: base64.encode(md5.convert(thumb.bytes).bytes),
    blurhash: blurhash,
  );
}

/// The largest centered 3:1 crop of [source]: width is exactly three times
/// the height, so every later resize keeps the shape the server checks.
img.Image _cropToBanner(img.Image source) {
  final height = math.min(source.height, source.width ~/ 3);
  if (height < _kMinBannerHeight) throw const UnsupportedImageException();
  final width = height * 3;
  return img.copyCrop(
    source,
    x: (source.width - width) ~/ 2,
    y: (source.height - height) ~/ 2,
    width: width,
    height: height,
  );
}

/// [image] resized to [width] x [width] / 3 (never a rounded, off-shape size).
img.Image _resizeThreeToOne(img.Image image, int width) => img.copyResize(
  image,
  width: width,
  height: width ~/ 3,
  interpolation: img.Interpolation.average,
);

class _Encoded {
  const _Encoded(this.image, this.bytes);
  final img.Image image;
  final Uint8List bytes;
}

/// Fits [source] into [edge] px on its longest side and encodes it at or
/// under [maxBytes]: quality steps down first, then the image shrinks. With
/// [threeToOne] [edge] is the width of a 3:1 band (a source that is exactly
/// 3:1) and every size stays exactly 3:1.
_Encoded _encodeWithin(
  img.Image source,
  int edge,
  int maxBytes, {
  required int quality,
  bool threeToOne = false,
}) {
  var current = source;
  final longest = math.max(current.width, current.height);
  if (longest > edge) {
    current = threeToOne
        ? _resizeThreeToOne(current, edge)
        : img.copyResize(
            current,
            width: current.width >= current.height ? edge : null,
            height: current.height > current.width ? edge : null,
            interpolation: img.Interpolation.average,
          );
  }
  for (var shrink = 0; shrink < 6; shrink++) {
    for (var q = quality; q >= 40; q -= 10) {
      final out = Uint8List.fromList(img.encodeJpg(current, quality: q));
      if (out.length <= maxBytes) return _Encoded(current, out);
    }
    current = threeToOne
        ? _resizeThreeToOne(
            current,
            math.max(3, (current.width * 0.75).round() ~/ 3 * 3),
          )
        : img.copyResize(
            current,
            width: math.max(1, (current.width * 0.75).round()),
            interpolation: img.Interpolation.average,
          );
  }
  throw const UnsupportedImageException('Image is too large to upload.');
}
