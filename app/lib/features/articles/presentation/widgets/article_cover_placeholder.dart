import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';

/// The empty cover: a dashed teal drop with "Add cover image" (Article
/// mocks). It is the button that opens the picker; [onTap] null while busy.
class ArticleCoverPlaceholder extends StatelessWidget {
  const ArticleCoverPlaceholder({
    super.key,
    required this.height,
    required this.onTap,
  });

  final double height;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final radius = BorderRadius.circular(AppRadius.card);
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: 'Add cover image',
      excludeSemantics: true,
      onTap: onTap,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: height),
        child: CustomPaint(
          foregroundPainter: _DashedBorder(
            color: AppPalette.teal,
            radius: AppRadius.card,
          ),
          child: Material(
            color: AppPalette.teal.withValues(
              alpha: AppArticlesLayout.coverFillAlpha,
            ),
            borderRadius: radius,
            child: InkWell(
              borderRadius: radius,
              onTap: onTap,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.add_photo_alternate_outlined,
                        color: colors.accentText,
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        'Add cover image',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.labelLarge
                            ?.copyWith(color: colors.accentText),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DashedBorder extends CustomPainter {
  const _DashedBorder({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = AppArticlesLayout.coverBorder;
    final outline = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Offset.zero & size,
          Radius.circular(radius),
        ).deflate(AppArticlesLayout.coverBorder / 2),
      );
    for (final PathMetric metric in outline.computeMetrics()) {
      for (
        var at = 0.0;
        at < metric.length;
        at += AppArticlesLayout.coverDash + AppArticlesLayout.coverDashGap
      ) {
        canvas.drawPath(
          metric.extractPath(at, at + AppArticlesLayout.coverDash),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorder old) =>
      old.color != color || old.radius != radius;
}
