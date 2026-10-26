import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/presentation/bloc/auth_bloc.dart';
import '../../features/auth/presentation/bloc/auth_event.dart';
import '../../features/engagement/domain/bookmarks_feature_flag.dart';
import '../../features/onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../features/posts/domain/posts_feature_flag.dart';
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
/// with the `bookmarks` and `posts` flags on; later waves add Lists here,
/// behind its flag.
class AppDrawer extends StatelessWidget {
  const AppDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    final profile = context.select((OnboardingBloc bloc) => bloc.state.profile);
    final handle = profile?.handle ?? '';
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
            // Needs `bookmarks` (the entry) and `posts` (the route).
            if (isFeatureEnabled(context, kFeatureBookmarks) &&
                isFeatureEnabled(context, kFeaturePosts))
              _DrawerRow(
                icon: Icons.bookmark_border,
                label: 'Bookmarks',
                onTap: () =>
                    _go(context, () => context.go(AppRouter.bookmarksPath)),
              ),
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
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label: label,
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}
