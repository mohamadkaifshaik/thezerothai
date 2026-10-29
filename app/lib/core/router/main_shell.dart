import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../features/engagement/domain/bookmarks_feature_flag.dart';
import '../../features/graph/presentation/graph_feature_flags.dart';
import '../../features/graph/presentation/widgets/who_to_follow_card.dart';
import '../../features/messages/domain/messaging_feature_flag.dart';
import '../../features/messages/presentation/bloc/messages_badge_cubit.dart';
import '../../features/notifications/domain/notifications_feature_flag.dart';
import '../../features/notifications/presentation/bloc/unread_badge_cubit.dart';
import '../../features/onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../features/posts/domain/posts_feature_flag.dart';
import '../../features/shells/domain/shell_entries.dart';
import '../../shared/widgets/app_side_column.dart';
import '../feature_flags/feature_flags.dart';
import '../feature_flags/ui_shell_feature_flag.dart';
import '../theme/app_theme.dart';
import '../widgets/app_account_chip.dart';
import '../../features/settings/presentation/settings_screen.dart';
import '../widgets/app_drawer.dart';
import '../widgets/app_more_menu.dart';
import '../widgets/responsive_scaffold.dart';
import '../widgets/privacy_policy_link.dart';
import 'app_router.dart';
import 'compose_gate.dart';

/// The navigation chrome around the authenticated top-level destinations.
///
/// With the `ui_shell` flag on (decision D3): Home, Notifications (flag),
/// Messages (`messaging`, W7-19) and the own Profile in the bottom bar / rail;
/// Settings and Sign out live in the avatar drawer (phones) and the account
/// chip menu (wide screens), like X. With it off: the legacy chrome, Settings
/// as a fourth destination (and the Messages entry inside it), no drawer, no
/// account chip, and the compose button wherever posting is offered. The flag
/// gates the navigation structure only, not the colours.
/// Wired as a `ShellRoute` builder in
/// [AppRouter] so it persists navigation state across pushes.
class MainShell extends StatelessWidget {
  const MainShell({super.key, required this.location, required this.child});

  final String location;
  final Widget child;

  /// The destinations, in order. Notifications sits second and exists only
  /// with the `notifications` flag on (P6). Messages follows it, with
  /// `messaging` and the new shell (W7-19, F10).
  static List<_Destination> _destinationsFor({
    required bool notifications,
    required bool messages,
    required bool bookmarks,
    required bool settings,
    void Function(BuildContext anchor)? onMore,
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
    if (messages)
      const _Destination(
        _Tab.messages,
        AppNavDestination(
          icon: Icons.mail_outline,
          selectedIcon: Icons.mail,
          label: 'Messages',
        ),
      ),
    // Rail only (>= 600dp): below that the drawer carries the entry.
    if (bookmarks)
      const _Destination(
        _Tab.bookmarks,
        AppNavDestination(
          icon: Icons.bookmark_border,
          selectedIcon: Icons.bookmark,
          label: 'History',
          railOnly: true,
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
    // Rail only: the menu of the shell entries (Creator tools, Premium, ...).
    // It opens a menu at the item and never navigates; below 600dp the
    // drawer carries those entries.
    if (onMore != null)
      _Destination(
        _Tab.more,
        AppNavDestination(
          icon: Icons.more_horiz,
          selectedIcon: Icons.more_horiz,
          label: 'More',
          semanticsLabel: 'More, menu',
          railOnly: true,
          onActivate: onMore,
        ),
      ),
  ];

  /// The selected tab, or null on screens that belong to no tab (Settings in
  /// the new shell, where it is not a destination).
  _Tab? _selectedTab({required bool settingsTab}) {
    if (location.startsWith('/notifications')) return _Tab.notifications;
    // The inbox and its Requests folder (the shell's children). A conversation
    // and the people picker are full-screen routes outside the shell.
    if (location == AppRouter.messagesPath ||
        location == AppRouter.messageRequestsPath) {
      return _Tab.messages;
    }
    if (location == AppRouter.bookmarksPath) return _Tab.bookmarks;
    // The shell pages belong to the rail's More item. (Premium is a dialog on
    // the root navigator: the page under it keeps its own tab.)
    if (location == AppRouter.creatorStudioPath ||
        location == AppRouter.advertisePath ||
        location == AppRouter.callsPath) {
      return _Tab.more;
    }
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
    final ownProfile = context.select(
      (OnboardingBloc bloc) => bloc.state.profile,
    );
    final ownHandle = ownProfile?.handle;

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
    // Messages (W7-19): the new shell with `messaging` on for the caller. The
    // legacy chrome has an entry in Settings instead. The badge cubit is read
    // only when the tab exists.
    final messagesEnabled =
        newShell && isFeatureEnabled(context, kFeatureMessaging);
    final unreadMessages = messagesEnabled
        ? context.select((MessagesBadgeCubit cubit) => cubit.state)
        : 0;
    // Bookmarks entry points (rail here, drawer row): the new shell only,
    // with `bookmarks` on for the caller, and `posts` (the route needs it).
    final bookmarksEntry =
        newShell &&
        isFeatureEnabled(context, kFeatureBookmarks) &&
        isFeatureEnabled(context, kFeaturePosts);
    final shellEntries = shellEntriesFor(context);
    final tabs = _destinationsFor(
      notifications: notificationsEnabled,
      messages: messagesEnabled,
      bookmarks: bookmarksEntry,
      settings: !newShell,
      onMore: shellEntries.isEmpty
          ? null
          : (anchor) => AppMoreMenu.show(anchor, entries: shellEntries),
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
        else if (t.tab == _Tab.messages && unreadMessages > 0)
          AppNavDestination(
            icon: t.destination.icon,
            selectedIcon: t.destination.selectedIcon,
            label: t.destination.label,
            badgeLabel: unreadBadgeLabel(unreadMessages),
            badgeSemanticLabel: unreadMessages == 1
                ? '1 unread conversation'
                : '${unreadBadgeLabel(unreadMessages)} unread conversations',
          )
        else
          t.destination,
    ];

    void openCompose() => context.push(AppRouter.composePath);
    // Settings is master-detail from 1200dp (the list beside the open page),
    // only in the new shell.
    final onSettings = location.startsWith(AppRouter.settingsPath);
    final masterDetail =
        newShell &&
        onSettings &&
        MediaQuery.sizeOf(context).width >= AppBreakpoints.tablet;

    return ResponsiveScaffold(
      masterPane: masterDetail ? _SettingsMaster(selectedPath: location) : null,
      selectedIndex: selectedIndex == null || selectedIndex < 0
          ? null
          : selectedIndex,
      onCompose: canCompose ? openCompose : null,
      showFab: showFab,
      drawer: newShell ? const AppDrawer() : null,
      accountChipBuilder: newShell
          ? (extended) => AppAccountChip(extended: extended)
          : null,
      sideColumn: AppSideColumn(
        // "You might like" (W3-19): the new shell, `graph` and
        // `follow_suggestions` all on. The card draws nothing until the shared
        // list has rows, so the column is unchanged otherwise.
        sections: [
          if (newShell && isFollowSuggestionsEnabled(context))
            const WhoToFollowCard(
              title: 'You might like',
              margin: EdgeInsets.only(bottom: AppSpacing.md),
            ),
        ],
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
          case _Tab.messages:
            context.go(AppRouter.messagesPath);
          case _Tab.bookmarks:
            context.go(AppRouter.bookmarksPath);
          case _Tab.settings:
            context.go(AppRouter.settingsPath);
          case _Tab.more:
            // Opens a menu through `onActivate`; never navigates.
            break;
          case _Tab.profile:
            context.go(
              ownHandle == null || ownHandle.isEmpty
                  ? '/home'
                  : '/profile/$ownHandle',
            );
        }
      },
      body: masterDetail && location == AppRouter.settingsPath
          ? const SettingsDetailPlaceholder()
          : child,
    );
  }
}

/// The master pane of the desktop Settings: a title row over the list.
class _SettingsMaster extends StatelessWidget {
  const _SettingsMaster({required this.selectedPath});

  final String selectedPath;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: AppSize.headerRow,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
          ),
          child: Semantics(
            header: true,
            child: Text(
              'Settings',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
        ),
        Expanded(child: SettingsList(selectedPath: selectedPath)),
      ],
    );
  }
}

enum _Tab { home, notifications, messages, bookmarks, profile, settings, more }

class _Destination {
  const _Destination(this.tab, this.destination);
  final _Tab tab;
  final AppNavDestination destination;
}
