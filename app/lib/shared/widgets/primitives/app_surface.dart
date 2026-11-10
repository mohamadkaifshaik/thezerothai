import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// A calm, bordered panel (dz.css `.box`): [child] on white (light) or navy2
/// (dark) with a hairline border and the `cardSmall` radius. Purely
/// presentational (no data, no state); [elevated] lifts it one surface level
/// for a panel that sits on another panel. For the shadowed gradient card use
/// `AppCard`.
class AppSurface extends StatelessWidget {
  const AppSurface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.md),
    this.margin = EdgeInsets.zero,
    this.elevated = false,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final bool elevated;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final base = dark
        ? colors.surfaceContainerHigh
        : colors.surfaceContainerLowest;
    return Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: elevated ? colors.surfaceContainerHighest : base,
        border: Border.all(color: context.appColors.hairline),
        borderRadius: BorderRadius.circular(AppRadius.cardSmall),
      ),
      child: child,
    );
  }
}
