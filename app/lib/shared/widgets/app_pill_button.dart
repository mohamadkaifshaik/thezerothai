import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// The primary call to action of a screen (Post, Save, Continue): X's strong
/// (inverse) pill: a light pill on dark, a dark pill on light, flat, no
/// gradient. Use it for primary CTAs only; secondary actions stay on the
/// themed Filled/Outlined/Text buttons (the themed `FilledButton` has the same
/// look but no busy state).
///
/// Whether it is [busy] or disabled (`onPressed == null`) is the caller's
/// decision, from its own bloc state. Both ignore taps and show the flat
/// disabled pill. It announces [label] exactly once, as an enabled or disabled
/// button.
///
/// [compact] draws a 36dp pill (header and composer buttons) inside the same
/// 48dp tap target; the default is a 48dp pill (forms).
class AppPillButton extends StatelessWidget {
  const AppPillButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.busy = false,
    this.compact = false,
    this.busySemanticsLabel,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool busy;
  final bool compact;

  /// While [busy], announced instead of [label] as a live region ("Sending
  /// reply"); the visible text stays [label].
  final String? busySemanticsLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.appColors;
    final enabled = !busy && onPressed != null;
    final announceBusy = busy && busySemanticsLabel != null;
    final radius = BorderRadius.circular(AppRadius.pill);
    final fill = enabled ? colors.strongPillFill : colors.disabledPillFill;
    final labelColor = enabled
        ? colors.strongPillLabel
        : colors.disabledPillLabel;
    final pillHeight = compact ? AppSize.pillCompact : AppSpacing.minTapTarget;
    // A compact pill is centred (and shrinks) inside its 48dp tap box; the
    // regular pill fills the width its parent gives it (forms).
    Widget wrap({required Widget child}) =>
        compact ? Center(widthFactor: 1, heightFactor: 1, child: child) : child;
    // The visual subtree is excluded from semantics and replaced by this one
    // node, so the label is spoken once (not once here and once from the Text).
    return Semantics(
      button: true,
      enabled: enabled,
      liveRegion: announceBusy,
      label: announceBusy ? busySemanticsLabel : label,
      onTap: enabled ? onPressed : null,
      excludeSemantics: true,
      child: ConstrainedBox(
        // The tap target is 48dp even when the pill is 36dp.
        constraints: const BoxConstraints(
          minHeight: AppSpacing.minTapTarget,
          minWidth: AppSpacing.minButtonWidth,
        ),
        child: wrap(
          child: Material(
            type: MaterialType.transparency,
            borderRadius: radius,
            child: Ink(
              decoration: BoxDecoration(borderRadius: radius, color: fill),
              child: InkWell(
                borderRadius: radius,
                onTap: enabled ? onPressed : null,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: pillHeight,
                    minWidth: AppSpacing.minButtonWidth,
                  ),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: compact ? AppSpacing.md : AppSpacing.lg,
                      vertical: AppSpacing.xs,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (busy) ...[
                          SizedBox(
                            width: AppIconSize.md,
                            height: AppIconSize.md,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: labelColor,
                            ),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                        ] else if (icon != null) ...[
                          Icon(icon, size: AppIconSize.md, color: labelColor),
                          const SizedBox(width: AppSpacing.sm),
                        ],
                        Flexible(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: labelColor,
                            ),
                          ),
                        ),
                      ],
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
