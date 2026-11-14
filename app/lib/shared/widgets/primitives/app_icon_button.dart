import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// A 48 x 48 icon button (dz.css `.iconbtn`). [raised] is the flat white disc
/// (`.iconbtn.raised`) with no shadow, like the Feed's pinned-timelines
/// button, in light mode only: in dark mode a white disc glares, so a raised
/// button is the plain grey icon of an unraised one (owner, 2026-11-14:
/// match the Explore header's Settings). A [tooltip] is required: it is the
/// semantics label and the long-press hint.
class AppIconButton extends StatelessWidget {
  const AppIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.raised = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool raised;

  @override
  Widget build(BuildContext context) {
    const target = Size(AppSpacing.minTapTarget, AppSpacing.minTapTarget);
    final colors = context.appColors;
    final disc = raised && Theme.of(context).brightness == Brightness.light;
    final button = IconButton(
      icon: Icon(icon),
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        minimumSize: target,
        fixedSize: target,
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.padded,
        shape: const CircleBorder(),
        backgroundColor: disc ? AppPalette.white : null,
        foregroundColor: disc ? AppPalette.navy : null,
        disabledBackgroundColor: disc ? colors.disabledPillFill : null,
        disabledForegroundColor: colors.disabledPillLabel,
      ),
    );
    return button;
  }
}
