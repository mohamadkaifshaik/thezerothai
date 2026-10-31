import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// The default tile of a List or a Community (W5-11, reused by W5-31): a 48dp
/// rounded square with a muted outline [icon] and a 1dp border. No gradient and
/// no brand tint (ADR-0020). Decorative: it carries no semantics of its own,
/// the row beside it names the thing.
class AppTileIcon extends StatelessWidget {
  const AppTileIcon({
    super.key,
    required this.icon,
    this.size = AppSpacing.xxl,
  });

  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          border: Border.all(color: scheme.outlineVariant),
          borderRadius: BorderRadius.circular(AppSpacing.smd),
        ),
        child: Icon(icon, size: AppIconSize.lg, color: scheme.onSurfaceVariant),
      ),
    );
  }
}
