import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/context_pane.dart';
import '../../../../shared/widgets/primitives/app_skeleton.dart';
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
/// refused), so "About this log" shows on this rule only, in band A's list
/// and in band B's pane alike.
bool moderationLogListed(ModerationLogState state) =>
    state.status != ModerationLogStatus.loading &&
    !(state.status == ModerationLogStatus.error && state.error != null) &&
    state.entries.isNotEmpty;

/// Band B's "About this log" card while the log loads, and until the log
/// page has lent the card (the slot's placeholder): the title over a
/// skeleton, so the pane neither opens on the footer alone nor promises a
/// Restore before the log says the caller moderates.
class ModerationLogAboutPlaceholder extends StatelessWidget {
  const ModerationLogAboutPlaceholder({super.key});

  @override
  Widget build(BuildContext context) => ContextPaneCard(
    title: kModerationLogAboutTitle,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.xs,
        AppSpacing.md,
        AppSpacing.md,
      ),
      child: AppSkeletonScope(
        semanticsLabel: 'Loading the moderation log',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final factor in const [1.0, 1.0, 0.6]) ...[
              FractionallySizedBox(
                widthFactor: factor,
                child: const AppSkeletonBlock(height: AppSpacing.md),
              ),
              const SizedBox(height: AppSpacing.xs),
            ],
          ],
        ),
      ),
    ),
  );
}

/// "About this log" (tablet plan section 4.1, ModLog): a card in band B's
/// context pane (lent by the log page) and the same card as the first item
/// of the log in band A (the screen passes its own [margin]), both only
/// while [moderationLogListed]. Static content: it reads no data.
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
