import 'package:material_ui/material_ui.dart';

import '../../../core/icons/dz_icon.dart';
import '../../../core/icons/dz_icon_data.dart';
import '../../../core/theme/app_theme.dart';

/// The floating action button of the redesigned phone screens, as the Dz
/// artboards draw it: a 58 dp circle in solid electric teal with a navy glyph
/// and the teal glow of [AppShadows.fab] (the compose button above the
/// floating bar, Messages' New message). It sits 16 dp from the side and
/// above the bar (the shell places it).
///
/// Pass [dzIcon] for the design's stroke glyph (24 dp, 2.2 stroke); [icon]
/// stays for callers that still hand over a Material glyph. Pressing shrinks
/// it a little (not under reduce-motion).
class AppGradientFab extends StatefulWidget {
  const AppGradientFab({
    super.key,
    required this.tooltip,
    this.icon,
    this.dzIcon,
    required this.onPressed,
  }) : assert(icon != null || dzIcon != null, 'give an icon or a dzIcon');

  final String tooltip;
  final IconData? icon;
  final DzIconData? dzIcon;
  final VoidCallback? onPressed;

  @override
  State<AppGradientFab> createState() => _AppGradientFabState();
}

class _AppGradientFabState extends State<AppGradientFab> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.disableAnimationsOf(context);
    const ink = AppPalette.navy;
    final dz = widget.dzIcon;
    return AnimatedScale(
      scale: _pressed && widget.onPressed != null ? 0.94 : 1,
      duration: reduce ? Duration.zero : const Duration(milliseconds: 80),
      child: DecoratedBox(
        decoration: const ShapeDecoration(
          shape: CircleBorder(),
          color: AppPalette.tealElectric,
          shadows: AppShadows.fab,
        ),
        child: Semantics(
          button: true,
          enabled: widget.onPressed != null,
          label: widget.tooltip,
          onTap: widget.onPressed,
          excludeSemantics: true,
          child: Tooltip(
            message: widget.tooltip,
            excludeFromSemantics: true,
            child: Material(
              type: MaterialType.transparency,
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkResponse(
                onTap: widget.onPressed,
                onHighlightChanged: (down) {
                  if (down != _pressed) setState(() => _pressed = down);
                },
                containedInkWell: true,
                highlightShape: BoxShape.circle,
                child: SizedBox.square(
                  dimension: AppSize.fabRedesign,
                  child: Center(
                    child: dz != null
                        ? DzIcon(dz, size: AppIconSize.lg, color: ink)
                        : Icon(widget.icon, size: AppIconSize.lg, color: ink),
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
