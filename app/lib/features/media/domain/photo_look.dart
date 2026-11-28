import 'dart:math' as math;

enum PhotoFilter {
  original('Original', 1, 1, 0),
  vivid('Vibrance', 1.35, 1.09, 0),
  warm('Warm', 1.12, 1.02, 13),
  cool('Cool', 1.05, 1.03, -13),
  sepia('Sepia', 0.23, 0.95, 27),
  mono('Mono', 0, 1.15, 0);

  const PhotoFilter(this.label, this.saturation, this.contrast, this.warmth);

  final String label;
  final double saturation;
  final double contrast;
  final double warmth;

  List<double> matrix(bool enhance) {
    final s = saturation * (enhance ? 1.18 : 1);
    final c = contrast * (enhance ? 1.08 : 1);
    final r = 0.2126 * (1 - s) * c;
    final g = 0.7152 * (1 - s) * c;
    final b = 0.0722 * (1 - s) * c;
    final offset = 127.5 * (1 - c) + (enhance ? 7 : 0);
    return [
      r + s * c,
      g,
      b,
      0,
      offset + warmth,
      r,
      g + s * c,
      b,
      0,
      offset,
      r,
      g,
      b + s * c,
      0,
      offset - warmth,
      0,
      0,
      0,
      1,
      0,
    ];
  }
}

enum StickerShape {
  star('Star', 0xffffc547),
  heart('Heart', 0xffef4f75),
  sparkle('Sparkle', 0xff72d8ff);

  const StickerShape(this.label, this.color);
  final String label;
  final int color;
}

/// The center is relative to the uncropped, rotated photo. The diameter is
/// relative to its shorter edge, so the artwork keeps its proportions.
typedef PhotoSticker = ({
  StickerShape shape,
  double x,
  double y,
  double size,
  double angle,
});

List<math.Point<double>> stickerOutline(
  PhotoSticker sticker,
  double width,
  double height,
) {
  final count = switch (sticker.shape) {
    StickerShape.star => 10,
    StickerShape.heart => 48,
    StickerShape.sparkle => 8,
  };
  final radius = sticker.size * math.min(width, height) / 2;
  final sin = math.sin(sticker.angle);
  final cos = math.cos(sticker.angle);
  return List.generate(count, (i) {
    final theta = i * 2 * math.pi / count;
    final double x;
    final double y;
    if (sticker.shape == StickerShape.heart) {
      x = math.pow(math.sin(theta), 3).toDouble();
      y =
          -(13 * math.cos(theta) -
              5 * math.cos(2 * theta) -
              2 * math.cos(3 * theta) -
              math.cos(4 * theta)) /
          17;
    } else {
      final factor = i.isEven ? 1.0 : 0.38;
      x = math.sin(theta) * factor;
      y = -math.cos(theta) * factor;
    }
    return math.Point(
      sticker.x * width + radius * (x * cos - y * sin),
      sticker.y * height + radius * (x * sin + y * cos),
    );
  });
}
