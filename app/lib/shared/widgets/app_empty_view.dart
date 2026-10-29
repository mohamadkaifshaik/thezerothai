import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// An empty list state: [icon], a short [title] and an optional one-line
/// [subtitle]. Sized for a sliver/box inside a scroll view (Home, profile,
/// thread replies). In a bounded-height box (an `Expanded`, a `Center`) it
/// scrolls when its content is taller than the space left, so a large text
/// scale or a short window never overflows; its default rendering is
/// unchanged.
class AppEmptyView extends StatelessWidget {
  const AppEmptyView({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? subtitle;

  /// A call to action under the text (e.g. a compact pill button).
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final content = _content(context);
        // Bounded height (an `Expanded`, a `Center` in one): when the content
        // is taller than the space left it scrolls instead of overflowing.
        // The scroll view shrink-wraps, so when the content fits the layout
        // is exactly the plain content. Unbounded (a sliver box adapter in a
        // scroll view) the content is returned as is.
        if (!constraints.hasBoundedHeight) return content;
        return SingleChildScrollView(primary: false, child: content);
      },
    );
  }

  Widget _content(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.xxl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: AppSpacing.xxl,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            title,
            style: theme.textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
          if (subtitle != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              subtitle!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
          if (action != null) ...[
            const SizedBox(height: AppSpacing.md),
            action!,
          ],
        ],
      ),
    );
  }
}
