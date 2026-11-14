import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/presentation/request_sign_out.dart';
import '../../features/engagement/domain/bookmarks_feature_flag.dart';
import '../../features/graph/data/graph_repository.dart';
import '../../features/graph/domain/follow_requests_entry.dart';
import '../../features/graph/domain/graph_list_extra.dart';
import '../../features/communities/domain/communities_feature_flag.dart';
import '../../features/lists/domain/lists_feature_flag.dart';
import '../../features/onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../features/posts/domain/posts_feature_flag.dart';
import '../router/shell_entries.dart';
import '../../gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import '../../shared/widgets/primitives/app_avatar.dart';
import '../feature_flags/feature_flags.dart';
import '../router/app_router.dart';
import '../theme/app_theme.dart';

/// The account drawer of narrow layouts (phones, under 600dp; tablet and
/// desktop use the rail and the account chip menu, never this), opened by the
/// avatar button of the top bar (`AppTopBar`). Top to bottom: the account
/// header (avatar, name, handle, the Following / Followers counts, an aqua
/// corner glow), a grid of up to four tinted quick tiles (Articles, Lists,
/// Communities, History), Profile and Follow requests, then the shell entries
/// (Creator Studio, Premium, Advertise, Calls), Settings and Privacy and Sign
/// out. Plans is a primary destination (bar and rail), so it has no row here
/// (ADR-0034 3, D5).
///
/// It reads the profile the app already holds (`OnboardingBloc`): 0 RPCs. A
/// row closes the drawer, then navigates; the counts open the same lists as
/// the profile header. Each destination keeps its existing feature gate. The
/// whole drawer scrolls, so short screens and large text never overflow.
class AppDrawer extends StatelessWidget {
  const AppDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    final profile = context.select((OnboardingBloc bloc) => bloc.state.profile);
    final handle = profile?.handle ?? '';
    final shellEntries = shellEntriesFor(context);
    final pendingRequests = context.select(
      (OnboardingBloc bloc) => bloc.state.pendingFollowRequestCount,
    );
    final showFollowRequests = followRequestsEntryVisible(context);
    final tiles = <_DrawerTile>[
      // Needs `posts` (the entry and route).
      if (isFeatureEnabled(context, kFeaturePosts))
        _DrawerTile(
          icon: Icons.article_outlined,
          label: 'Articles',
          onTap: () => _go(context, () => context.go(AppRouter.articlesPath)),
        ),
      // Needs `lists` (the drawer only exists with `ui_shell`).
      if (isFeatureEnabled(context, kFeatureLists))
        _DrawerTile(
          key: const ValueKey('drawer-lists'),
          icon: Icons.list_alt_outlined,
          label: 'Lists',
          onTap: () => _go(context, () => context.go(AppRouter.listsPath)),
        ),
      // Needs `communities` (the drawer only exists with `ui_shell`).
      if (isFeatureEnabled(context, kFeatureCommunities))
        _DrawerTile(
          key: const ValueKey('drawer-communities'),
          icon: Icons.groups_outlined,
          label: 'Communities',
          onTap: () =>
              _go(context, () => context.go(AppRouter.communitiesPath)),
        ),
      if (isFeatureEnabled(context, kFeatureBookmarks) &&
          isFeatureEnabled(context, kFeaturePosts))
        _DrawerTile(
          icon: Icons.bookmark_border,
          label: 'History',
          onTap: () => _go(context, () => context.go(AppRouter.bookmarksPath)),
        ),
    ];
    final accountRows = <Widget>[
      if (handle.isNotEmpty)
        _DrawerRow(
          icon: Icons.person_outline,
          label: 'Profile',
          chevron: true,
          onTap: () =>
              _go(context, () => context.go(AppRouter.profilePath(handle))),
        ),
      // A protected account's requests (or any pending count). Needs
      // `graph`; never `private_accounts` for a protected caller (undo rule).
      if (showFollowRequests)
        _DrawerRow(
          key: const ValueKey('drawer-follow-requests'),
          icon: Icons.person_add_alt_outlined,
          label: 'Follow requests',
          chevron: true,
          badge: pendingRequests > 0
              ? followRequestBadgeText(pendingRequests)
              : null,
          badgeSpoken: pendingRequests > 0
              ? followRequestBadgeSpoken(pendingRequests)
              : null,
          onTap: () =>
              _go(context, () => context.go(AppRouter.followRequestsPath)),
        ),
    ];
    final dividerColor = Theme.of(context).brightness == Brightness.dark
        ? AppPalette.drawerDividerDark
        : AppPalette.drawerDividerLight;
    Widget divider() => Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      child: Divider(height: 1, thickness: 1, color: dividerColor),
    );
    return Drawer(
      // 320dp, never more than 85 % of the screen on a very narrow phone.
      width: math.min(
        AppSize.drawerWidth,
        MediaQuery.sizeOf(context).width * 0.85,
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(bottom: AppSpacing.md),
          children: [
            if (profile != null) _AccountHeader(profile: profile),
            if (tiles.isNotEmpty) _TileGrid(tiles: tiles),
            if (accountRows.isNotEmpty) ...[
              if (profile != null || tiles.isNotEmpty) divider(),
              ...accountRows,
            ],
            divider(),
            for (final entry in shellEntries)
              _DrawerRow(
                key: ValueKey('shell-${entry.kind.name}'),
                icon: entry.icon,
                label: entry.label,
                chevron: true,
                onTap: () => _go(context, () => openShellEntry(context, entry)),
              ),
            _DrawerRow(
              icon: Icons.settings_outlined,
              label: 'Settings and Privacy',
              chevron: true,
              onTap: () =>
                  _go(context, () => context.go(AppRouter.settingsPath)),
            ),
            // No chevron: it does not open a page.
            _DrawerRow(
              icon: Icons.logout,
              label: 'Sign out',
              onTap: () =>
                  _go(context, () => unawaited(requestSignOut(context))),
            ),
          ],
        ),
      ),
    );
  }

  /// Closes the drawer, then runs [action].
  static void _go(BuildContext context, VoidCallback action) {
    Navigator.of(context).pop();
    action();
  }
}

class _AccountHeader extends StatelessWidget {
  const _AccountHeader({required this.profile});

  final identity.Profile profile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final muted = theme.colorScheme.onSurfaceVariant;
    final name = profile.displayName.isEmpty
        ? '@${profile.handle}'
        : profile.displayName;
    const glow = AppSize.drawerGlow;
    return Stack(
      children: [
        // The decorative corner glow: a big aqua disc cut by the drawer edge
        // and a mint one over it. Not part of the semantics.
        Positioned(
          top: 0,
          right: 0,
          width: glow,
          height: glow * 0.9,
          child: ExcludeSemantics(
            child: ClipRect(
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    top: -glow * 0.45,
                    right: -glow * 0.3,
                    width: glow,
                    height: glow,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: dark
                            ? AppDrawerGlow.aquaDark
                            : AppDrawerGlow.aquaLight,
                      ),
                    ),
                  ),
                  Positioned(
                    top: glow * 0.08,
                    right: -glow * 0.28,
                    width: glow * 0.6,
                    height: glow * 0.6,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: dark
                            ? AppDrawerGlow.mintDark
                            : AppDrawerGlow.mintLight,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.md,
            AppSpacing.md,
            AppSpacing.sm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  AppAvatar(
                    url: profile.avatarThumbUrl,
                    radius: AppSize.drawerAvatar / 2,
                  ),
                  const SizedBox(width: AppSpacing.smd),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          '@${profile.handle}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.lg,
                children: [
                  _CountLink(
                    count: profile.followingCount.toInt(),
                    label: 'Following',
                    onTap: () => _open(
                      context,
                      AppRouter.followingPath(profile.handle),
                      profile,
                    ),
                  ),
                  _CountLink(
                    count: profile.followersCount.toInt(),
                    label: 'Followers',
                    onTap: () => _open(
                      context,
                      AppRouter.followersPath(profile.handle),
                      profile,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  static void _open(BuildContext context, String path, identity.Profile who) {
    Navigator.of(context).pop();
    context.push(
      path,
      extra: GraphListExtra(userId: who.userId, displayName: who.displayName),
    );
  }
}

class _CountLink extends StatelessWidget {
  const _CountLink({
    required this.count,
    required this.label,
    required this.onTap,
  });

  final int count;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Semantics(
      button: true,
      label: '$count $label',
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppSpacing.minTapTarget),
          child: Center(
            widthFactor: 1,
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '$count',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  TextSpan(
                    text: ' $label',
                    style: theme.textTheme.bodyLarge?.copyWith(color: muted),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One quick tile of the grid: a tinted rounded card, a centred 32dp outline
/// icon in the primary colour and the label below.
class _DrawerTile {
  const _DrawerTile({
    this.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final Key? key;
  final IconData icon;
  final String label;
  final VoidCallback onTap;
}

/// The tiles in two columns, tints in a checkerboard (blue, teal / teal,
/// blue) as in the design. With an odd count the last tile spans the full
/// width instead of leaving a hole: 1 tile is one wide card, 3 tiles are
/// 2 + 1. (A half-width tile with an empty cell beside it reads as a missing
/// item; a full-width card reads as intended.)
class _TileGrid extends StatelessWidget {
  const _TileGrid({required this.tiles});

  final List<_DrawerTile> tiles;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final blue = dark
        ? AppPalette.drawerTileBlueDark
        : AppPalette.drawerTileBlue;
    final teal = dark
        ? AppPalette.drawerTileTealDark
        : AppPalette.drawerTileTeal;
    final rows = <Widget>[];
    for (var i = 0; i < tiles.length; i += 2) {
      final pair = tiles.skip(i).take(2).toList();
      final row = i ~/ 2;
      rows.add(
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var c = 0; c < pair.length; c++) ...[
                if (c > 0) const SizedBox(width: AppSpacing.smd),
                Expanded(
                  child: _TileCard(
                    tile: pair[c],
                    tint: (row + c).isEven ? blue : teal,
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
        AppSpacing.sm,
      ),
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const SizedBox(height: AppSpacing.smd),
            rows[i],
          ],
        ],
      ),
    );
  }
}

class _TileCard extends StatelessWidget {
  const _TileCard({required this.tile, required this.tint});

  final _DrawerTile tile;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label: tile.label,
      excludeSemantics: true,
      onTap: tile.onTap,
      child: Material(
        key: tile.key,
        color: tint,
        borderRadius: BorderRadius.circular(AppRadius.cardSmall),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: tile.onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: AppSize.drawerTile),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm,
                vertical: AppSpacing.smd,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    tile.icon,
                    size: AppSize.drawerTileIcon,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      tile.label,
                      maxLines: 1,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One 56dp destination row: a 24dp outline icon in the primary colour, a
/// bold label and, when it opens a page, a trailing chevron.
class _DrawerRow extends StatelessWidget {
  const _DrawerRow({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.chevron = false,
    this.badge,
    this.badgeSpoken,
  });

  final IconData icon;
  final String label;
  final bool chevron;

  /// A count pill after the label (the follow-requests badge), and what a
  /// screen reader says for it.
  final String? badge;
  final String? badgeSpoken;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label: badgeSpoken == null ? label : '$label, $badgeSpoken',
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppSize.drawerRow),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: AppIconSize.lg,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: AppSpacing.lg),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleLarge,
                  ),
                ),
                if (badge != null) ...[
                  const SizedBox(width: AppSpacing.sm),
                  FollowRequestCountBadge(text: badge!),
                ],
                if (chevron) ...[
                  const SizedBox(width: AppSpacing.sm),
                  Icon(
                    Icons.chevron_right,
                    size: AppIconSize.lg,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The follow requests count: "7", and "1000+" once the server's cap (1,000)
/// is reached (the count stops there, it may be higher).
String followRequestBadgeText(int count) =>
    count >= kPendingRequestsCap ? '$kPendingRequestsCap+' : '$count';

/// What a screen reader says for [followRequestBadgeText].
String followRequestBadgeSpoken(int count) => count >= kPendingRequestsCap
    ? '$kPendingRequestsCap or more pending'
    : '$count pending';

/// `GetMe.pending_follow_request_count` stops counting at this.
const kPendingRequestsCap = 1000;

/// A small strong pill (AA contrast, like the primary pill button) with a count; the number is also in the row's spoken
/// label, so this is excluded from semantics with the rest of the row.
class FollowRequestCountBadge extends StatelessWidget {
  const FollowRequestCountBadge({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      constraints: const BoxConstraints(minWidth: AppSpacing.lg),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: context.appColors.strongPillFill,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        text,
        maxLines: 1,
        textAlign: TextAlign.center,
        style: theme.textTheme.labelMedium?.copyWith(
          color: context.appColors.strongPillLabel,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// Whether the "Follow requests" entry is shown (drawer row, account menu of
/// wide layouts): [followRequestsAllowed] for the caller, and not while
/// `ListFollowRequests` is backed off for the session (`followRequestsUnavailable`).
/// Reads the caller from `OnboardingBloc` and the backoff from the
/// `GraphRepository` in the tree; 0 RPCs. Call it at build or open time.
bool followRequestsEntryVisible(BuildContext context) {
  final features = context.select(
    (OnboardingBloc bloc) => bloc.state.enabledFeatures,
  );
  final protected = context.select(
    (OnboardingBloc bloc) => bloc.state.profile?.isPrivate ?? false,
  );
  return followRequestsAllowed(
        enabledFeatures: features,
        isProtected: protected,
      ) &&
      !context.read<GraphRepository>().followRequestsUnavailable;
}
