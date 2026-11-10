import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// The default tile of a List or a Community and the leading tile of a
/// settings row: a rounded square (`tile` radius) with a 12 % teal tint and
/// the [icon] in the accent text colour (tealText on light, electric teal on
/// dark). A [destructive] tile tints with the error colour instead.
/// Decorative: it carries no semantics of its own, the row beside it names
/// the thing.
class AppTileIcon extends StatelessWidget {
  const AppTileIcon({
    super.key,
    required this.icon,
    this.size = AppSpacing.xxl,
    this.destructive = false,
  });

  /// Strength of the tint over the surface.
  static const double tintAlpha = 0.12;

  final IconData icon;
  final double size;
  final bool destructive;

  /// The glyph colour for [context] (also the tint's base).
  static Color glyphColor(BuildContext context, {bool destructive = false}) =>
      destructive
      ? Theme.of(context).colorScheme.error
      : context.appColors.accentText;

  @override
  Widget build(BuildContext context) {
    final glyph = glyphColor(context, destructive: destructive);
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: glyph.withValues(alpha: tintAlpha),
          borderRadius: BorderRadius.circular(AppRadius.tile),
        ),
        child: Icon(icon, size: AppIconSize.lg, color: glyph),
      ),
    );
  }
}
