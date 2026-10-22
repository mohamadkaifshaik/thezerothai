import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../features/notifications/domain/notifications_feature_flag.dart';
import '../../features/notifications/presentation/bloc/unread_badge_cubit.dart';
import '../../features/onboarding/presentation/bloc/onboarding_bloc.dart';
import '../feature_flags/feature_flags.dart';
import '../feature_flags/ui_shell_feature_flag.dart';
import '../widgets/app_account_chip.dart';
import '../widgets/app_drawer.dart';
import '../widgets/responsive_scaffold.dart';
import 'app_router.dart';
import 'compose_gate.dart';

/// The navigation chrome around the authenticated top-level destinations.
///
/// With the `ui_shell` flag on (decision D3): Home, Notifications (flag) and
/// the own Profile in the bottom bar / rail; Settings and Sign out live in the
/// avatar drawer (phones) and the account chip menu (wide screens), like X.
/// With it off: the legacy chrome, Settings as a fourth destination, no
/// drawer, no account chip, and the compose button wherever posting is
/// offered. The flag gates the navigation structure only, not the colours.
/// Wired as a `ShellRoute` builder in
/// [AppRouter] so it persists navigation state across pushes.
class MainShell extends StatelessWidget {
  const MainShell({super.key, required this.location, required this.child});

  final String location;
  final Widget child;

  /// The destinations, in order. Notifications sits second and exists only
  /// with the `notifications` flag on (P6).
  static List<_Destination> _destinationsFor({
    required bool notifications,
    required bool settings,
  }) => [
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
    if (settings)
      const _Destination(
        _Tab.settings,
        AppNavDestination(
          icon: Icons.settings_outlined,
          selectedIcon: Icons.settings,
          label: 'Settings',
        ),
      ),
  ];

  /// The selected tab, or null on screens that belong to no tab (Settings in
  /// the new shell, where it is not a destination).
  _Tab? _selectedTab({required bool settingsTab}) {
    if (location.startsWith('/notifications')) return _Tab.notifications;
    if (location.startsWith('/profile') || location.startsWith('/u/')) {
      return _Tab.profile;
    }
    if (location.startsWith('/settings')) {
      return settingsTab ? _Tab.settings : null;
    }
    return _Tab.home;
  }

  @override
  Widget build(BuildContext context) {
    final ownHandle = context.select(
      (OnboardingBloc bloc) => bloc.state.profile?.handle,
    );

    final canCompose = canComposeAt(context, location);
    final newShell = isFeatureEnabled(context, kFeatureUiShell);
    final showFab = newShell ? showComposeFabAt(context, location) : canCompose;

    final notificationsEnabled = isFeatureEnabled(
      context,
      kFeatureNotifications,
    );
    // The badge cubit is read only when the tab exists.
    final unread = notificationsEnabled
        ? context.select((UnreadBadgeCubit cubit) => cubit.state)
        : 0;
    final tabs = _destinationsFor(
      notifications: notificationsEnabled,
      settings: !newShell,
    );
    final selected = _selectedTab(settingsTab: !newShell);
    final selectedIndex = selected == null
        ? null
        : tabs.indexWhere((t) => t.tab == selected);
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

    return ResponsiveScaffold(
      selectedIndex: selectedIndex == null || selectedIndex < 0
          ? null
          : selectedIndex,
      onCompose: canCompose ? () => context.push(AppRouter.composePath) : null,
      showFab: showFab,
      drawer: newShell ? const AppDrawer() : null,
      accountChipBuilder: newShell
          ? (extended) => AppAccountChip(extended: extended)
          : null,
      destinations: destinations,
      onDestinationSelected: (index) {
        switch (tabs[index].tab) {
          case _Tab.home:
            context.go('/home');
          case _Tab.notifications:
            context.go(AppRouter.notificationsPath);
          case _Tab.settings:
            context.go(AppRouter.settingsPath);
          case _Tab.profile:
            context.go(
              ownHandle == null || ownHandle.isEmpty
                  ? '/home'
                  : '/profile/$ownHandle',
            );
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
