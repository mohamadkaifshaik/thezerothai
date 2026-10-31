import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../shared/format/relative_time.dart';
import '../../domain/composer_draft.dart';

/// One unsent post in the Drafts list (W6-15): the text (up to 3 lines), then
/// a muted line with a Poll badge when it has one and how long ago it was last
/// edited. No avatar. In Edit mode ([editing]) a checkbox sits at the start and
/// a tap selects instead of opening.
///
/// The row is ONE node for a screen reader ("`<text>`. Poll. Edited 5 minutes
/// ago"), a button that opens the draft, or a checkbox in Edit mode. [now] is
/// injected so the relative time is deterministic in tests.
class DraftRow extends StatelessWidget {
  const DraftRow({
    super.key,
    required this.draft,
    required this.now,
    required this.onTap,
    this.editing = false,
    this.selected = false,
  });

  final ComposerDraft draft;
  final DateTime now;
  final VoidCallback onTap;
  final bool editing;
  final bool selected;

  bool get _hasPoll => draft.poll != null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final text = draft.text.trim();
    final shown = text.isEmpty ? 'No text' : text;
    final time = formatRelativeTime(draft.updatedAt, now);
    final spoken = [
      shown,
      if (_hasPoll) 'Poll',
      'Edited ${formatRelativeTimeSpoken(draft.updatedAt, now)}',
    ].join('. ');
    return Semantics(
      container: true,
      button: !editing,
      checked: editing ? selected : null,
      label: spoken,
      excludeSemantics: true,
      onTap: onTap,
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
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (editing) ...[
                  // The row is the control; the box only pictures it, so it
                  // is not a second tab stop.
                  ExcludeFocus(
                    child: IgnorePointer(
                      child: Checkbox(
                        value: selected,
                        onChanged: (_) {},
                        materialTapTargetSize: MaterialTapTargetSize.padded,
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.xs),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        shown,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: text.isEmpty
                              ? colors.onSurfaceVariant
                              : colors.onSurface,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Row(
                        children: [
                          if (_hasPoll) ...[
                            Icon(
                              Icons.poll_outlined,
                              size: AppIconSize.sm,
                              color: colors.onSurfaceVariant,
                            ),
                            const SizedBox(width: AppSpacing.xs),
                            Text(
                              'Poll',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.xs,
                              ),
                              child: Text(
                                '·',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                          Flexible(
                            child: Text(
                              time,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
