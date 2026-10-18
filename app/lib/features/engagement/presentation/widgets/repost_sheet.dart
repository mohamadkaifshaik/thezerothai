import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';

/// What the user picked in the repost sheet.
enum RepostChoice { repost, undoRepost, quote }

/// The sheet behind a post's repost button (X-style): Repost / Undo repost,
/// and Quote when [canQuote]. Returns null when dismissed. Rows are 48dp
/// targets with an icon and a label; no default list tiles.
Future<RepostChoice?> showRepostSheet(
  BuildContext context, {
  required bool reposted,
  required bool canQuote,
}) {
  return showModalBottomSheet<RepostChoice>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _SheetRow(
            icon: Icons.repeat,
            label: reposted ? 'Undo repost' : 'Repost',
            onTap: () => Navigator.of(context)
                .pop(reposted ? RepostChoice.undoRepost : RepostChoice.repost),
          ),
          if (canQuote)
            _SheetRow(
              icon: Icons.edit_outlined,
              label: 'Quote',
              onTap: () => Navigator.of(context).pop(RepostChoice.quote),
            ),
          const SizedBox(height: AppSpacing.sm),
        ],
      ),
    ),
  );
}

class _SheetRow extends StatelessWidget {
  const _SheetRow({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppSpacing.xxl),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            child: Row(
              children: [
                Icon(icon, size: AppIconSize.lg),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(label, style: theme.textTheme.titleMedium),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
