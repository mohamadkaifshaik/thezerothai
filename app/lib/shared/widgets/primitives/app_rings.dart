import 'package:flutter/material.dart';

/// Decorative concentric rings (dz.css `.ring`): 1dp strokes of [color] at
/// falling opacity around one centre. Paints behind the content, never takes
/// input and is excluded from semantics.
class AppRings extends StatelessWidget {
  const AppRings({
    super.key,
    required this.rings,
    required this.color,
    required this.centre,
  });

  /// (diameter, alpha) pairs from the inside out.
  final List<(double, double)> rings;
  final Color color;

  /// Where the rings sit inside the painted box, from its size.
  final Offset Function(Size size) centre;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ExcludeSemantics(
      child: CustomPaint(
        size: Size.infinite,
        painter: _RingsPainter(rings: rings, color: color, centre: centre),
      ),
    ),
  );
}

class _RingsPainter extends CustomPainter {
  const _RingsPainter({
    required this.rings,
    required this.color,
    required this.centre,
  });

  final List<(double, double)> rings;
  final Color color;
  final Offset Function(Size size) centre;

  @override
  void paint(Canvas canvas, Size size) {
    final at = centre(size);
    for (final (diameter, alpha) in rings) {
      canvas.drawCircle(
        at,
        diameter / 2,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = color.withValues(alpha: alpha),
      );
    }
  }

  @override
  bool shouldRepaint(_RingsPainter old) =>
      old.color != color || old.rings != rings || old.centre != centre;
}
