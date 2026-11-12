import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// Characters left in a text field (negative once over the limit, e.g. `-1`
/// for 281 of 280). Announced as "Characters remaining: N" / "Characters over
/// the limit: N" instead of the bare number. Used by the composer, the reply
/// composer and Edit profile (as `InputDecoration.counter`).
///
/// With [limit] set the visible text is the used count against it, "7 / 25"
/// (the poll builder's choices); the spoken label is unchanged.
///
/// [CharacterCounter.ring] (the reply composer) draws the share of [ringOf]
/// used as a ring before the bare remaining count; the spoken label is the
/// same.
class CharacterCounter extends StatelessWidget {
  const CharacterCounter({super.key, required this.remaining, this.limit})
    : ringOf = null,
      ringSize = 0;

  /// The ring style: [ringOf] is the field's limit, [ringSize] the ring's
  /// diameter.
  const CharacterCounter.ring({
    super.key,
    required this.remaining,
    required int this.ringOf,
    this.ringSize = AppSize.counterRing,
  }) : limit = null;

  final int remaining;

  /// The field's limit; null shows the bare remaining count.
  final int? limit;

  /// The limit the ring measures against; null draws no ring.
  final int? ringOf;

  final double ringSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final over = remaining < 0;
    final label = over
        ? 'Characters over the limit: ${-remaining}'
        : 'Characters remaining: $remaining';
    final shown = limit == null
        ? '$remaining'
        : '${limit! - remaining} / $limit';
    final color = over
        ? theme.colorScheme.error
        : theme.colorScheme.onSurfaceVariant;
    final text = Text(
      shown,
      style: theme.textTheme.labelLarge?.copyWith(color: color),
    );
    final max = ringOf;
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: max == null
          ? text
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox.square(
                  dimension: ringSize,
                  child: CustomPaint(
                    painter: _RingPainter(
                      used: max <= 0 ? 1 : (max - remaining) / max,
                      fill: over ? theme.colorScheme.error : AppPalette.teal,
                      track: theme.colorScheme.outlineVariant,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.smd),
                text,
              ],
            ),
    );
  }
}

/// A filled pie of [used] (0-1) in [fill] over a [track] disc (the mock's
/// `conic-gradient(teal 0 N%, line 0)`).
class _RingPainter extends CustomPainter {
  _RingPainter({required this.used, required this.fill, required this.track});

  final double used;
  final Color fill;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawOval(rect, Paint()..color = track);
    final sweep = used.clamp(0.0, 1.0) * 2 * math.pi;
    if (sweep > 0) {
      canvas.drawArc(rect, -math.pi / 2, sweep, true, Paint()..color = fill);
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.used != used || old.fill != fill || old.track != track;
}
