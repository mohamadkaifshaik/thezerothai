import 'dart:ui' show SemanticsRole;

import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import '../../../../shared/widgets/primitives/app_status_pill.dart';
import '../../../../shared/widgets/primitives/app_tile_icon.dart';
import '../../../lists/presentation/widgets/list_row.dart'
    show listMemberCountLabel;
import '../../domain/community_role.dart';

/// "1 member" / "N members" for a community (`member_count` is an Int64).
String communityMemberCountLabel(pb.Community community) =>
    listMemberCountLabel(community.memberCount.toInt());

/// The role badge text of [role] for the owner and moderators; null for a
/// plain member, a banned viewer or no role (the badge marks authority only).
String? communityRoleBadge(CommunityRole role) => switch (role) {
  CommunityRole.owner => 'Owner',
  CommunityRole.moderator => 'Moderator',
  _ => null,
};

/// One community in a list (W5-31): the default tile, a bold name, a muted
/// "N members", a role badge for the owner and moderators, and an optional
/// [trailing] control (the Join pill of the directory). A custom row (no
/// `ListTile`); the whole text area is the tap target (>= 48dp) and speaks
/// name, members and role as one label. The audience picker (W5-34) reuses it
/// without [trailing], with [role] `menuItem` and [selected] for the chosen
/// one.
class CommunityRow extends StatelessWidget {
  const CommunityRow({
    super.key,
    required this.community,
    this.onTap,
    this.trailing,
    this.role,
    this.selected,
  });

  final pb.Community community;
  final VoidCallback? onTap;
  final Widget? trailing;

  /// An ARIA role for the row on the web (null: a plain button).
  final SemanticsRole? role;

  /// Non-null makes the row one choice of a mutually exclusive group (spoken
  /// as selected or not).
  final bool? selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final members = communityMemberCountLabel(community);
    final badge = communityRoleBadge(community.role);
    final spoken = [community.name, members, ?badge].join(', ');
    return Row(
      children: [
        Expanded(
          child: Semantics(
            button: onTap != null,
            role: role,
            selected: selected,
            inMutuallyExclusiveGroup: selected == null ? null : true,
            label: spoken,
            excludeSemantics: true,
            onTap: onTap,
            child: InkWell(
              onTap: onTap,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: AppSpacing.minTapTarget,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.smd,
                  ),
                  child: Row(
                    children: [
                      const AppTileIcon(icon: Icons.groups_outlined),
                      const SizedBox(width: AppSpacing.smd),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              community.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleMedium,
                            ),
                            const SizedBox(height: AppSpacing.xs),
                            Wrap(
                              spacing: AppSpacing.sm,
                              runSpacing: AppSpacing.xs,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Text(
                                  members,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: muted,
                                  ),
                                ),
                                if (badge != null) AppStatusPill(label: badge),
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
          ),
        ),
        if (trailing != null)
          Padding(
            padding: const EdgeInsetsDirectional.only(end: AppSpacing.md),
            child: trailing,
          ),
      ],
    );
  }
}
