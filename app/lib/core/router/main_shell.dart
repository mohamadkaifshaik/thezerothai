import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../features/notifications/domain/notifications_feature_flag.dart';
import '../../features/notifications/presentation/bloc/unread_badge_cubit.dart';
import '../../features/onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../shared/widgets/app_side_column.dart';
import '../feature_flags/feature_flags.dart';
import '../widgets/privacy_policy_link.dart';
import 'app_router.dart';
import 'compose_gate.dart';
import '../widgets/responsive_scaffold.dart';

/// The bottom-nav/rail chrome around the three authenticated top-level
/// destinations: Home, (own) Profile, Settings. Wired as a `ShellRoute`
/// builder in [AppRouter] so it persists navigation state across pushes.
class MainShell extends StatelessWidget {
  const MainShell({super.key, required this.location, required this.child});

  final String location;
  final Widget child;

  /// The top-level destinations, in order. Notifications sits second and
  /// exists only with the `notifications` flag on (P6).
  static List<_Destination> _destinationsFor({required bool notifications}) => [
    const _Destination(
      _Tab.home,
      AppNavDestination(
        icon: Icons.home_outlined,
        selectedIcon: Icons.home,
        label: 'Home',
      ),
    ),
    if (notifications)
      const _Destination(
        _Tab.notifications,
        AppNavDestination(
          icon: Icons.notifications_none,
          selectedIcon: Icons.notifications,
          label: 'Notifications',
        ),
      ),
    const _Destination(
      _Tab.profile,
      AppNavDestination(
        icon: Icons.person_outline,
        selectedIcon: Icons.person,
        label: 'Profile',
      ),
    ),
    const _Destination(
      _Tab.settings,
      AppNavDestination(
        icon: Icons.settings_outlined,
        selectedIcon: Icons.settings,
        label: 'Settings',
      ),
    ),
  ];

  _Tab get _selectedTab {
    if (location.startsWith('/notifications')) return _Tab.notifications;
    if (location.startsWith('/profile') || location.startsWith('/u/')) {
      return _Tab.profile;
    }
    if (location.startsWith('/settings')) return _Tab.settings;
    return _Tab.home;
  }

  @override
  Widget build(BuildContext context) {
    final ownProfile = context.select(
      (OnboardingBloc bloc) => bloc.state.profile,
    );
    final ownHandle = ownProfile?.handle;

    final canCompose = canComposeAt(context, location);

    final notificationsEnabled = isFeatureEnabled(
      context,
      kFeatureNotifications,
    );
    // The badge cubit is read only when the tab exists.
    final unread = notificationsEnabled
        ? context.select((UnreadBadgeCubit cubit) => cubit.state)
        : 0;
    final tabs = _destinationsFor(notifications: notificationsEnabled);
    final selectedIndex = tabs.indexWhere((t) => t.tab == _selectedTab);
    final destinations = [
      for (final t in tabs)
        if (t.tab == _Tab.notifications && unread > 0)
          AppNavDestination(
            icon: t.destination.icon,
            selectedIcon: t.destination.selectedIcon,
            label: t.destination.label,
            badgeLabel: unreadBadgeLabel(unread),
            badgeSemanticLabel: '${unreadBadgeLabel(unread)} unread',
          )
        else
          t.destination,
    ];

    void openCompose() => context.push(AppRouter.composePath);
    return ResponsiveScaffold(
      selectedIndex: selectedIndex < 0 ? 0 : selectedIndex,
      // Phone: the floating button. Tablet and desktop: the rail's own entry
      // (icon, or the "Post" button when extended). All gated by canComposeAt.
      floatingActionButton: canCompose
          ? FloatingActionButton(
              tooltip: 'New post',
              onPressed: openCompose,
              child: const Icon(Icons.edit_outlined),
            )
          : null,
      onCompose: canCompose ? openCompose : null,
      sideColumn: AppSideColumn(
        // Only what is already loaded: no profile, no card (nothing is fetched).
        profile: ownHandle == null || ownHandle.isEmpty
            ? null
            : AppSideProfile(
                displayName: ownProfile?.displayName ?? '',
                handle: ownHandle,
                avatarUrl: ownProfile?.avatarThumbUrl ?? '',
                onTap: () => context.go(AppRouter.profilePath(ownHandle)),
              ),
        links: [
          AppSideLink(
            icon: Icons.settings_outlined,
            label: 'Settings',
            onTap: () => context.go(AppRouter.settingsPath),
          ),
          AppSideLink(
            icon: Icons.privacy_tip_outlined,
            label: 'Privacy Policy',
            onTap: () => launchPrivacyPolicy(context),
          ),
        ],
      ),
      destinations: destinations,
      onDestinationSelected: (index) {
        switch (tabs[index].tab) {
          case _Tab.home:
            context.go('/home');
          case _Tab.notifications:
            context.go(AppRouter.notificationsPath);
          case _Tab.profile:
            context.go(
              ownHandle == null || ownHandle.isEmpty
                  ? '/home'
                  : '/profile/$ownHandle',
            );
          case _Tab.settings:
            context.go('/settings');
        }
      },
      body: child,
    );
  }
}

enum _Tab { home, notifications, profile, settings }

class _Destination {
  const _Destination(this.tab, this.destination);
  final _Tab tab;
  final AppNavDestination destination;
}
