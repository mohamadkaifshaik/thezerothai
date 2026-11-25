import 'package:material_ui/material_ui.dart';

import '../../../core/icons/dz_icon.dart';
import '../../../core/icons/dz_icon_data.dart';
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
    required IconData this.icon,
    this.size = AppSpacing.xxl,
    this.destructive = false,
  }) : dzIcon = null,
       radius = AppRadius.tile;

  /// The Dz settings-row tile: [size] 40, radius 12, the same teal tint, with
  /// a stroke icon from `DzIcons`.
  const AppTileIcon.dz({
    super.key,
    required DzIconData this.dzIcon,
    this.size = dzSize,
    this.destructive = false,
  }) : icon = null,
       radius = dzRadius;

  /// Strength of the tint over the surface.
  static const double tintAlpha = 0.12;

  /// The Dz tile (artboards: 40 dp, radius 12).
  static const double dzSize = 40;
  static const double dzRadius = 12;

  final IconData? icon;
  final DzIconData? dzIcon;
  final double size;
  final double radius;
  final bool destructive;

  /// The glyph colour for [context] (also the tint's base).
  static Color glyphColor(BuildContext context, {bool destructive = false}) =>
      destructive
      ? Theme.of(context).colorScheme.error
      : context.appColors.accentText;

  @override
  Widget build(BuildContext context) {
    final glyph = glyphColor(context, destructive: destructive);
    final dz = dzIcon;
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: glyph.withValues(alpha: tintAlpha),
          borderRadius: BorderRadius.circular(radius),
        ),
        child: dz != null
            ? Center(
                child: DzIcon(dz, size: AppIconSize.md, color: glyph),
              )
            : Icon(icon, size: AppIconSize.lg, color: glyph),
      ),
    );
  }
}
