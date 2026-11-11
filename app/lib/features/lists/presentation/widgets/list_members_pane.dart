import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/context_pane.dart';
import '../../../../shared/widgets/user/user_list_skeleton.dart';
import '../../../graph/presentation/widgets/user_list_row.dart';
import '../bloc/list_detail_state.dart';
import '../bloc/list_members_preview_cubit.dart';

/// The title of the members card in band B's context pane on `/lists/:id`.
const kListMembersPaneTitle = 'Members';

/// The card's link to the members page: the owner manages it (Remove), the
/// others read it.
const kManageMembersLabel = 'Manage members';
const kSeeAllMembersLabel = 'See all members';

/// [ListMembersPane] while the List or its members load, and the pane's
/// members section until the page has lent it: the Members card over a
/// skeleton of the same rows, so the pane never opens on the footer alone.
class ListMembersPanePlaceholder extends StatelessWidget {
  const ListMembersPanePlaceholder({super.key});

  @override
  Widget build(BuildContext context) => const ContextPaneCard(
    title: kListMembersPaneTitle,
    child: Padding(
      padding: EdgeInsets.only(bottom: AppSpacing.sm),
      child: UserListSkeleton(rows: 3, semanticsLabel: 'Loading members'),
    ),
  );
}

/// Band B's context pane on a List (tablet plan section 4.1, ListDetail:
/// "timeline | Members preview + Manage"; T8b): the first
/// [kListMembersPreviewLimit] members as the members page draws them, then
/// one 48 dp link to that page ([kManageMembersLabel] for the owner,
/// [kSeeAllMembersLabel] for everyone else).
///
/// The page lends it over its own state (`ContextPaneSlots`). The header's
/// "N members" stays at every width (R-inline); this card only adds a
/// second place. Nothing when the List is unavailable or its header failed
/// to load (the page says so), nor when the members can't be shown at all.
class ListMembersPane extends StatelessWidget {
  const ListMembersPane({
    super.key,
    required this.detail,
    required this.preview,
    required this.isOwner,
    required this.onSeeAll,
    required this.onRetry,
  });

  final ListDetailState detail;
  final ListMembersPreviewState preview;
  final bool isOwner;
  final VoidCallback onSeeAll;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (detail.status == ListDetailStatus.unavailable ||
        preview.status == ListMembersPreviewStatus.unavailable) {
      return const SizedBox.shrink();
    }
    final header = detail.header;
    if (header == null) {
      return detail.headerFailed
          ? const SizedBox.shrink()
          : const ListMembersPanePlaceholder();
    }
    final users = preview.users;
    final waiting =
        preview.status == ListMembersPreviewStatus.idle ||
        preview.status == ListMembersPreviewStatus.loading;
    if (waiting && users.isEmpty) return const ListMembersPanePlaceholder();
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final failed = preview.status == ListMembersPreviewStatus.failed;
    final empty = header.memberCount == 0 && users.isEmpty;
    return ContextPaneCard(
      title: kListMembersPaneTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (empty && !failed)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.xs,
                AppSpacing.md,
                AppSpacing.md,
              ),
              // The members page's own empty line.
              child: Text('No one is on this List yet', style: muted),
            ),
          for (var i = 0; i < users.length; i++)
            UserListRow(
              key: ValueKey('pane-member-${users[i].user.userId}'),
              item: users[i],
            ),
          if (failed)
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(
                AppSpacing.md,
                AppSpacing.sm,
                AppSpacing.sm,
                0,
              ),
              child: Row(
                children: [
                  Expanded(child: Text("Couldn't load members.", style: muted)),
                  TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(
                        AppSpacing.minTapTarget,
                        AppSpacing.minTapTarget,
                      ),
                    ),
                    onPressed: onRetry,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          if (!empty)
            Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(AppSpacing.minTapTarget),
                ),
                onPressed: onSeeAll,
                child: Text(
                  isOwner ? kManageMembersLabel : kSeeAllMembersLabel,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
