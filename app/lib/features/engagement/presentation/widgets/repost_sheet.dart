import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/sheet_option_row.dart';

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
          SheetOptionRow(
            icon: Icons.repeat,
            label: reposted ? 'Undo repost' : 'Repost',
            onTap: () => Navigator.of(context)
                .pop(reposted ? RepostChoice.undoRepost : RepostChoice.repost),
          ),
          if (canQuote)
            SheetOptionRow(
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
