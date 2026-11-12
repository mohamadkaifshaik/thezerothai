import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/primitives/pin_to_home.dart';
import '../../../../shared/widgets/primitives/app_status_pill.dart';
import '../../../../shared/widgets/primitives/app_skeleton.dart';
import '../../../lists/presentation/widgets/list_unavailable_view.dart'
    show kListOutlinedButtonStyle;
import '../../../../gen/dzeroth/communities/v1/communities.pbenum.dart'
    show CommunityStatus;
import '../../domain/community_role.dart';
import '../bloc/community_detail_state.dart';
import 'community_join_control.dart';
import 'community_about.dart' show communityModeratorsOf;
import 'community_hero.dart';
import 'community_member_avatars.dart';
import 'community_row.dart';

/// A community's name as its page header draws it (the design's `h1`: 32 sp
/// display on a phone, 48 sp in the tablet and desktop hero ([wide]); w800,
/// line height 1.02, tracking -0.035 em; R10b), shared by the Create preview
/// so the preview matches the page.
TextStyle? communityNameStyle(ThemeData theme, {bool wide = false}) {
  final size = AppTypeTokens.displaySizes[wide ? 4 : 1]; // 48 : 32
  return theme.textTheme.displaySmall?.copyWith(
    fontSize: size,
    fontWeight: AppTypeTokens.weightDisplay,
    height: AppTypeTokens.displayLineHeight,
    letterSpacing: size * AppTypeTokens.displayTracking,
  );
}

/// The top of `/communities/:id`: name, "N members" (opens the members
/// page), the Join / Joined / Banned control and Pin / Unpin from Home.
/// Presentation only: the screen wires the callbacks. On tablet and desktop
/// ([wide]) the name, description and people sit on the navy hero card and
/// the buttons under it.
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
    this.wide = false,
    this.onCompose,
    this.onModerationLog,
  });

  final CommunityDetailState state;
  final VoidCallback onMembers;
  final VoidCallback onJoin;
  final VoidCallback onLeave;
  final VoidCallback onTogglePin;
  final VoidCallback onRetry;

  /// The tablet and desktop look (the hero card).
  final bool wide;

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
      if (state.status == CommunityDetailStatus.error) {
        return Padding(
          padding: _kHeaderPadding,
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              onPressed: onRetry,
              child: const Text("Couldn't load Community details. Retry"),
            ),
          ),
        );
      }
      return _HeaderPlaceholder(wide: wide);
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
    final countLabel = communityMemberCountLabel(community);
    final people = communityModeratorsOf(state);
    // Its own builder: on the hero the context's theme is the dark one.
    final identity = Builder(
      builder: (context) {
        final theme = Theme.of(context);
        final colors = context.appColors;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (wide)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.smd),
                child: Text(
                  'Community'.toUpperCase(),
                  style: AppTextStyles.eyebrow(theme)
                      .copyWith(color: AppPalette.tealElectric),
                ),
              ),
            Row(
              children: [
                Flexible(
                  child: Semantics(
                    header: true,
                    child: Text(
                      community.name,
                      style: communityNameStyle(theme, wide: wide),
                    ),
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
                padding: const EdgeInsets.only(top: AppSpacing.sm),
                child: Text(
                  community.description.trim(),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  // dz: 14 w500 in text2.
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                    color: colors.text2,
                  ),
                ),
              ),
            // The people row: avatars, "N members" (opens the members page),
            // and Join / Joined at the end. It wraps (Join under the count)
            // when it does not fit, at large text.
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.xs,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CommunityMemberAvatars(people: people),
                      Flexible(
                        child: Semantics(
                          button: true,
                          label: '$countLabel, see members',
                          excludeSemantics: true,
                          onTap: onMembers,
                          child: TextButton(
                            onPressed: onMembers,
                            style: TextButton.styleFrom(
                              foregroundColor: colors.accentText,
                              // The gap after the avatars, only when there are
                              // avatars.
                              padding: EdgeInsetsDirectional.only(
                                start: people.isEmpty ? 0 : AppSpacing.smd,
                              ),
                              minimumSize: const Size(
                                AppSpacing.minTapTarget,
                                AppSpacing.minTapTarget,
                              ),
                              textStyle: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            child: Text(countLabel),
                          ),
                        ),
                      ),
                    ],
                  ),
                  CommunityJoinControl(
                    state: join,
                    name: community.name,
                    busy: state.joinBusy,
                    onJoin: onJoin,
                    onLeave: role.isOwner ? null : onLeave,
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
    final actions = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (onCompose != null || onModerationLog != null || !banned) ...[
          const SizedBox(height: AppSpacing.xs),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
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
        ],
        if (hint != null)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: Text(
              hint,
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ),
      ],
    );
    if (wide) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CommunityHero(child: identity),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppCommunitiesLayout.heroPaddingH,
              AppSpacing.smd,
              AppCommunitiesLayout.heroPaddingH,
              AppSpacing.smd,
            ),
            child: actions,
          ),
        ],
      );
    }
    return Padding(
      padding: _kHeaderPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [identity, actions],
      ),
    );
  }
}

/// The header's side inset (dz `20px`) and padding (`16px 20px 12px`).
const double _kInset = 20;

const _kHeaderPadding = EdgeInsets.fromLTRB(
  _kInset,
  AppSpacing.md,
  _kInset,
  AppSpacing.smd,
);

/// The header while `GetCommunity` is in flight: the loaded header's shape,
/// block for block (name line, one description line, the 48 dp people row,
/// the 48 dp row of Post / Moderation log / Pin buttons), so the tabs under
/// it do not move when it answers. The description is drawn as one line (a
/// longer one adds its second line when it arrives).
class _HeaderPlaceholder extends StatelessWidget {
  const _HeaderPlaceholder({required this.wide});

  /// The tablet and desktop look: the same blocks on the hero card.
  final bool wide;

  /// A 48 dp slot holding a 36 dp pill, as the loaded buttons sit.
  static Widget _slot(double width) => SizedBox(
    height: AppSpacing.minTapTarget,
    child: Align(
      alignment: AlignmentDirectional.centerStart,
      child: AppSkeletonBlock(width: width, height: 36, radius: AppRadius.pill),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final body = Theme.of(context).textTheme.bodyMedium;
    final name = Theme.of(context).textTheme.displaySmall;
    // The loaded lines' heights at the ambient text scale.
    final scaler = MediaQuery.textScalerOf(context);
    final nameHeight =
        scaler.scale(AppTypeTokens.displaySizes[wide ? 4 : 1]) *
        (name?.height ?? 1.02);
    final lineHeight = scaler.scale(14) * (body?.height ?? 1.4);
    final identity = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (wide)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.smd),
            child: AppSkeletonBlock(
              width: 96,
              height: scaler.scale(AppTypeTokens.eyebrowSize) * 1.33,
            ),
          ),
        AppSkeletonBlock(width: 200, height: nameHeight),
        const SizedBox(height: AppSpacing.sm),
        SizedBox(
          height: lineHeight,
          child: const Align(
            alignment: AlignmentDirectional.centerStart,
            child: AppSkeletonBlock(width: 260, height: 12),
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        const SizedBox(
          height: AppSpacing.minTapTarget,
          child: Row(
            children: [
              AppSkeletonBlock(
                width: kCommunityHeaderAvatarSize,
                height: kCommunityHeaderAvatarSize,
                circle: true,
              ),
              SizedBox(width: AppSpacing.smd),
              AppSkeletonBlock(width: 96, height: 14),
              Spacer(),
              AppSkeletonBlock(width: 88, height: 36, radius: AppRadius.pill),
            ],
          ),
        ),
      ],
    );
    final actions = Row(
      children: [
        _slot(72),
        const SizedBox(width: AppSpacing.sm),
        _slot(120),
      ],
    );
    return AppSkeletonScope(
      semanticsLabel: 'Loading Community',
      child: wide
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                CommunityHero(child: identity),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppCommunitiesLayout.heroPaddingH,
                    AppSpacing.smd + AppSpacing.xs,
                    AppCommunitiesLayout.heroPaddingH,
                    AppSpacing.smd,
                  ),
                  child: actions,
                ),
              ],
            )
          : Padding(
              padding: _kHeaderPadding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  identity,
                  const SizedBox(height: AppSpacing.xs),
                  actions,
                ],
              ),
            ),
    );
  }
}
