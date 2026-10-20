import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// A calm, bordered panel: [child] on a theme surface with the standard
/// radius and a low-contrast border. Purely presentational (no data, no
/// state); [elevated] lifts it one surface level for a panel that sits on
/// another panel.
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
    final colors = Theme.of(context).colorScheme;
    return Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: elevated
            ? colors.surfaceContainerHigh
            : colors.surfaceContainerLow,
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: child,
    );
  }
}
