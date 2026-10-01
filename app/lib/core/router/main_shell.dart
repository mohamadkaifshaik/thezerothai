import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../features/onboarding/presentation/bloc/onboarding_bloc.dart';
import '../widgets/responsive_scaffold.dart';

/// The bottom-nav/rail chrome around the three authenticated top-level
/// destinations: Home, (own) Profile, Settings. Wired as a `ShellRoute`
/// builder in [AppRouter] so it persists navigation state across pushes.
class MainShell extends StatelessWidget {
  const MainShell({super.key, required this.location, required this.child});

  final String location;
  final Widget child;

  static const _destinations = [
    AppNavDestination(
      icon: Icons.home_outlined,
      selectedIcon: Icons.home,
      label: 'Home',
    ),
    AppNavDestination(
      icon: Icons.person_outline,
      selectedIcon: Icons.person,
      label: 'Profile',
    ),
    AppNavDestination(
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings,
      label: 'Settings',
    ),
  ];

  int get _selectedIndex {
    if (location.startsWith('/profile') || location.startsWith('/u/')) return 1;
    if (location.startsWith('/settings')) return 2;
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final ownHandle = context.select(
      (OnboardingBloc bloc) => bloc.state.profile?.handle,
    );

    return ResponsiveScaffold(
      selectedIndex: _selectedIndex,
      destinations: _destinations,
      onDestinationSelected: (index) {
        switch (index) {
          case 0:
            context.go('/home');
          case 1:
            context.go(
              ownHandle == null || ownHandle.isEmpty
                  ? '/home'
                  : '/profile/$ownHandle',
            );
          case 2:
            context.go('/settings');
        }
      },
      body: child,
    );
  }
}
