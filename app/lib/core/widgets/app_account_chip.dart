import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/presentation/bloc/auth_bloc.dart';
import '../../features/auth/presentation/bloc/auth_event.dart';
import '../../features/onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../shared/widgets/app_avatar.dart';
import '../router/app_router.dart';
import '../theme/app_theme.dart';

enum _AccountAction { profile, settings, signOut }

/// The account chip at the bottom of the navigation rail on wide layouts:
/// the 40dp avatar with, when [extended], the display name, the handle and a
/// "more" glyph. Tapping it opens a menu with Profile, Settings and Sign out
/// (the destinations that are not in the rail), like the drawer on phones.
///
/// It reads the profile the app already holds (`OnboardingBloc`): 0 RPCs.
/// Nothing is drawn until there is a profile.
class AppAccountChip extends StatelessWidget {
  const AppAccountChip({super.key, required this.extended});

  /// Show the name block next to the avatar (the labelled rail, >= 1200dp).
  final bool extended;

  @override
  Widget build(BuildContext context) {
    final profile = context.select((OnboardingBloc bloc) => bloc.state.profile);
    if (profile == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final name = profile.displayName.isEmpty
        ? '@${profile.handle}'
        : profile.displayName;
    final avatar = AppAvatar(
      url: profile.avatarThumbUrl,
      radius: AppSize.avatarMd / 2,
    );
    return PopupMenuButton<_AccountAction>(
      tooltip: 'Account menu',
      position: PopupMenuPosition.over,
      onSelected: (action) => _onSelected(context, action, profile.handle),
      itemBuilder: (context) => [
        if (profile.handle.isNotEmpty)
          const PopupMenuItem(
            value: _AccountAction.profile,
            child: Text('Profile'),
          ),
        const PopupMenuItem(
          value: _AccountAction.settings,
          child: Text('Settings'),
        ),
        const PopupMenuItem(
          value: _AccountAction.signOut,
          child: Text('Sign out'),
        ),
      ],
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: AppSpacing.minTapTarget),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.sm),
          child: extended
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    avatar,
                    const SizedBox(width: AppSpacing.smd),
                    Flexible(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall,
                          ),
                          Text(
                            '@${profile.handle}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    const Icon(Icons.more_horiz, size: AppIconSize.md),
                  ],
                )
              : avatar,
        ),
      ),
    );
  }

  static void _onSelected(
    BuildContext context,
    _AccountAction action,
    String handle,
  ) {
    switch (action) {
      case _AccountAction.profile:
        context.go(AppRouter.profilePath(handle));
      case _AccountAction.settings:
        context.go(AppRouter.settingsPath);
      case _AccountAction.signOut:
        context.read<AuthBloc>().add(const AuthSignOutRequested());
    }
  }
}
