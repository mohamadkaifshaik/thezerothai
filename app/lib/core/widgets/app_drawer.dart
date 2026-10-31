import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/presentation/bloc/auth_bloc.dart';
import '../../features/auth/presentation/bloc/auth_event.dart';
import '../../features/engagement/domain/bookmarks_feature_flag.dart';
import '../../features/graph/data/graph_repository.dart';
import '../../features/graph/domain/follow_requests_entry.dart';
import '../../features/lists/domain/lists_feature_flag.dart';
import '../../features/onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../features/posts/domain/posts_feature_flag.dart';
import '../../features/shells/domain/shell_entries.dart';
import '../../gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import '../../shared/widgets/app_avatar.dart';
import '../feature_flags/feature_flags.dart';
import '../router/app_router.dart';
import '../theme/app_theme.dart';

/// The account drawer of narrow layouts, opened by the avatar button of the
/// top bar (`AppTopBar`): the account block (avatar, name, handle and the
/// Following / Followers counts) and one 56dp row per destination that is not
/// in the bottom bar: Profile, Settings, Sign out.
///
/// It reads the profile the app already holds (`OnboardingBloc`): 0 RPCs. A
/// row closes the drawer, then navigates; the counts open the same lists as
/// the profile header. Bookmarks (W2-7) sits between Profile and Settings
/// with the `bookmarks` and `posts` flags on; Lists (W5-11) follows it with `lists` on;
/// behind its flag. With `shells` and `ui_shell` on, the shell rows (Creator
/// tools, Premium, Advertise, Calls) follow under a divider, before Settings.
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
    return Drawer(
      // 277dp, never more than 85 % of the screen on a very narrow phone.
      width: math.min(
        AppSize.drawerWidth,
        MediaQuery.sizeOf(context).width * 0.85,
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(bottom: AppSpacing.md),
          children: [
            if (profile != null) _AccountHeader(profile: profile),
            if (handle.isNotEmpty)
              _DrawerRow(
                icon: Icons.person_outline,
                label: 'Profile',
                onTap: () => _go(
                  context,
                  () => context.go(AppRouter.profilePath(handle)),
                ),
              ),
            // W3-34: a protected account's requests (or any pending count). Needs
            // `graph`; never `private_accounts` for a protected caller (undo rule).
            if (showFollowRequests)
              _DrawerRow(
                key: const ValueKey('drawer-follow-requests'),
                icon: Icons.person_add_alt_outlined,
                label: 'Follow requests',
                badge: pendingRequests > 0
                    ? followRequestBadgeText(pendingRequests)
                    : null,
                badgeSpoken: pendingRequests > 0
                    ? followRequestBadgeSpoken(pendingRequests)
                    : null,
                onTap: () => _go(
                  context,
                  () => context.go(AppRouter.followRequestsPath),
                ),
              ),
            // Needs `bookmarks` (the entry) and `posts` (the route).
            if (isFeatureEnabled(context, kFeatureBookmarks) &&
                isFeatureEnabled(context, kFeaturePosts))
              _DrawerRow(
                icon: Icons.bookmark_border,
                label: 'History',
                onTap: () =>
                    _go(context, () => context.go(AppRouter.bookmarksPath)),
              ),
            // W5-11: needs `lists` (the drawer only exists with `ui_shell`).
            if (isFeatureEnabled(context, kFeatureLists))
              _DrawerRow(
                key: const ValueKey('drawer-lists'),
                icon: Icons.list_alt_outlined,
                label: 'Lists',
                onTap: () =>
                    _go(context, () => context.go(AppRouter.listsPath)),
              ),
            // The read-only shells (W8-2): after every feature row, before
            // Settings, under a hairline. Needs `shells` and `ui_shell`.
            if (shellEntries.isNotEmpty) ...[
              const Divider(height: 1),
              for (final entry in shellEntries)
                _DrawerRow(
                  key: ValueKey('shell-${entry.kind.name}'),
                  icon: entry.icon,
                  label: entry.label,
                  onTap: () =>
                      _go(context, () => openShellEntry(context, entry)),
                ),
            ],
            _DrawerRow(
              icon: Icons.settings_outlined,
              label: 'Settings',
              onTap: () =>
                  _go(context, () => context.go(AppRouter.settingsPath)),
            ),
            _DrawerRow(
              icon: Icons.logout,
              label: 'Sign out',
              onTap: () => _go(
                context,
                () =>
                    context.read<AuthBloc>().add(const AuthSignOutRequested()),
              ),
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
    final muted = theme.colorScheme.onSurfaceVariant;
    final name = profile.displayName.isEmpty
        ? '@${profile.handle}'
        : profile.displayName;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppAvatar(url: profile.avatarThumbUrl, radius: AppSize.avatarMd / 2),
          const SizedBox(height: AppSpacing.smd),
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium,
          ),
          Text(
            '@${profile.handle}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(color: muted),
          ),
          const SizedBox(height: AppSpacing.smd),
          Wrap(
            spacing: AppSpacing.md,
            children: [
              _CountLink(
                count: profile.followingCount.toInt(),
                label: 'Following',
                onTap: () => _open(
                  context,
                  AppRouter.followingPath(profile.handle),
                  profile.userId,
                ),
              ),
              _CountLink(
                count: profile.followersCount.toInt(),
                label: 'Followers',
                onTap: () => _open(
                  context,
                  AppRouter.followersPath(profile.handle),
                  profile.userId,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static void _open(BuildContext context, String path, String userId) {
    Navigator.of(context).pop();
    context.push(path, extra: userId);
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
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  TextSpan(
                    text: ' $label',
                    style: theme.textTheme.bodyMedium?.copyWith(color: muted),
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

/// One 56dp destination row: a 24dp outline icon and a bold 20dp label.
class _DrawerRow extends StatelessWidget {
  const _DrawerRow({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.badge,
    this.badgeSpoken,
  });

  final IconData icon;
  final String label;

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
                Icon(icon, size: AppIconSize.lg),
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

/// `GetMe.pending_follow_request_count` stops counting at this (W3-26b).
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
/// `ListFollowRequests` is backed off for the session (`followRequestsUnavailable`,
/// W3-34b). Reads the caller from `OnboardingBloc` and the backoff from the
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
