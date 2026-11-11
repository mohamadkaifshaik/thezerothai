import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// A small outlined chip (dz.css `.chip`): 1.5 dp `selectedIndicator` outline,
/// 12 sp w700 label, an optional 6 dp dot. The visual is at least 26 dp tall
/// and grows with the text scale, never a fixed box.
///
/// A chip that only labels (a post meta tag) has no hit area; give it
/// [onPressed] and it becomes a button with a 48 dp target around the visual.
/// Set [onDark] on a navy or photo surface (teal electric in both themes).
class AppChip extends StatelessWidget {
  const AppChip({
    super.key,
    required this.label,
    this.showDot = false,
    this.onDark = false,
    this.onPressed,
    this.semanticsLabel,
  });

  final String label;

  /// A leading 6 dp status dot.
  final bool showDot;

  /// Use the teal-electric colours (a navy surface in a light theme).
  final bool onDark;
  final VoidCallback? onPressed;

  /// Spoken label when it differs from [label].
  final String? semanticsLabel;

  /// Minimum visual height (dp).
  static const double minHeight = 26;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = onDark
        ? AppPalette.tealElectric
        : context.appColors.selectedIndicator;
    final visual = Container(
      constraints: const BoxConstraints(minHeight: minHeight),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: color, width: AppSize.componentBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showDot) ...[
            DecoratedBox(
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              child: const SizedBox.square(dimension: 6),
            ),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: color,
                fontWeight: AppTypeTokens.weightUi,
              ),
            ),
          ),
        ],
      ),
    );
    final pressed = onPressed;
    if (pressed == null) {
      return Semantics(
        container: true,
        label: semanticsLabel ?? label,
        child: ExcludeSemantics(child: visual),
      );
    }
    return Semantics(
      container: true,
      button: true,
      onTap: pressed,
      label: semanticsLabel ?? label,
      child: ExcludeSemantics(
        child: InkWell(
          onTap: pressed,
          customBorder: const StadiumBorder(),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: AppSpacing.minTapTarget,
              minWidth: AppSpacing.minTapTarget,
            ),
            child: Center(widthFactor: 1, child: visual),
          ),
        ),
      ),
    );
  }
}

/// A filter pill (dz.css `.pill`): white (light) or raised (dark) with a
/// 3:1 outline; the selected pill is navy (pearl on dark) **and** shows a
/// check glyph and a w700 label, so selection is never colour alone. Announced
/// as a selected button. The visual is at least 36 dp inside a 48 dp hit area.
class AppFilterPill extends StatelessWidget {
  const AppFilterPill({
    super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
    this.maxLines = 1,
  });

  final String label;
  final bool selected;

  /// Lines of the label before it ellipsizes; null wraps it whole (a
  /// Settings choice at large text, R4). One by default (the filter rows).
  final int? maxLines;

  /// Null disables the pill.
  final VoidCallback? onPressed;

  /// Minimum visual height (dp); it grows with the text scale.
  static const double minHeight = 36;

  /// The unselected fill for [theme].
  static Color unselectedFill(ThemeData theme) =>
      theme.brightness == Brightness.dark
      ? theme.colorScheme.surfaceContainer
      : AppPalette.white;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.appColors;
    final enabled = onPressed != null;
    final fill = selected ? colors.strongPillFill : unselectedFill(theme);
    final labelColor = selected
        ? colors.strongPillLabel
        : theme.colorScheme.onSurface;
    final border = selected ? colors.strongPillFill : colors.uiBorder;
    final visual = Container(
      constraints: const BoxConstraints(minHeight: minHeight),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (selected) ...[
            Icon(Icons.check, size: AppIconSize.sm, color: labelColor),
            const SizedBox(width: AppSpacing.xs),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: maxLines,
              overflow: maxLines == null ? null : TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                color: labelColor,
                fontWeight: selected
                    ? AppTypeTokens.weightUi
                    : AppTypeTokens.weightLabel,
              ),
            ),
          ),
        ],
      ),
    );
    return Semantics(
      container: true,
      button: true,
      selected: selected,
      enabled: enabled,
      onTap: onPressed,
      label: label,
      child: ExcludeSemantics(
        child: Opacity(
          opacity: enabled ? 1 : 0.5,
          child: InkWell(
            onTap: onPressed,
            customBorder: const StadiumBorder(),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: AppSpacing.minTapTarget,
                minWidth: AppSpacing.minTapTarget,
              ),
              child: Center(widthFactor: 1, child: visual),
            ),
          ),
        ),
      ),
    );
  }
}
