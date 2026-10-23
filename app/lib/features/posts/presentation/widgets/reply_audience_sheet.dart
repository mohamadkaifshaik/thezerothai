import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/sheet_option_row.dart';
import '../../domain/reply_audience.dart';

/// The leading icon of an audience: globe, person with a check, "@".
IconData replyAudienceIcon(ReplyAudience audience) => switch (audience) {
  ReplyAudience.everyone => Icons.public,
  ReplyAudience.following => Icons.how_to_reg_outlined,
  ReplyAudience.mentionedOnly => Icons.alternate_email,
};

/// The "Who can reply?" sheet of the composer (ADR-0021 D2): the three launch
/// options, each with a leading icon and a radio on the right, [selected]
/// checked. Picking one closes the sheet and returns it; dismissing returns
/// null. A bottom sheet at every width, like the app's other pickers
/// (Material caps its width on wide screens).
Future<ReplyAudience?> showReplyAudienceSheet(
  BuildContext context, {
  required ReplyAudience selected,
}) {
  return showModalBottomSheet<ReplyAudience>(
    context: context,
    showDragHandle: true,
    builder: (_) => ReplyAudienceSheet(selected: selected),
  );
}

class ReplyAudienceSheet extends StatelessWidget {
  const ReplyAudienceSheet({super.key, required this.selected});

  final ReplyAudience selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                0,
                AppSpacing.md,
                AppSpacing.sm,
              ),
              child: Semantics(
                header: true,
                child: Text(
                  'Who can reply?',
                  style: theme.textTheme.titleLarge,
                ),
              ),
            ),
            for (final audience in ReplyAudience.values)
              SheetOptionRow(
                icon: replyAudienceIcon(audience),
                label: audience.optionLabel,
                selected: audience == selected,
                onTap: () => Navigator.of(context).pop(audience),
                trailing: Icon(
                  audience == selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: AppIconSize.lg,
                  color: audience == selected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ),
      ),
    );
  }
}
