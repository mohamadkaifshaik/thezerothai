import 'dart:ui' show SemanticsRole;

import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import '../../../../shared/widgets/primitives/app_card.dart';
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

/// One community in a list: the default tile, a bold name, a muted
/// "N members", a role badge for the owner and moderators, and an optional
/// [trailing] control (the Join pill of the directory). A custom row (no
/// `ListTile`); the whole text area is the tap target (>= 48dp) and speaks
/// name, members and role as one label. The audience picker reuses it
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
    this.trailingBelow = false,
    this.card = false,
  });

  final pb.Community community;
  final VoidCallback? onTap;
  final Widget? trailing;

  /// The Communities page's look (dz.css `.card.row`, R10): the row on a
  /// raised card with a 52 dp tile, the description (when there is one)
  /// under the name, then "N members". Off: the plain row (band B's pane,
  /// the composer's audience picker).
  final bool card;

  /// The tile of a [card] row (the design's 52 dp mark).
  static const double cardTileSize = 52;

  /// Puts [trailing] under the name, aligned with it, instead of after the
  /// row: for a narrow column (band B's context pane, 320 dp), where the Join
  /// pill would leave the name no room. Off: today's row.
  final bool trailingBelow;

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
    final description = card ? community.description.trim() : '';
    final spoken = [
      community.name,
      if (description.isNotEmpty) description,
      members,
      ?badge,
    ].join(', ');
    final trailing = this.trailing;
    if (card) return _card(context, spoken, description, members, badge);
    if (trailingBelow && trailing != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CommunityRow(
            community: community,
            onTap: onTap,
            role: role,
            selected: selected,
          ),
          Padding(
            // Under the name: the row's padding, the tile and its gap.
            padding: const EdgeInsetsDirectional.only(
              start: AppSpacing.md + AppSpacing.xxl + AppSpacing.smd,
              end: AppSpacing.md,
              bottom: AppSpacing.smd,
            ),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: trailing,
            ),
          ),
        ],
      );
    }
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

  /// Above this text scale a [card] row puts its [trailing] pill under the
  /// name: at 2.0 a "Joined" pill alone is about 200 dp wide, which would
  /// leave a 320 dp phone's name no room (as band B's pane does, T8a).
  static const double cardStackTextScale = 1.3;

  /// The [card] look: the text area is the row's one button (as the plain
  /// row), the [trailing] pill sits beside it on the card (under the name at
  /// large text), never inside it.
  Widget _card(
    BuildContext context,
    String spoken,
    String description,
    String members,
    String? badge,
  ) {
    final theme = Theme.of(context);
    final colors = context.appColors;
    final radius = BorderRadius.circular(AppRadius.card);
    final trailing = this.trailing;
    final stack =
        trailing != null &&
        MediaQuery.textScalerOf(context).scale(1) > cardStackTextScale;
    const inset = AppSpacing.smd + 2;
    final textArea = Semantics(
      button: onTap != null,
      role: role,
      selected: selected,
      inMutuallyExclusiveGroup: selected == null ? null : true,
      label: spoken,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppSpacing.minTapTarget),
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(
              inset,
              inset,
              AppSpacing.smd,
              inset,
            ),
            child: Row(
              children: [
                const AppTileIcon(
                  icon: Icons.groups_outlined,
                  size: cardTileSize,
                ),
                const SizedBox(width: AppSpacing.smd),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        community.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (description.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colors.secondaryOnRaised,
                          ),
                        ),
                      ],
                      const SizedBox(height: 2),
                      Wrap(
                        spacing: AppSpacing.sm,
                        runSpacing: AppSpacing.xs,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            members,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: theme.colorScheme.onSurface,
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
    );
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm - AppSpacing.xs / 2,
      ),
      child: AppCard(
        padding: EdgeInsets.zero,
        child: Material(
          type: MaterialType.transparency,
          child: stack
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    textArea,
                    Padding(
                      // Under the name: the inset, the tile and its gap.
                      padding: const EdgeInsetsDirectional.only(
                        start: inset + cardTileSize + AppSpacing.smd,
                        end: AppSpacing.smd,
                        bottom: AppSpacing.sm,
                      ),
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: trailing,
                      ),
                    ),
                  ],
                )
              : Row(
                  children: [
                    Expanded(child: textArea),
                    if (trailing != null)
                      Padding(
                        padding: const EdgeInsetsDirectional.only(
                          end: AppSpacing.smd,
                        ),
                        child: trailing,
                      ),
                  ],
                ),
        ),
      ),
    );
  }
}
