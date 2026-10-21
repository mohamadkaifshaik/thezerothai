import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/app_section_header.dart';
import '../../../../shared/widgets/app_surface.dart';

/// One Settings section: a [title] header above a card whose [rows] are
/// separated by hairlines. Feature-local: the Settings screen is the only
/// place that groups rows this way.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, required this.title, required this.rows})
    : assert(rows.length > 0, 'an empty group must not be built');

  final String title;
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppSectionHeader(title: title),
          AppSurface(
            padding: EdgeInsets.zero,
            margin: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            // Clips the row ripples to the card's rounded corners.
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.lg),
              child: Column(
                children: [
                  for (var i = 0; i < rows.length; i++) ...[
                    if (i > 0) const Divider(height: 1),
                    rows[i],
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One row of a [SettingsGroup]: a leading icon in a small rounded tile, a
/// [title] (and optional [subtitle]) and a [trailing] widget (a chevron by
/// default). With no [onTap] the row is static text (the Email row), not a
/// button. A [destructive] row uses the error color.
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    this.trailing,
    this.showChevron = true,
    this.destructive = false,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;

  /// Replaces the default chevron (shown only when [onTap] is set).
  final Widget? trailing;

  /// Whether the default chevron is shown when there is no [trailing]; false
  /// for an action that does not open another page (Sign out).
  final bool showChevron;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final tint = destructive ? colors.error : colors.onSurface;
    final content = ConstrainedBox(
      constraints: const BoxConstraints(
        minHeight: AppSpacing.xxl + AppSpacing.sm,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        child: Row(
          children: [
            Container(
              width: AppSpacing.xl + AppSpacing.sm,
              height: AppSpacing.xl + AppSpacing.sm,
              decoration: BoxDecoration(
                color: colors.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: Icon(icon, size: AppIconSize.md, color: tint),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.bodyLarge?.copyWith(color: tint),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            if (onTap != null && (trailing != null || showChevron)) ...[
              const SizedBox(width: AppSpacing.sm),
              trailing ??
                  Icon(
                    Icons.chevron_right,
                    size: AppIconSize.lg,
                    color: colors.onSurfaceVariant,
                  ),
            ],
          ],
        ),
      ),
    );

    final label = subtitle == null ? title : '$title\n$subtitle';
    // `container` keeps each row its own node: without it a static row would
    // merge into the group header's node above it.
    if (onTap == null) {
      return Semantics(
        container: true,
        label: label,
        excludeSemantics: true,
        child: content,
      );
    }
    // One node per row: the label once, as a button.
    return Semantics(
      container: true,
      button: true,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(onTap: onTap, child: content),
    );
  }
}
