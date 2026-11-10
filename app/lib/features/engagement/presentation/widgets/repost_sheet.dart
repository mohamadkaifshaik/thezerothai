import 'package:flutter/material.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/primitives/app_sheet.dart';
import '../../../../shared/widgets/primitives/sheet_option_row.dart';

/// What the user picked in the repost sheet.
enum RepostChoice { repost, undoRepost, quote }

/// The sheet behind a post's repost button (X-style): Repost / Undo repost,
/// and Quote when [canQuote]. Returns null when dismissed. Rows are 48dp
/// targets with an icon and a label; no default list tiles.
///
/// With [restricted] (another user's followers-only post) Repost and
/// Quote are shown disabled under a line saying why; Undo repost stays.
///
/// On the tablet layout (600-1199 dp) it is a menu hung from [anchor] (the
/// Repost button), never a bottom sheet.
Future<RepostChoice?> showRepostSheet(
  BuildContext context, {
  required bool reposted,
  required bool canQuote,
  bool restricted = false,
  BuildContext? anchor,
}) {
  return showAppSheet<RepostChoice>(
    context: context,
    material: const MaterialSheetOptions(showDragHandle: true),
    onTablet: AppSheetOnTablet.menu,
    anchor: anchor,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SheetOptionRow(
            icon: Icons.repeat,
            label: reposted ? 'Undo repost' : 'Repost',
            onTap: restricted && !reposted
                ? null
                : () => Navigator.of(context).pop(
                    reposted ? RepostChoice.undoRepost : RepostChoice.repost,
                  ),
          ),
          if (canQuote)
            SheetOptionRow(
              icon: Icons.edit_outlined,
              label: 'Quote',
              onTap: restricted
                  ? null
                  : () => Navigator.of(context).pop(RepostChoice.quote),
            ),
          if (restricted)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm,
              ),
              child: Text(
                ProtectedAccountException.userMessage,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          const SizedBox(height: AppSpacing.sm),
        ],
      ),
    ),
  );
}
