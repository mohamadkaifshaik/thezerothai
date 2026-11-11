import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/primitives/pin_to_home.dart';
import '../../../../shared/widgets/primitives/app_status_pill.dart';
import '../../../lists/presentation/widgets/list_unavailable_view.dart'
    show kListOutlinedButtonStyle;
import '../../../../gen/dzeroth/communities/v1/communities.pbenum.dart'
    show CommunityStatus;
import '../../domain/community_role.dart';
import '../bloc/community_detail_state.dart';
import 'community_join_control.dart';
import 'community_row.dart';

/// A community's name as its page header draws it (the design's `h1`: 800,
/// tight; R10), shared by the Create preview so the preview matches the page.
TextStyle? communityNameStyle(ThemeData theme) => theme.textTheme.headlineSmall
    ?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.5, height: 1.1);

/// The top of `/communities/:id`: name, "N members" (opens the members
/// page), the Join / Joined / Banned control and Pin / Unpin from Home.
/// Presentation only: the screen wires the callbacks.
///
/// - The control reads the server's `viewer_role` (through the state); a Join
///   in flight already reads "Joined" and a Leave in flight already reads
///   "Join" (optimistic). The owner cannot leave, so their "Joined" is inert.
/// - A banned viewer sees the muted "You can't join this Community" and no Pin.
/// - At [kMaxPinnedHomeTabs] pinned, Pin is disabled and a hint says why. The
///   buttons wrap, so they fit at 360 dp and text scale 2.0.
/// - "Post" is the compose entry: shown only when the screen passes
///   [onCompose], which it does for a joined, not archived community and a
///   caller who may post (see [communityComposeAllowed]).
class CommunityHeader extends StatelessWidget {
  const CommunityHeader({
    super.key,
    required this.state,
    required this.onMembers,
    required this.onJoin,
    required this.onLeave,
    required this.onTogglePin,
    required this.onRetry,
    this.onCompose,
    this.onModerationLog,
  });

  final CommunityDetailState state;
  final VoidCallback onMembers;
  final VoidCallback onJoin;
  final VoidCallback onLeave;
  final VoidCallback onTogglePin;
  final VoidCallback onRetry;

  /// Opens the composer on this community; null hides the "Post" button.
  final VoidCallback? onCompose;

  /// Opens the moderation log; null hides the entry. The screen passes
  /// it only when the server's `viewer_role` is owner or moderator.
  final VoidCallback? onModerationLog;

  /// Whether the "Post" entry is offered for [state]: the caller is a
  /// member by the server's `viewer_role` (a banned or non-member viewer is
  /// not), the community is not archived (read-only), and no Join / Leave is
  /// in flight. The caller's own flags (`posts`, protected account) are the
  /// screen's to add.
  static bool communityComposeAllowed(CommunityDetailState state) {
    final community = state.community;
    if (community == null) return false;
    if (community.status == CommunityStatus.COMMUNITY_STATUS_ARCHIVED) {
      return false;
    }
    return joinStateOf(state) == CommunityJoinState.joined && !state.joinBusy;
  }

  /// What the control shows for [state].
  static CommunityJoinState joinStateOf(CommunityDetailState state) {
    final role = state.community?.role ?? CommunityRole.none;
    if (role == CommunityRole.banned || state.bannedByRefusal) {
      return CommunityJoinState.banned;
    }
    if (state.joinedOptimistically) return CommunityJoinState.joined;
    if (state.leftOptimistically) return CommunityJoinState.join;
    return role.isMember ? CommunityJoinState.joined : CommunityJoinState.join;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final community = state.community;
    if (community == null) {
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              child: Text('Community', style: theme.textTheme.titleLarge),
            ),
            if (state.status == CommunityDetailStatus.error)
              TextButton(
                onPressed: onRetry,
                child: const Text("Couldn't load Community details. Retry"),
              ),
          ],
        ),
      );
    }
    final role = community.role;
    final badge = communityRoleBadge(role);
    final join = joinStateOf(state);
    final banned = join == CommunityJoinState.banned;
    final hint = banned
        ? null
        : pinToHomeHint(
            pinned: state.pinned,
            full: state.pinFull,
            writeUnavailable: state.pinWriteUnavailable,
          );
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
                  child: Text(community.name, style: communityNameStyle(theme)),
                ),
              ),
              if (badge != null) ...[
                const SizedBox(width: AppSpacing.sm),
                AppStatusPill(label: badge),
              ],
            ],
          ),
          // The description, at most 2 lines (R10 review item 11; the About
          // tab has it whole). An empty one draws nothing.
          if (community.description.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text(
                community.description.trim(),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Semantics(
              button: true,
              label: '${communityMemberCountLabel(community)}, see members',
              excludeSemantics: true,
              onTap: onMembers,
              child: TextButton(
                onPressed: onMembers,
                style: TextButton.styleFrom(
                  textStyle: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                child: Text(communityMemberCountLabel(community)),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              CommunityJoinControl(
                state: join,
                name: community.name,
                busy: state.joinBusy,
                onJoin: onJoin,
                onLeave: role.isOwner ? null : onLeave,
              ),
              if (onCompose != null)
                OutlinedButton.icon(
                  style: kListOutlinedButtonStyle,
                  onPressed: onCompose,
                  icon: const Icon(Icons.edit_outlined, size: AppIconSize.md),
                  label: const Text('Post'),
                ),
              if (onModerationLog != null)
                OutlinedButton.icon(
                  style: kListOutlinedButtonStyle,
                  onPressed: onModerationLog,
                  icon: const Icon(Icons.shield_outlined, size: AppIconSize.md),
                  label: const Text('Moderation log'),
                ),
              if (!banned)
                PinToHomeButton(
                  pinned: state.pinned,
                  full: state.pinFull,
                  writeUnavailable: state.pinWriteUnavailable,
                  busy: state.pinBusy,
                  onToggle: onTogglePin,
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
}
