import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import '../../../../gen/dzeroth/communities/v1/communities.pbenum.dart'
    show ModerationLogAction;
import '../../../../shared/format/relative_time.dart';
import '../../../lists/presentation/widgets/list_unavailable_view.dart'
    show kListOutlinedButtonStyle;

/// "@mod removed a post" for one log entry. A deleted actor or target
/// reads "Deleted account"; an action this build does not know reads
/// "Moderation action". The log never names a post's author.
String moderationLogSentence(pb.ModerationLogEntry e) {
  // No actor and not deleted: the platform acted (ADR-0031 D14a, the
  // `_platform` marker). It reads as the platform, never as a person.
  final actor = e.actorDeleted
      ? 'Deleted account'
      : (e.hasActor()
            ? (e.actor.handle.isNotEmpty ? '@${e.actor.handle}' : 'A moderator')
            : 'The platform');
  final target = e.targetDeleted
      ? 'Deleted account'
      : (e.hasTarget() && e.target.handle.isNotEmpty
            ? '@${e.target.handle}'
            : 'a member');
  return switch (e.action) {
    ModerationLogAction.MODERATION_LOG_ACTION_HIDE => '$actor removed a post',
    ModerationLogAction.MODERATION_LOG_ACTION_RESTORE =>
      '$actor restored a post',
    ModerationLogAction.MODERATION_LOG_ACTION_BAN => '$actor banned $target',
    ModerationLogAction.MODERATION_LOG_ACTION_UNBAN =>
      '$actor unbanned $target',
    ModerationLogAction.MODERATION_LOG_ACTION_MAKE_MODERATOR =>
      '$actor made $target a moderator',
    ModerationLogAction.MODERATION_LOG_ACTION_REMOVE_MODERATOR =>
      '$actor removed $target as moderator',
    ModerationLogAction.MODERATION_LOG_ACTION_EDIT =>
      '$actor edited the Community',
    ModerationLogAction.MODERATION_LOG_ACTION_MODERATOR_LEFT =>
      '$actor left as moderator',
    ModerationLogAction.MODERATION_LOG_ACTION_OWNER_HANDOVER =>
      e.hasTarget() || e.targetDeleted
          ? 'Ownership moved to $target'
          : 'The Community was archived',
    _ => 'Moderation action',
  };
}

/// One moderation-log entry: the sentence, a muted time, and for a
/// HIDE entry a Restore button (or "Restored"). A custom row (no `ListTile`).
/// [now] is injected so the time is deterministic.
class ModerationLogRow extends StatelessWidget {
  const ModerationLogRow({
    super.key,
    required this.entry,
    required this.now,
    this.onRestore,
    this.restored = false,
    this.busy = false,
  });

  final pb.ModerationLogEntry entry;
  final DateTime now;

  /// Null hides the Restore button.
  final VoidCallback? onRestore;

  /// The post was restored from this screen: shows "Restored" instead.
  final bool restored;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final sentence = moderationLogSentence(entry);
    final at = entry.hasAt() ? entry.at.toDateTime() : null;
    final time = at == null ? '' : formatRelativeTime(at, now);
    final spoken = at == null ? '' : formatRelativeTimeSpoken(at, now);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              label: spoken.isEmpty ? sentence : '$sentence, $spoken',
              excludeSemantics: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(sentence, style: theme.textTheme.bodyMedium),
                  if (time.isNotEmpty)
                    Text(
                      time,
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                ],
              ),
            ),
          ),
          if (restored)
            Text(
              'Restored',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            )
          else if (onRestore != null) ...[
            const SizedBox(width: AppSpacing.sm),
            Semantics(
              button: true,
              label: 'Restore post',
              excludeSemantics: true,
              onTap: busy ? null : onRestore,
              child: OutlinedButton(
                style: kListOutlinedButtonStyle,
                onPressed: busy ? null : onRestore,
                child: const Text('Restore'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
