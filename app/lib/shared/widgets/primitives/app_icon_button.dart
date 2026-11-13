import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// A 48 x 48 icon button (dz.css `.iconbtn`). [raised] is the flat white disc
/// (`.iconbtn.raised`) with no shadow, like the Feed's pinned-timelines
/// button. A [tooltip] is required: it is the
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
        backgroundColor: raised ? AppPalette.white : null,
        foregroundColor: raised ? AppPalette.navy : null,
        disabledBackgroundColor: raised ? colors.disabledPillFill : null,
        disabledForegroundColor: colors.disabledPillLabel,
      ),
    );
    return button;
  }
}
