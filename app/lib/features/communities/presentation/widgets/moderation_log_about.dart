import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/context_pane.dart';
import '../bloc/community_moderation_log_cubit.dart';

/// The title of [ModerationLogAbout].
const kModerationLogAboutTitle = 'About this log';

/// The sentences of [ModerationLogAbout], from what the log already says
/// (its actions, edits included, its access rule and its Restore action).
const kModerationLogAboutText =
    'Removed posts, bans, role changes and edits in this Community, newest '
    'first. Only the owner and moderators can see this log. You can restore '
    'a removed post from its entry.';

/// Whether the log page lists entries: loaded (or loading more), not failed,
/// and not empty. Only the owner and moderators get entries (anyone else is
/// refused), so "About this log" shows on this rule only.
bool moderationLogListed(ModerationLogState state) =>
    state.status != ModerationLogStatus.loading &&
    !(state.status == ModerationLogStatus.error && state.error != null) &&
    state.entries.isNotEmpty;

/// "About this log" (the desktop ModLog mock's side box): the first item of
/// the log on desktop (the screen passes its own [margin]), only while
/// [moderationLogListed]. Static content: it reads no data. Phones and
/// tablets do not show it (their mocks have none).
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
