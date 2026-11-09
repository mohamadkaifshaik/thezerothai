import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// How an [AppPillButton] is filled (dz.css `.btn.*`).
enum AppButtonVariant {
  /// The gradient call to action: teal gradient, navy label, static glow.
  primary,

  /// The inverse pill: navy on light, pearl on dark.
  navy,

  /// Transparent with a 1.5dp boundary (>= 3:1) and a themed label.
  outline,

  /// No fill and no boundary: an accent-coloured label.
  text,

  /// Destructive: `#B42318` fill with a white label in both themes.
  danger,

  /// A white pill with a soft shadow, for use on photos and dark surfaces.
  white,
}

/// The height of an [AppPillButton] (dz.css `.btn` and `.btn.lg`).
enum AppButtonSize {
  regular(AppSpacing.minTapTarget),
  large(52);

  const AppButtonSize(this.height);
  final double height;
}

/// The button primitive of a screen (Post, Save, Continue, Delete).
///
/// The default [variant] is [AppButtonVariant.primary], the call to action.
///
/// Whether it is [busy] or disabled (`onPressed == null`) is the caller's
/// decision, from its own bloc state. Both ignore taps and show the flat
/// disabled pill (outline and text keep their shape). It announces [label]
/// exactly once, as an enabled or disabled button.
///
/// [compact] draws a 36dp pill (header and composer buttons) inside the same
/// 48dp tap target; the default is a [size] tall pill (forms). The label wraps
/// and the button grows at large text scales; it is never ellipsised.
class AppPillButton extends StatelessWidget {
  const AppPillButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.busy = false,
    this.compact = false,
    this.busySemanticsLabel,
    this.variant = AppButtonVariant.primary,
    this.size = AppButtonSize.regular,
    this.singleLine = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool busy;
  final bool compact;

  /// While [busy], announced instead of [label] as a live region ("Sending
  /// reply"); the visible text stays [label].
  final String? busySemanticsLabel;

  final AppButtonVariant variant;
  final AppButtonSize size;

  /// Keeps the label on one line and ellipsizes it. For callers that cap the
  /// button width themselves (the form header); everywhere else the label
  /// wraps and the button grows.
  final bool singleLine;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.appColors;
    final enabled = !busy && onPressed != null;
    final announceBusy = busy && busySemanticsLabel != null;
    final radius = BorderRadius.circular(AppRadius.pill);
    final look = _resolve(theme, colors, enabled);
    final labelColor = look.label;
    final pillHeight = compact ? AppSize.pillCompact : size.height;
    final textStyle = theme.textTheme.labelLarge?.copyWith(
      color: labelColor,
      fontSize: size == AppButtonSize.large && !compact ? 16 : null,
    );
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
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
              decoration: BoxDecoration(
                borderRadius: radius,
                color: look.fill,
                gradient: look.gradient,
                boxShadow: look.shadow,
                border: look.border == null
                    ? null
                    : Border.all(color: look.border!, width: 1.5),
              ),
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
                      horizontal: variant == AppButtonVariant.text
                          ? AppSpacing.sm
                          : compact
                          ? AppSpacing.md
                          : AppSpacing.lg,
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
                              // Reduced motion: a still arc, not a spinner.
                              value: reduceMotion ? 0.75 : null,
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
                            textAlign: TextAlign.center,
                            maxLines: singleLine ? 1 : null,
                            overflow: singleLine ? TextOverflow.ellipsis : null,
                            style: textStyle,
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

  _ButtonLook _resolve(ThemeData theme, AppColors colors, bool enabled) {
    final disabled = _ButtonLook(
      fill: colors.disabledPillFill,
      label: colors.disabledPillLabel,
    );
    switch (variant) {
      case AppButtonVariant.primary:
        if (!enabled) return disabled;
        return _ButtonLook(
          gradient: colors.primaryFillGradient,
          label: colors.primaryFillLabel,
          shadow: AppShadows.primaryGlow,
        );
      case AppButtonVariant.navy:
        if (!enabled) return disabled;
        return _ButtonLook(
          fill: colors.strongPillFill,
          label: colors.strongPillLabel,
        );
      case AppButtonVariant.outline:
        return _ButtonLook(
          label: enabled
              ? theme.colorScheme.onSurface
              : colors.disabledPillLabel,
          border: enabled ? colors.uiBorder : colors.hairline,
        );
      case AppButtonVariant.text:
        return _ButtonLook(
          label: enabled ? colors.accentText : colors.disabledPillLabel,
        );
      case AppButtonVariant.danger:
        if (!enabled) return disabled;
        return _ButtonLook(fill: colors.dangerFill, label: colors.onDangerFill);
      case AppButtonVariant.white:
        if (!enabled) return disabled;
        return const _ButtonLook(
          fill: AppPalette.white,
          label: AppPalette.navy,
          shadow: AppShadows.card,
        );
    }
  }
}

class _ButtonLook {
  const _ButtonLook({
    required this.label,
    this.fill,
    this.gradient,
    this.border,
    this.shadow,
  });

  final Color label;
  final Color? fill;
  final Gradient? gradient;
  final Color? border;
  final List<BoxShadow>? shadow;
}
