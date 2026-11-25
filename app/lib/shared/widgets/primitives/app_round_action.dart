import 'package:material_ui/material_ui.dart';

import '../../../core/icons/dz_icon.dart';
import '../../../core/icons/dz_icon_data.dart';
import '../../../core/theme/app_theme.dart';

/// The round header action of the Dz artboards: a 44 dp white disc with the
/// soft shadow ([AppShadows.softRaised]) and a 20 dp stroke icon in navy.
/// Used at the end of a screen header (My plans, Notification settings...).
///
/// A [tooltip] is required: it is the semantics label and the long-press hint.
/// In dark mode the disc is the raised surface and carries no shadow (a white
/// disc glares). Pressing shrinks it a little (not under reduce-motion). A
/// null [onPressed] dims it.
class AppRoundAction extends StatefulWidget {
  const AppRoundAction({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.size = 44,
    this.iconSize = 20,
  });

  final DzIconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  /// Disc diameter (the artboards use 44).
  final double size;
  final double iconSize;

  @override
  State<AppRoundAction> createState() => _AppRoundActionState();
}

class _AppRoundActionState extends State<AppRoundAction> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final light = theme.brightness == Brightness.light;
    final reduce = MediaQuery.disableAnimationsOf(context);
    final enabled = widget.onPressed != null;
    final fill = light
        ? AppPalette.white
        : theme.colorScheme.surfaceContainerHigh;
    final ink = light ? AppPalette.navy : theme.colorScheme.onSurface;
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.tooltip,
      onTap: widget.onPressed,
      excludeSemantics: true,
      child: Tooltip(
        message: widget.tooltip,
        excludeFromSemantics: true,
        child: AnimatedScale(
          scale: _pressed && enabled ? 0.92 : 1,
          duration: reduce ? Duration.zero : const Duration(milliseconds: 80),
          child: DecoratedBox(
            decoration: ShapeDecoration(
              shape: const CircleBorder(),
              shadows: light && enabled ? AppShadows.softRaised : null,
            ),
            child: Material(
              color: fill,
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
                  dimension: widget.size,
                  child: Center(
                    child: DzIcon(
                      widget.icon,
                      size: widget.iconSize,
                      color: enabled ? ink : ink.withValues(alpha: 0.4),
                    ),
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
