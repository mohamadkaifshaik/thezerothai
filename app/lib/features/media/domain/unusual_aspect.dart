/// A photo wider or taller than this many times its other side is "unusually
/// shaped" (width / height below 1/20 or above 20): the composer tells a
/// lone such photo it will be cropped in the feed. The feed itself crops a
/// single photo beyond 9:16 .. 3:1 (`PostMedia.frameAspect`); 1:20 is a
/// deliberately narrower, owner-chosen line for "very thin", so slightly
/// tall or wide photos are not nagged about.
const int kUnusualAspectMax = 20;

/// Which way an unusually shaped photo is stretched.
enum UnusualShape {
  /// Much taller than wide (width / height < 1/20).
  narrow,

  /// Much wider than tall (width / height > 20).
  wide,
}

/// The unusual shape of a photo of [width] x [height] pixels (the processed,
/// post-EXIF size), or null when it is shaped normally. GIFs and unknown
/// sizes (a side of 0 or less) are never unusual. Exactly 1:20 and 20:1 are
/// still normal. Integer math, so no rounding at the edges.
UnusualShape? unusualShapeOf({
  required int width,
  required int height,
  bool isGif = false,
}) {
  if (isGif || width <= 0 || height <= 0) return null;
  if (width * kUnusualAspectMax < height) return UnusualShape.narrow;
  if (width > height * kUnusualAspectMax) return UnusualShape.wide;
  return null;
}
