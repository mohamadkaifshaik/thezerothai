import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// The opacity of a teal tint (dz.css `.badge`: teal at 14 %).
const double _tintAlpha = 0.14;

/// The tone of an [AppTintBadge].
enum AppTintTone {
  /// Accent label on a 14 % teal tint (4.99:1 on light, higher on dark).
  accent,

  /// Muted label on a raised surface step (a neutral status).
  neutral,
}

/// A small full-round tinted label (dz.css `.badge`): 12 sp w700, tokens only.
///
/// It is a minimum-height box ([minHeight]) that grows with the text scale,
/// never a fixed box. By default it carries its [label] as semantics; pass
/// [excludeSemantics] when the parent row speaks the label itself.
class AppTintBadge extends StatelessWidget {
  const AppTintBadge({
    super.key,
    required this.label,
    this.tone = AppTintTone.accent,
    this.excludeSemantics = false,
    this.maxLines = 1,
  });

  final String label;
  final AppTintTone tone;

  /// Leave the badge out of the semantics tree (the parent announces it).
  final bool excludeSemantics;

  /// The label wraps up to this many lines, then ellipsises.
  final int maxLines;

  /// Minimum badge height (dp); it grows with the text.
  static const double minHeight = 24;

  /// The accent fill composited over [surface] (opaque), so a contrast check
  /// can read it.
  static Color accentFill(Color surface) =>
      Color.alphaBlend(AppPalette.teal.withValues(alpha: _tintAlpha), surface);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.appColors;
    final accent = tone == AppTintTone.accent;
    final fill = accent
        ? AppPalette.teal.withValues(alpha: _tintAlpha)
        : theme.colorScheme.surfaceContainerHigh;
    final labelColor = accent ? colors.accentText : colors.secondaryOnRaised;
    final badge = Container(
      constraints: const BoxConstraints(minHeight: minHeight),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs / 2,
      ),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        label,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall?.copyWith(
          color: labelColor,
          fontWeight: AppTypeTokens.weightUi,
        ),
      ),
    );
    if (excludeSemantics) return ExcludeSemantics(child: badge);
    return Semantics(
      label: label,
      container: true,
      child: ExcludeSemantics(child: badge),
    );
  }
}

/// A count badge (dz.css `.count`): navy with a pearl count on light, pearl
/// with a navy count on dark; "99+" above [max]. Empty when [count] is 0.
///
/// [semanticsLabel] is required ("3 unread notifications"): the digits alone
/// say nothing. Set [onNavy] over a navy surface (the floating bar), where
/// the badge inverts so it stays visible.
class AppCountBadge extends StatelessWidget {
  const AppCountBadge({
    super.key,
    required this.count,
    required this.semanticsLabel,
    this.max = 99,
    this.onNavy = false,
  });

  final int count;
  final String semanticsLabel;

  /// Counts above this show as "max+".
  final int max;
  final bool onNavy;

  /// Minimum width and height (dp); both grow with the text scale.
  static const double minSize = 22;

  /// The text for [count] ("99+" above [max]).
  static String format(int count, {int max = 99}) =>
      count > max ? '$max+' : '$count';

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final colors = context.appColors;
    // On a normal surface the theme's strong-pill pair; over navy it inverts.
    final fill = onNavy ? AppPalette.pearl : colors.strongPillFill;
    final labelColor = onNavy ? AppPalette.navy : colors.strongPillLabel;
    return Semantics(
      label: semanticsLabel,
      container: true,
      child: ExcludeSemantics(
        child: Container(
          constraints: const BoxConstraints(
            minWidth: minSize,
            minHeight: minSize,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 7),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          child: Text(
            format(count, max: max),
            maxLines: 1,
            style: theme.textTheme.labelSmall?.copyWith(
              color: labelColor,
              fontWeight: AppTypeTokens.weightUi,
            ),
          ),
        ),
      ),
    );
  }
}

/// The unread dot (dz.css `.dot`): 8 dp teal with a 2 dp ring in the page
/// colour so it separates from the glyph it sits on. [semanticsLabel] is
/// required ("Unread"); the dot is never the only carrier of the state, the
/// row text or a count also says it.
class AppUnreadDot extends StatelessWidget {
  const AppUnreadDot({super.key, required this.semanticsLabel, this.ringColor});

  final String semanticsLabel;

  /// The colour behind the dot; the theme surface when null.
  final Color? ringColor;

  /// Diameter of the teal core (dp).
  static const double size = 8;

  /// Width of the page-colour ring (dp).
  static const double ring = 2;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: semanticsLabel,
      container: true,
      child: ExcludeSemantics(
        child: Container(
          width: size + ring * 2,
          height: size + ring * 2,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: ringColor ?? theme.colorScheme.surface,
            shape: BoxShape.circle,
          ),
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: context.appColors.accentText,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    );
  }
}
