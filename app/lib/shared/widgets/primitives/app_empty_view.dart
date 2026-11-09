import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// An empty list state: an optional [icon], a short [title] and an optional
/// one-line [subtitle]. Centred on phones (window narrower than
/// [AppBreakpoints.mobile], matching the mobile designs) and start-aligned on
/// tablet and desktop (dz.css `.empty`); [centered] forces either. Sized for a sliver/box inside a scroll view (Home, profile,
/// thread replies). In a bounded-height box (an `Expanded`, a `Center`) it
/// scrolls when its content is taller than the space left, so a large text
/// scale or a short window never overflows; its default rendering is
/// unchanged.
class AppEmptyView extends StatelessWidget {
  const AppEmptyView({
    super.key,
    this.icon,
    required this.title,
    this.subtitle,
    this.action,
    this.centered,
    this.iconColor,
  });

  final IconData? icon;
  final String title;
  final String? subtitle;

  /// A call to action under the text (e.g. a compact pill button).
  final Widget? action;

  /// Centre the content (true) or start it at the leading edge (false).
  /// Null (the default) decides by window width: centred below
  /// [AppBreakpoints.mobile] (owner decision 2026-11-09), start-aligned above.
  final bool? centered;

  /// Overrides the muted icon colour (an error state uses the error role).
  final Color? iconColor;

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
    final centered =
        this.centered ??
        MediaQuery.sizeOf(context).width < AppBreakpoints.mobile;
    final align = centered ? TextAlign.center : TextAlign.start;
    return SizedBox(
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.xxl,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: centered
              ? CrossAxisAlignment.center
              : CrossAxisAlignment.start,
          children: [
            if (icon != null) ...[
              ExcludeSemantics(
                child: Icon(
                  icon,
                  size: AppSpacing.xxl,
                  color: iconColor ?? theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
            ],
            Text(title, style: theme.textTheme.titleLarge, textAlign: align),
            if (subtitle != null) ...[
              const SizedBox(height: AppSpacing.sm),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Text(
                  subtitle!,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  textAlign: align,
                ),
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: AppSpacing.md),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
