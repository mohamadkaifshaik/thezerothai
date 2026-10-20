import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// The primary call to action of a screen (Post, Save): a pill with a
/// primary-to-tertiary gradient. Use it for primary CTAs only; secondary
/// actions stay on the themed Filled/Outlined/Text buttons.
///
/// Whether it is [busy] or disabled (`onPressed == null`) is the caller's
/// decision, from its own bloc state. Both ignore taps. It announces
/// [label] exactly once, as an enabled or disabled button.
class AppGradientButton extends StatelessWidget {
  const AppGradientButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final enabled = !busy && onPressed != null;
    final radius = BorderRadius.circular(AppRadius.pill);
    // The visual subtree is excluded from semantics and replaced by this one
    // node, so the label is spoken once (not once here and once from the Text).
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      onTap: enabled ? onPressed : null,
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        borderRadius: radius,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: radius,
            gradient: LinearGradient(
              colors: enabled
                  ? [colors.primary, colors.tertiary]
                  : [colors.onSurfaceVariant, colors.onSurfaceVariant],
            ),
          ),
          child: InkWell(
            borderRadius: radius,
            onTap: enabled ? onPressed : null,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: AppSpacing.minTapTarget,
                minWidth: AppSpacing.minButtonWidth,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg,
                  vertical: AppSpacing.sm,
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
                          color: colors.onPrimary,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                    ] else if (icon != null) ...[
                      Icon(icon, size: AppIconSize.md, color: colors.onPrimary),
                      const SizedBox(width: AppSpacing.sm),
                    ],
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: colors.onPrimary,
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
    );
  }
}
