import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/primitives/app_menu_item_row.dart';
import '../../domain/community_role.dart';

/// One moderator action on a member row.
enum CommunityMemberAction { ban, unban, makeModerator, removeModerator }

/// Which actions the viewer may start on a row, from roles the server sent
/// (`Community.viewer_role`, `CommunityMember.role`); the client derives
/// nothing else, and the server still checks every call (FORBIDDEN
/// `not_moderator` / `not_owner`).
///
/// - Owner and moderators: Ban a plain member; Unban on the banned page.
/// - Owner only: Make a member a moderator; Remove a moderator.
/// - Nobody acts on the owner, on a moderator (ban) or on themselves.
List<CommunityMemberAction> communityMemberActions({
  required CommunityRole viewer,
  required CommunityRole target,
  required bool isSelf,
}) {
  if (isSelf || !viewer.canModerate) return const [];
  return switch (target) {
    CommunityRole.banned => const [CommunityMemberAction.unban],
    CommunityRole.member => [
      CommunityMemberAction.ban,
      if (viewer.isOwner) CommunityMemberAction.makeModerator,
    ],
    CommunityRole.moderator => [
      if (viewer.isOwner) CommunityMemberAction.removeModerator,
    ],
    _ => const [],
  };
}

/// The "more" menu of a member row: the [actions] the viewer may start. Draws
/// nothing for an empty list. 48dp target, labelled with the member's handle.
class CommunityMemberActionsMenu extends StatelessWidget {
  const CommunityMemberActionsMenu({
    super.key,
    required this.handle,
    required this.actions,
    required this.onSelected,
    this.busy = false,
  });

  final String handle;
  final List<CommunityMemberAction> actions;
  final ValueChanged<CommunityMemberAction> onSelected;

  /// A call for this member is in flight: the menu is disabled.
  final bool busy;

  static String label(CommunityMemberAction a) => switch (a) {
    CommunityMemberAction.ban => 'Ban from Community',
    CommunityMemberAction.unban => 'Unban',
    CommunityMemberAction.makeModerator => 'Make moderator',
    CommunityMemberAction.removeModerator => 'Remove as moderator',
  };

  static IconData _icon(CommunityMemberAction a) => switch (a) {
    CommunityMemberAction.ban => Icons.block,
    CommunityMemberAction.unban => Icons.lock_open_outlined,
    CommunityMemberAction.makeModerator => Icons.shield_outlined,
    CommunityMemberAction.removeModerator => Icons.remove_moderator_outlined,
  };

  @override
  Widget build(BuildContext context) {
    if (actions.isEmpty) return const SizedBox.shrink();
    return PopupMenuButton<CommunityMemberAction>(
      tooltip: 'Moderate @$handle',
      enabled: !busy,
      icon: Icon(
        Icons.more_horiz,
        size: AppIconSize.lg,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final a in actions)
          PopupMenuItem(
            value: a,
            child: AppMenuItemRow(
              icon: _icon(a),
              label: label(a),
              destructive: a == CommunityMemberAction.ban,
            ),
          ),
      ],
    );
  }
}
