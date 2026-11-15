import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'image_size_plan.dart';

/// What the user did to a photo in the editor, applied to the SOURCE before it
/// is processed, so the server receives (and verifies, B14) real pixels.
///
/// The order is fixed: the EXIF orientation is baked in, the photo is rotated
/// by [quarterTurns] clockwise, then the crop is taken from the ROTATED photo
/// (so what the user saw is what is kept). The crop is stored as fractions of
/// the rotated photo ([left] < [right], [top] < [bottom], all in 0..1), so it
/// does not depend on the size the editor happened to decode.
@immutable
class PhotoEdit {
  const PhotoEdit({
    this.quarterTurns = 0,
    this.left = 0,
    this.top = 0,
    this.right = 1,
    this.bottom = 1,
  }) : assert(quarterTurns >= 0 && quarterTurns < 4);

  static const PhotoEdit none = PhotoEdit();

  /// Clockwise quarter turns, 0..3.
  final int quarterTurns;
  final double left;
  final double top;
  final double right;
  final double bottom;

  bool get hasCrop => left > 0 || top > 0 || right < 1 || bottom < 1;

  /// True when processing with this edit equals processing without one.
  bool get isIdentity => quarterTurns == 0 && !hasCrop;

  CropFractions get box => (left: left, top: top, right: right, bottom: bottom);

  PhotoEdit withBox(CropFractions b) => PhotoEdit(
    quarterTurns: quarterTurns,
    left: b.left,
    top: b.top,
    right: b.right,
    bottom: b.bottom,
  );

  /// One more clockwise turn; the crop starts over (it was drawn on the
  /// previous orientation).
  PhotoEdit rotated() => PhotoEdit(quarterTurns: (quarterTurns + 1) % 4);

  @override
  bool operator ==(Object other) =>
      other is PhotoEdit &&
      other.quarterTurns == quarterTurns &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(quarterTurns, left, top, right, bottom);
}

/// The size of a [width] x [height] photo after [quarterTurns] turns.
({int width, int height}) rotatedSize(
  int width,
  int height,
  int quarterTurns,
) => quarterTurns.isOdd
    ? (width: height, height: width)
    : (width: width, height: height);

/// The pixel crop of [edit] on a photo whose ROTATED size is [width] x
/// [height]: integers, at least 1 x 1, always inside the photo. Both
/// processing paths use this one function, so they keep the same pixels and
/// declare the same size.
CropRect editCropRect(PhotoEdit edit, int width, int height) {
  final x = (edit.left * width).round().clamp(0, width - 1);
  final y = (edit.top * height).round().clamp(0, height - 1);
  final x2 = (edit.right * width).round().clamp(x + 1, width);
  final y2 = (edit.bottom * height).round().clamp(y + 1, height);
  return (x: x, y: y, width: x2 - x, height: y2 - y);
}

/// The aspect choices of the editor.
enum CropPreset {
  original('Original', null),
  square('Square', 1),
  fourFive('4:5', 4 / 5),
  sixteenNine('16:9', 16 / 9);

  const CropPreset(this.label, this.ratio);
  final String label;

  /// Width / height; null keeps the photo's own shape.
  final double? ratio;
}

/// A crop box in fractions of the (rotated) photo.
typedef CropFractions = ({
  double left,
  double top,
  double right,
  double bottom,
});

const CropFractions kFullCrop = (left: 0, top: 0, right: 1, bottom: 1);

/// The smallest crop side, as a fraction of the photo.
const double kMinCropSide = 0.1;

/// [box] forced inside the photo with sides of at least [kMinCropSide].
CropFractions normalizeCrop(CropFractions box) {
  var w = (box.right - box.left).clamp(kMinCropSide, 1.0);
  var h = (box.bottom - box.top).clamp(kMinCropSide, 1.0);
  final left = box.left.clamp(0.0, 1 - w);
  final top = box.top.clamp(0.0, 1 - h);
  return (left: left, top: top, right: left + w, bottom: top + h);
}

/// The biggest box of [ratio] (width / height in PIXELS) that fits a photo of
/// [photoAspect] (its width / height), centred on [around]. A null ratio is
/// the whole photo.
CropFractions fitPreset(
  double? ratio,
  double photoAspect, {
  CropFractions around = kFullCrop,
}) {
  if (ratio == null) return kFullCrop;
  // In fractions: (w * photoAspect) / h = ratio.
  var w = 1.0;
  var h = photoAspect / ratio;
  if (h > 1) {
    h = 1;
    w = ratio / photoAspect;
  }
  final cx = (around.left + around.right) / 2;
  final cy = (around.top + around.bottom) / 2;
  final left = (cx - w / 2).clamp(0.0, 1 - w);
  final top = (cy - h / 2).clamp(0.0, 1 - h);
  return (left: left, top: top, right: left + w, bottom: top + h);
}

/// [box] moved by ([dx], [dy]) fractions, kept inside the photo.
CropFractions moveCrop(CropFractions box, double dx, double dy) {
  final w = box.right - box.left;
  final h = box.bottom - box.top;
  final left = (box.left + dx).clamp(0.0, 1 - w);
  final top = (box.top + dy).clamp(0.0, 1 - h);
  return (left: left, top: top, right: left + w, bottom: top + h);
}

/// [box] scaled by [factor] about its centre (a pinch or a Larger / Smaller
/// action): the shape is kept, the box stays inside the photo and at least
/// [kMinCropSide] on each side.
CropFractions zoomCrop(CropFractions box, double factor) {
  final w = box.right - box.left;
  final h = box.bottom - box.top;
  final cx = (box.left + box.right) / 2;
  final cy = (box.top + box.bottom) / 2;
  final maxByEdge = math.min(
    2 * math.min(cx, 1 - cx) / w,
    2 * math.min(cy, 1 - cy) / h,
  );
  final minByMin = math.max(kMinCropSide / w, kMinCropSide / h);
  final f = factor.clamp(minByMin, math.max(minByMin, maxByEdge));
  return normalizeCrop((
    left: cx - w * f / 2,
    top: cy - h * f / 2,
    right: cx + w * f / 2,
    bottom: cy + h * f / 2,
  ));
}

/// Which corner a handle drags.
enum CropHandle { topLeft, topRight, bottomLeft, bottomRight }

/// [box] with [handle] dragged by ([dx], [dy]) fractions. The opposite corner
/// stays put. With [ratio] (the box's pixel width / height) the shape is kept;
/// without it the corner moves freely. The result stays inside the photo and
/// at least [kMinCropSide] on each side.
CropFractions dragHandle(
  CropFractions box,
  CropHandle handle,
  double dx,
  double dy, {
  double? ratio,
  double photoAspect = 1,
}) {
  final movesLeft =
      handle == CropHandle.topLeft || handle == CropHandle.bottomLeft;
  final movesTop =
      handle == CropHandle.topLeft || handle == CropHandle.topRight;
  final fixedX = movesLeft ? box.right : box.left;
  final fixedY = movesTop ? box.bottom : box.top;
  final x = ((movesLeft ? box.left : box.right) + dx).clamp(0.0, 1.0);
  final y = ((movesTop ? box.top : box.bottom) + dy).clamp(0.0, 1.0);
  final maxW = movesLeft ? fixedX : 1 - fixedX;
  final maxH = movesTop ? fixedY : 1 - fixedY;
  var w = (movesLeft ? fixedX - x : x - fixedX).clamp(0.0, maxW);
  var h = (movesTop ? fixedY - y : y - fixedY).clamp(0.0, maxH);
  if (ratio != null) {
    // Fractions: w * photoAspect / h = ratio. Follow the larger move.
    if (dx.abs() * photoAspect >= dy.abs()) {
      h = w * photoAspect / ratio;
    } else {
      w = h * ratio / photoAspect;
    }
    final scale = math.min(1.0, math.min(maxW / w, maxH / h));
    if (scale.isFinite) {
      w *= scale;
      h *= scale;
    }
  }
  // Too small to keep (or no room beside the fixed corner): hold the minimum.
  w = math.max(w, math.min(kMinCropSide, maxW));
  h = math.max(h, math.min(kMinCropSide, maxH));
  final left = movesLeft ? fixedX - w : fixedX;
  final top = movesTop ? fixedY - h : fixedY;
  return normalizeCrop((
    left: left,
    top: top,
    right: left + w,
    bottom: top + h,
  ));
}
