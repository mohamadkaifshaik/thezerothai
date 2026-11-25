import 'package:material_ui/material_ui.dart';

import '../theme/app_theme.dart';
import 'dz_icon_data.dart';

/// Paints a [DzIconData] like `Icon`: [size] and [color] default to the
/// ambient `IconTheme`. The 24 x 24 grid is scaled to [size] together with the
/// stroke, as an SVG is.
///
/// [fill] (0 to 1) fills the shapes with [fillColor] (default [color]) at that
/// strength: 0 is the outline, 1 the "liked" / "saved" / active look. It is
/// the *target*: with a [fillDuration] the painted fill eases to it when it
/// changes (a toggle), and a first build shows it at once. Shapes marked
/// `filled` in the data (dots) are always filled.
///
/// A [semanticLabel] makes the icon an image with that label; without one it
/// is hidden from assistive technology (the usual case: its button carries
/// the label).
class DzIcon extends StatelessWidget {
  const DzIcon(
    this.data, {
    super.key,
    this.size,
    this.color,
    this.fill = 0,
    this.fillDuration = Duration.zero,
    this.fillColor,
    this.strokeWidth,
    this.semanticLabel,
  }) : assert(fill >= 0 && fill <= 1, 'fill is 0 to 1');

  final DzIconData data;
  final double? size;
  final Color? color;
  final double fill;

  /// How long the painted fill takes to reach [fill] when it changes; zero is
  /// instant (pass zero under reduce-motion).
  final Duration fillDuration;
  final Color? fillColor;

  /// Overrides the icon's own stroke width (on the 24 grid).
  final double? strokeWidth;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final iconTheme = IconTheme.of(context);
    final dimension = size ?? iconTheme.size ?? 24;
    var resolved = color ?? iconTheme.color ?? AppPalette.navy;
    final opacity = iconTheme.opacity;
    if (opacity != null && opacity != 1) {
      resolved = resolved.withValues(alpha: resolved.a * opacity);
    }
    Widget paint(double shown) => CustomPaint(
      painter: _DzIconPainter(
        data,
        color: resolved,
        fillColor: fillColor ?? resolved,
        fill: shown,
        strokeWidth: strokeWidth ?? data.strokeWidth,
      ),
    );
    final painted = SizedBox.square(
      dimension: dimension,
      child: fillDuration == Duration.zero
          ? paint(fill)
          : TweenAnimationBuilder<double>(
              tween: Tween(end: fill),
              duration: fillDuration,
              builder: (context, shown, _) => paint(shown),
            ),
    );
    if (semanticLabel == null) return ExcludeSemantics(child: painted);
    return Semantics(label: semanticLabel, image: true, child: painted);
  }
}

class _DzIconPainter extends CustomPainter {
  _DzIconPainter(
    this.data, {
    required this.color,
    required this.fillColor,
    required this.fill,
    required this.strokeWidth,
  });

  final DzIconData data;
  final Color color;
  final Color fillColor;
  final double fill;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final compiled = data.compiled;
    canvas.save();
    canvas.scale(size.width / DzIconData.grid, size.height / DzIconData.grid);
    final fillPaint = Paint()
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    if (fill > 0) {
      fillPaint.color = fillColor.withValues(alpha: fillColor.a * fill);
      canvas.drawPath(compiled.fill, fillPaint);
    }
    if (compiled.hasDots) {
      fillPaint.color = color;
      canvas.drawPath(compiled.dots, fillPaint);
    }
    canvas.drawPath(
      compiled.stroke,
      Paint()
        ..style = PaintingStyle.stroke
        ..isAntiAlias = true
        ..color = color
        ..strokeWidth = strokeWidth
        ..strokeCap = data.cap
        ..strokeJoin = data.join,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_DzIconPainter old) =>
      old.data != data ||
      old.color != color ||
      old.fillColor != fillColor ||
      old.fill != fill ||
      old.strokeWidth != strokeWidth;
}
