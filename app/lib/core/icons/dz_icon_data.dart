import 'dart:ui';

import 'svg_path_parser.dart';

/// One drawn element of an icon on the 24 x 24 grid: a path, a circle or a
/// rounded rect, as the design's inline `<svg>` elements are.
sealed class DzShape {
  const DzShape({this.filled = false, this.stroked = true});

  /// Always filled with the icon colour (a dot), whatever the icon's fill
  /// state.
  final bool filled;

  /// Drawn with the icon's stroke. False for the three "more" dots, which
  /// the design fills without a stroke.
  final bool stroked;

  void addTo(Path path);
}

/// `<path d="...">`.
class DzPathShape extends DzShape {
  const DzPathShape(this.d, {super.filled, super.stroked});

  final String d;

  @override
  void addTo(Path path) => path.addPath(parseSvgPath(d), Offset.zero);
}

/// `<circle cx cy r>`.
class DzCircleShape extends DzShape {
  const DzCircleShape(this.cx, this.cy, this.r, {super.filled, super.stroked});

  final double cx, cy, r;

  @override
  void addTo(Path path) =>
      path.addOval(Rect.fromCircle(center: Offset(cx, cy), radius: r));
}

/// `<rect x y width height rx>`.
class DzRectShape extends DzShape {
  const DzRectShape(
    this.x,
    this.y,
    this.width,
    this.height, {
    this.rx = 0,
    super.filled,
    super.stroked,
  });

  final double x, y, width, height, rx;

  @override
  void addTo(Path path) => path.addRRect(
    RRect.fromRectAndRadius(
      Rect.fromLTWH(x, y, width, height),
      Radius.circular(rx),
    ),
  );
}

/// A stroke icon: shapes on a 24 x 24 grid plus the stroke attributes the
/// artboard gives it. Const, so icon sets are plain constants; the parsed
/// [Path]s are built once per icon ([compiled]) and reused by every frame.
class DzIconData {
  const DzIconData(
    this.shapes, {
    this.strokeWidth = 2,
    this.cap = StrokeCap.butt,
    this.join = StrokeJoin.round,
  });

  final List<DzShape> shapes;

  /// Stroke width on the 24 grid (the artboards use 1.8 to 2.2).
  final double strokeWidth;
  final StrokeCap cap;
  final StrokeJoin join;

  /// The grid the shapes are drawn on.
  static const double grid = 24;

  static final Expando<DzCompiledIcon> _cache = Expando('DzIconData');

  /// The parsed paths; computed on first use, then cached for the process.
  DzCompiledIcon get compiled => _cache[this] ??= DzCompiledIcon._(this);
}

/// The parsed form of a [DzIconData]: [stroke] (every stroked shape), [fill]
/// (everything, for the filled "liked" / "saved" / active states) and [dots]
/// (shapes that are always filled).
class DzCompiledIcon {
  DzCompiledIcon._(DzIconData data)
    : stroke = _build(data, (s) => s.stroked),
      fill = _build(data, (s) => !s.filled),
      dots = _build(data, (s) => s.filled);

  final Path stroke;
  final Path fill;
  final Path dots;

  late final bool hasDots = !dots.getBounds().isEmpty;

  static Path _build(DzIconData data, bool Function(DzShape) test) {
    final path = Path();
    for (final shape in data.shapes) {
      if (test(shape)) shape.addTo(path);
    }
    return path;
  }
}
