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

enum ImagePurpose { post, avatar }

/// Turns picked bytes into an upload-ready [ProcessedImage]. An interface so
/// widget and cubit tests never decode real pixels.
abstract interface class ImageProcessor {
  Future<ProcessedImage> process(Uint8List bytes, ImagePurpose purpose);
}

/// Pure-Dart implementation that runs the decode/resize/encode work in a
/// background isolate (`compute`), so a 12 MP photo never janks the UI.
/// Works the same on Android, iOS and web.
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
/// - Avatars are center-cropped to a square first.
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
  if (avatar) {
    final side = math.min(source.width, source.height);
    source = img.copyCrop(
      source,
      x: (source.width - side) ~/ 2,
      y: (source.height - side) ~/ 2,
      width: side,
      height: side,
    );
  }
  final fullEdge = avatar ? kAvatarFullEdge : kPostFullEdge;
  final thumbEdge = avatar ? kAvatarThumbEdge : kPostThumbEdge;

  final full = _encodeWithin(source, fullEdge, kMaxFullBytes, quality: 80);
  final thumb = _encodeWithin(
    full.image,
    thumbEdge,
    kMaxThumbBytes,
    quality: 70,
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

class _Encoded {
  const _Encoded(this.image, this.bytes);
  final img.Image image;
  final Uint8List bytes;
}

/// Fits [source] into [edge] px on its longest side and encodes it at or
/// under [maxBytes]: quality steps down first, then the image shrinks.
_Encoded _encodeWithin(
  img.Image source,
  int edge,
  int maxBytes, {
  required int quality,
}) {
  var current = source;
  final longest = math.max(current.width, current.height);
  if (longest > edge) {
    current = img.copyResize(
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
    current = img.copyResize(
      current,
      width: math.max(1, (current.width * 0.75).round()),
      interpolation: img.Interpolation.average,
    );
  }
  throw const UnsupportedImageException('Image is too large to upload.');
}
