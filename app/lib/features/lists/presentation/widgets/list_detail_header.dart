import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/lists/v1/lists.pb.dart' as pb;
import '../../../../shared/widgets/app_avatar.dart';
import '../../../../shared/widgets/app_pill_button.dart';
import '../../domain/lists_feature_flag.dart';
import '../bloc/list_detail_state.dart';
import 'list_unavailable_view.dart';

/// The top of `/lists/:id` (W5-12): name (with a lock when private),
/// description, the owner row, "N members" and the Pin / Unpin and Edit
/// buttons. Presentation only; the screen wires the callbacks.
///
/// - Edit is for the [isOwner] only; Pin / Unpin is for everyone who can see
///   the List. At [kMaxPinnedHomeTabs] pinned, Pin is disabled and a hint says
///   why. The buttons wrap, so they fit at 360 dp and text scale 2.0.
/// - Without a header (offline cold start) a plain "List" title shows, with
///   Retry when the one `GetList` fell through.
class ListDetailHeader extends StatelessWidget {
  const ListDetailHeader({
    super.key,
    required this.state,
    required this.isOwner,
    required this.onMembers,
    required this.onOwner,
    required this.onTogglePin,
    required this.onEdit,
    required this.onRetry,
  });

  final ListDetailState state;
  final bool isOwner;
  final VoidCallback onMembers;
  final VoidCallback onOwner;
  final VoidCallback onTogglePin;
  final VoidCallback onEdit;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final header = state.header;
    if (header == null) {
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              child: Text('List', style: theme.textTheme.titleLarge),
            ),
            if (state.headerFailed)
              TextButton(
                onPressed: onRetry,
                child: const Text("Couldn't load List details. Retry"),
              ),
          ],
        ),
      );
    }
    final pinDisabled =
        !state.pinned &&
        (state.pinFull || state.pinWriteUnavailable || state.pinBusy);
    final hint = state.pinned
        ? null
        : state.pinFull
        ? 'You can pin up to $kMaxPinnedHomeTabs timelines to Home. Unpin one '
              'first.'
        : state.pinWriteUnavailable
        ? "Pinning isn't available yet."
        : null;
    final owner = header.owner;
    final ownerName = owner.displayName.isEmpty
        ? '@${owner.handle}'
        : owner.displayName;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(
                child: Semantics(
                  header: true,
                  child: Text(
                    header.name,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
              if (header.isPrivate) ...[
                const SizedBox(width: AppSpacing.xs),
                Semantics(
                  label: 'Private List',
                  child: ExcludeSemantics(
                    child: Icon(Icons.lock_outline, size: 18, color: muted),
                  ),
                ),
              ],
            ],
          ),
          if (header.description.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(header.description, style: theme.textTheme.bodyLarge),
          ],
          const SizedBox(height: AppSpacing.sm),
          if (owner.userId.isNotEmpty)
            Semantics(
              button: true,
              label: 'List by $ownerName, @${owner.handle}',
              excludeSemantics: true,
              onTap: onOwner,
              child: InkWell(
                onTap: onOwner,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: AppSpacing.minTapTarget,
                  ),
                  child: Row(
                    children: [
                      AppAvatar(url: owner.avatarUrl, radius: 12),
                      const SizedBox(width: AppSpacing.sm),
                      Flexible(
                        child: Text(
                          ownerName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      Flexible(
                        child: Text(
                          '@${owner.handle}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: muted,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              onPressed: onMembers,
              child: Text(_members(header)),
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (state.pinned)
                OutlinedButton(
                  style: kListOutlinedButtonStyle,
                  onPressed: state.pinBusy ? null : onTogglePin,
                  child: const Text('Unpin from Home'),
                )
              else
                AppPillButton(
                  label: 'Pin to Home',
                  compact: true,
                  onPressed: pinDisabled ? null : onTogglePin,
                ),
              if (isOwner)
                OutlinedButton(
                  style: kListOutlinedButtonStyle,
                  onPressed: onEdit,
                  child: const Text('Edit'),
                ),
            ],
          ),
          if (hint != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.sm),
              child: Text(
                hint,
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ),
        ],
      ),
    );
  }

  static String _members(pb.ListInfo header) =>
      header.memberCount == 1 ? '1 member' : '${header.memberCount} members';
}
