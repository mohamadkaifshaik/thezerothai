import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_router.dart';
import '../../../../core/theme/app_theme.dart';

/// The Feed top bar's "Pinned timelines" control (Feed design): a round 44 dp
/// flat white button (no shadow), inside a 48 dp hit area. Opens Manage
/// pinned. It lives in the bar, not at the end of the tab strip, so the tabs
/// keep the whole row.
class PinnedTimelinesButton extends StatelessWidget {
  const PinnedTimelinesButton({super.key});

  /// The disc; the hit area around it is [AppSpacing.minTapTarget].
  static const double diameter = 44;

  @override
  Widget build(BuildContext context) {
    const hit = Size.square(AppSpacing.minTapTarget);
    return SizedBox.fromSize(
      size: hit,
      child: Center(
        child: IconButton(
          tooltip: 'Manage pinned timelines',
          icon: const _PinnedGlyph(),
          onPressed: () => context.push(AppRouter.pinnedPath),
          style: IconButton.styleFrom(
            fixedSize: const Size.square(diameter),
            minimumSize: const Size.square(diameter),
            padding: EdgeInsets.zero,
            tapTargetSize: MaterialTapTargetSize.padded,
            shape: const CircleBorder(),
            backgroundColor: AppPalette.white,
            foregroundColor: AppPalette.navy,
          ),
        ),
      ),
    );
  }
}

/// The design's glyph: four short ticks around a gap
/// (`M12 3v4M12 17v4M3 12h4M17 12h4` on a 24 grid), 20 dp, 2 dp strokes with
/// round caps, in the icon colour.
class _PinnedGlyph extends StatelessWidget {
  const _PinnedGlyph();

  @override
  Widget build(BuildContext context) {
    final color = IconTheme.of(context).color ?? AppPalette.navy;
    return ExcludeSemantics(
      child: CustomPaint(
        size: const Size.square(AppIconSize.md),
        painter: _PinnedGlyphPainter(color),
      ),
    );
  }
}

class _PinnedGlyphPainter extends CustomPainter {
  const _PinnedGlyphPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final unit = size.width / 24;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2 * unit
      ..strokeCap = StrokeCap.round;
    void tick(double x1, double y1, double x2, double y2) => canvas.drawLine(
      Offset(x1 * unit, y1 * unit),
      Offset(x2 * unit, y2 * unit),
      paint,
    );
    tick(12, 3, 12, 7);
    tick(12, 17, 12, 21);
    tick(3, 12, 7, 12);
    tick(17, 12, 21, 12);
  }

  @override
  bool shouldRepaint(_PinnedGlyphPainter old) => old.color != color;
}
