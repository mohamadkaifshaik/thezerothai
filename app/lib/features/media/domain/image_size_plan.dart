import 'dart:math' as math;

import 'image_processor.dart';
import 'processed_image.dart';

/// The size rules of [processImageSync] as pure integer math, so a processor
/// that draws with the browser (the web worker) produces exactly the sizes it
/// declares and the server verifies (B14: declared width x height equal the
/// encoded JPEG's SOF). Every function here mirrors a step of the
/// `package:image` path; keep them in step.

/// A source rectangle (in oriented source pixels).
typedef CropRect = ({int x, int y, int width, int height});

/// One encode attempt: draw the crop into [width] x [height], JPEG [quality].
typedef EncodeAttempt = ({int width, int height, int quality});

/// Per-purpose output rules.
class PurposeSpec {
  const PurposeSpec._({
    required this.fullEdge,
    required this.thumbEdge,
    required this.maxFullBytes,
    required this.maxThumbBytes,
    this.threeToOne = false,
  });

  final int fullEdge;
  final int thumbEdge;
  final int maxFullBytes;
  final int maxThumbBytes;

  /// A banner: every size is exactly width x width ~/ 3.
  final bool threeToOne;

  static const fullQuality = 80;
  static const thumbQuality = 70;

  static PurposeSpec of(ImagePurpose purpose) => switch (purpose) {
    ImagePurpose.post => const PurposeSpec._(
      fullEdge: kPostFullEdge,
      thumbEdge: kPostThumbEdge,
      maxFullBytes: kMaxFullBytes,
      maxThumbBytes: kMaxThumbBytes,
    ),
    ImagePurpose.avatar => const PurposeSpec._(
      fullEdge: kAvatarFullEdge,
      thumbEdge: kAvatarThumbEdge,
      maxFullBytes: kMaxFullBytes,
      maxThumbBytes: kMaxThumbBytes,
    ),
    ImagePurpose.banner => const PurposeSpec._(
      fullEdge: kBannerFullWidth,
      thumbEdge: kBannerThumbWidth,
      maxFullBytes: kMaxBannerFullBytes,
      maxThumbBytes: kMaxBannerThumbBytes,
      threeToOne: true,
    ),
  };
}

/// The smallest banner height worth cropping (as in [processImageSync]).
const kMinBannerHeight = 16;

/// The part of a [width] x [height] source a purpose keeps: the whole photo
/// for a post, the centered square for an avatar, the largest centered 3:1
/// band for a banner (refused when thinner than [kMinBannerHeight]).
CropRect cropFor(ImagePurpose purpose, int width, int height) {
  switch (purpose) {
    case ImagePurpose.post:
      return (x: 0, y: 0, width: width, height: height);
    case ImagePurpose.avatar:
      final side = math.min(width, height);
      return (
        x: (width - side) ~/ 2,
        y: (height - side) ~/ 2,
        width: side,
        height: side,
      );
    case ImagePurpose.banner:
      final h = math.min(height, width ~/ 3);
      if (h < kMinBannerHeight) throw const UnsupportedImageException();
      final w = h * 3;
      return (x: (width - w) ~/ 2, y: (height - h) ~/ 2, width: w, height: h);
  }
}

/// [width] x [height] fitted into [edge] on its longest side; never upscaled.
/// Rounds like `copyResize` with one side given.
({int width, int height}) fitWithin(
  int width,
  int height,
  int edge, {
  bool threeToOne = false,
}) {
  if (math.max(width, height) <= edge) return (width: width, height: height);
  if (threeToOne) return (width: edge, height: edge ~/ 3);
  if (width >= height) {
    return (width: edge, height: math.max(1, (edge * (height / width)).round()));
  }
  return (width: math.max(1, (edge * (width / height)).round()), height: edge);
}

/// The next, 75 % smaller size of the shrink ladder.
({int width, int height}) shrinkOnce(
  int width,
  int height, {
  bool threeToOne = false,
}) {
  if (threeToOne) {
    final w = math.max(3, (width * 0.75).round() ~/ 3 * 3);
    return (width: w, height: w ~/ 3);
  }
  final w = math.max(1, (width * 0.75).round());
  return (width: w, height: math.max(1, (w * (height / width)).round()));
}

/// Every attempt `_encodeWithin` makes, in order: fit into [edge], then
/// quality [quality] down to 40 in steps of 10, then shrink by 75 % (six
/// sizes in total). The first attempt whose JPEG fits the cap wins.
Iterable<EncodeAttempt> encodeAttempts(
  int width,
  int height,
  int edge, {
  required int quality,
  bool threeToOne = false,
}) sync* {
  var size = fitWithin(width, height, edge, threeToOne: threeToOne);
  for (var shrink = 0; shrink < 6; shrink++) {
    for (var q = quality; q >= 40; q -= 10) {
      yield (width: size.width, height: size.height, quality: q);
    }
    size = shrinkOnce(size.width, size.height, threeToOne: threeToOne);
  }
}

/// The BlurHash source size of a [width] x [height] thumbnail: longest side
/// 32, the other at least 1 px.
({int width, int height}) blurhashSize(int width, int height) {
  final longest = math.max(width, height);
  return (
    width: math.max(1, (width * 32 / longest).round()),
    height: math.max(1, (height * 32 / longest).round()),
  );
}
