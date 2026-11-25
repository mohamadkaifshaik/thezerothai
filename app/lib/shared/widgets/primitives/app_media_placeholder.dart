import 'package:material_ui/material_ui.dart';

import '../../../core/icons/dz_icon.dart';
import '../../../core/icons/dz_icon_data.dart';
import '../../../core/icons/dz_icons.dart';
import '../../../core/theme/app_theme.dart';

/// A neutral stand-in for a picture that is loading, failed or missing: the
/// container surface of the theme ([AppPalette.lightContainerHigh] on light,
/// the dark container on dark) with an optional centred glyph. Never pastel
/// (the artboards' coloured placeholders are not shipped).
///
/// It fills the space it is given; wrap it in an `AspectRatio` or `SizedBox`.
/// Decorative by default; pass [semanticLabel] when it stands for content.
/// There is no animation, so it costs nothing in a long list.
class AppMediaPlaceholder extends StatelessWidget {
  const AppMediaPlaceholder({
    super.key,
    this.icon = DzIcons.image,
    this.iconSize = 28,
    this.borderRadius = BorderRadius.zero,
    this.semanticLabel,
  });

  /// The centred glyph; null draws none.
  final DzIconData? icon;
  final double iconSize;
  final BorderRadiusGeometry borderRadius;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final fill = dark
        ? AppPalette.darkContainer
        : AppPalette.lightContainerHigh;
    final glyph = dark ? AppPalette.mutedOnDark : AppPalette.mutedOnLight;
    final box = DecoratedBox(
      decoration: BoxDecoration(color: fill, borderRadius: borderRadius),
      child: icon == null
          ? const SizedBox.expand()
          : Center(
              child: DzIcon(icon!, size: iconSize, color: glyph),
            ),
    );
    if (semanticLabel == null) return ExcludeSemantics(child: box);
    return Semantics(label: semanticLabel, image: true, child: box);
  }
}
