import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/context_pane.dart';

/// The title of [ModerationLogAbout].
const kModerationLogAboutTitle = 'About this log';

/// The sentences of [ModerationLogAbout], from what the log already says
/// (its empty state, its access rule and its Restore action).
const kModerationLogAboutText =
    'Removed posts, bans and role changes in this Community, newest first. '
    'Only the owner and moderators can see this log. A removed post can be '
    'restored from its entry.';

/// "About this log" (tablet plan section 4.1, ModLog): a card in band B's
/// context pane, and the same card as an inline banner above the log in
/// band A (the screen passes its own [margin]). Static: it reads no data.
/// Phones and desktop do not show it (ruling R-1).
class ModerationLogAbout extends StatelessWidget {
  const ModerationLogAbout({
    super.key,
    this.margin = const EdgeInsets.only(bottom: AppSpacing.md),
  });

  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ContextPaneCard(
      title: kModerationLogAboutTitle,
      margin: margin,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.xs,
          AppSpacing.md,
          AppSpacing.md,
        ),
        child: Text(
          kModerationLogAboutText,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
