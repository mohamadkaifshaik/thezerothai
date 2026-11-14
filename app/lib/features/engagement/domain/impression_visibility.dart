import 'dart:ui' show Rect;

/// How long a card must stay mostly on screen before it counts as seen.
const kImpressionDwell = Duration(seconds: 1);

/// The share of a card (by height) that must be on screen.
const kImpressionVisibleFraction = 0.5;

/// Whether [item] is "mostly on screen" inside [viewport] (both in the same
/// coordinate space): at least [kImpressionVisibleFraction] of its height is
/// inside, or, for a card taller than the viewport, at least that fraction of
/// the viewport is covered by it. A card with no area is never visible.
bool isMostlyVisible(Rect item, Rect viewport) {
  if (item.width <= 0 || item.height <= 0) return false;
  final shown = item.intersect(viewport);
  if (shown.width <= 0 || shown.height <= 0) return false;
  final reference = item.height < viewport.height
      ? item.height
      : viewport.height;
  return shown.height >= kImpressionVisibleFraction * reference;
}
