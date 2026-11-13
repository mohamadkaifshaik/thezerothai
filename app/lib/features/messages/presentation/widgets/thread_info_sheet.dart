import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/common/v1/common.pb.dart' as common;
import '../../../../shared/widgets/primitives/app_avatar.dart';
import '../../../../shared/widgets/primitives/app_menu_item_row.dart';
import '../../../../shared/widgets/primitives/app_side_sheet.dart';

/// The name of the chat info sheet, and the tooltip of the button opening
/// it (the same as the phone and desktop menu's).
const kConversationInfoLabel = 'Conversation info';

/// What the chat info sheet asks the thread to do. The sheet pops it; the
/// thread runs the same flow as its menu (`Block`, `Report`, `Delete`) from
/// its own context once the sheet has closed.
enum ThreadInfoAction { viewProfile, block, report, delete }

/// The chat info side sheet of a conversation (tablet plan sections 4.1
/// "Chat" and 4.2): it replaces the thread's info menu at 600-1199dp on the
/// tablet layout. Phones and desktop keep the menu (ruling R-1).
///
/// - The peer's profile card: avatar, name, handle and View profile (when
///   the peer has a handle).
/// - The menu's actions, with the menu's rules: Block (graph on, a user id,
///   not already blocked), Report (`reports` on; disabled without a report
///   flow or a user id) and Delete conversation.
///
/// Mute (new-features F32), the shared plan (F4) and live location (its own
/// future flag) have no client data yet; their slots collapse with no gap.
class ThreadInfoSheet extends StatelessWidget {
  const ThreadInfoSheet({
    super.key,
    required this.peer,
    required this.canBlock,
    required this.showReport,
    required this.canReport,
  });

  final common.AuthorSnapshot peer;
  final bool canBlock;
  final bool showReport;
  final bool canReport;

  /// Opens the sheet from [context] and resolves to the chosen action, or
  /// null when it was closed.
  static Future<ThreadInfoAction?> show(
    BuildContext context, {
    required common.AuthorSnapshot peer,
    required bool canBlock,
    required bool showReport,
    required bool canReport,
  }) => showAppSideSheet<ThreadInfoAction>(
    context: context,
    semanticLabel: kConversationInfoLabel,
    builder: (_) => ThreadInfoSheet(
      peer: peer,
      canBlock: canBlock,
      showReport: showReport,
      canReport: canReport,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final handle = peer.handle.isEmpty ? '' : ' @${peer.handle}';
    void choose(ThreadInfoAction action) => Navigator.of(context).pop(action);
    return ListView(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      children: [
        const AppSideSheetHeader(title: kConversationInfoLabel),
        _ProfileCard(
          peer: peer,
          onViewProfile: peer.handle.isEmpty
              ? null
              : () => choose(ThreadInfoAction.viewProfile),
        ),
        const Divider(height: 1),
        const SizedBox(height: AppSpacing.xs),
        if (canBlock)
          ThreadInfoActionRow(
            icon: Icons.block,
            label: 'Block$handle',
            onTap: () => choose(ThreadInfoAction.block),
          ),
        if (showReport)
          ThreadInfoActionRow(
            icon: Icons.flag_outlined,
            label: 'Report$handle',
            onTap: canReport ? () => choose(ThreadInfoAction.report) : null,
          ),
        ThreadInfoActionRow(
          icon: Icons.delete_outline,
          label: 'Delete conversation',
          destructive: true,
          onTap: () => choose(ThreadInfoAction.delete),
        ),
      ],
    );
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.peer, required this.onViewProfile});

  final common.AuthorSnapshot peer;
  final VoidCallback? onViewProfile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasName = peer.displayName.isNotEmpty;
    final name = hasName ? peer.displayName : '@${peer.handle}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
        AppSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ExcludeSemantics(
            child: AppAvatar(url: peer.avatarUrl, radius: AppSpacing.xl),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            name,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          if (hasName && peer.handle.isNotEmpty)
            Text(
              '@${peer.handle}',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          if (onViewProfile != null) ...[
            const SizedBox(height: AppSpacing.md),
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, AppSpacing.minTapTarget),
              ),
              onPressed: onViewProfile,
              child: const Text('View profile'),
            ),
          ],
        ],
      ),
    );
  }
}

/// One action of the sheet: the menu's row in a 48dp+ tap target.
class ThreadInfoActionRow extends StatelessWidget {
  const ThreadInfoActionRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      child: AppMenuItemRow(icon: icon, label: label, destructive: destructive),
    );
    return Semantics(
      container: true,
      button: true,
      enabled: onTap != null,
      child: InkWell(
        onTap: onTap,
        child: onTap == null ? Opacity(opacity: 0.38, child: row) : row,
      ),
    );
  }
}
