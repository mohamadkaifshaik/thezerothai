import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/primitives/pin_to_home.dart';
import '../../../../shared/widgets/primitives/app_status_pill.dart';
import '../../domain/community_role.dart';
import '../bloc/community_detail_state.dart';
import 'community_join_control.dart';
import 'community_row.dart';

/// The top of `/communities/:id` (W5-32): name, "N members" (opens the members
/// page), the Join / Joined / Banned control and Pin / Unpin from Home.
/// Presentation only: the screen wires the callbacks.
///
/// - The control reads the server's `viewer_role` (through the state); a Join
///   in flight already reads "Joined" and a Leave in flight already reads
///   "Join" (optimistic). The owner cannot leave, so their "Joined" is inert.
/// - A banned viewer sees the muted "You can't join this Community" and no Pin.
/// - At [kMaxPinnedHomeTabs] pinned, Pin is disabled and a hint says why. The
///   buttons wrap, so they fit at 360 dp and text scale 2.0.
class CommunityHeader extends StatelessWidget {
  const CommunityHeader({
    super.key,
    required this.state,
    required this.onMembers,
    required this.onJoin,
    required this.onLeave,
    required this.onTogglePin,
    required this.onRetry,
  });

  final CommunityDetailState state;
  final VoidCallback onMembers;
  final VoidCallback onJoin;
  final VoidCallback onLeave;
  final VoidCallback onTogglePin;
  final VoidCallback onRetry;

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
                  child: Text(
                    community.name,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
              if (badge != null) ...[
                const SizedBox(width: AppSpacing.sm),
                AppStatusPill(label: badge),
              ],
            ],
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
