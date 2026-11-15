import 'package:flutter/material.dart';

/// A small line over [values] (one point per day, oldest first), drawn with a
/// [CustomPainter]. Decorative: the tile around it carries the semantics. A
/// flat or single-point series is a straight line in the middle.
class InsightsSparkline extends StatelessWidget {
  const InsightsSparkline({
    super.key,
    required this.values,
    required this.color,
    this.width = 96,
    this.height = 32,
  });

  final List<int> values;
  final Color color;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: CustomPaint(
        size: Size(width, height),
        painter: SparklinePainter(values: values, color: color),
      ),
    );
  }
}

class SparklinePainter extends CustomPainter {
  SparklinePainter({required this.values, required this.color});

  final List<int> values;
  final Color color;

  static const double _stroke = 2;

  /// The points of the line in [size], x spread evenly, y scaled to the
  /// series' own min and max (inset by the stroke so the line is not clipped).
  List<Offset> points(Size size) {
    if (values.isEmpty) return const [];
    final lo = values.reduce((a, b) => a < b ? a : b);
    final hi = values.reduce((a, b) => a > b ? a : b);
    final span = hi - lo;
    final h = size.height - 2 * _stroke;
    return [
      for (var i = 0; i < values.length; i++)
        Offset(
          values.length == 1
              ? size.width / 2
              : size.width * i / (values.length - 1),
          span == 0
              ? size.height / 2
              : _stroke + h * (1 - (values[i] - lo) / span),
        ),
    ];
  }

  @override
  void paint(Canvas canvas, Size size) {
    final pts = points(size);
    if (pts.isEmpty) return;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    if (pts.length == 1) {
      canvas.drawLine(
        Offset(0, pts.first.dy),
        Offset(size.width, pts.first.dy),
        paint,
      );
      return;
    }
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (final p in pts.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(SparklinePainter old) =>
      old.color != color || !_same(old.values, values);

  static bool _same(List<int> a, List<int> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
