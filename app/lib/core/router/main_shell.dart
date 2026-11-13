import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../features/beacons/domain/beacons_feature_flag.dart';
import '../../features/beacons/domain/plans_list_detail.dart';
import '../../features/beacons/presentation/bloc/plans_session.dart';
import '../../features/beacons/presentation/plans_list_detail.dart';
import '../../features/engagement/domain/bookmarks_feature_flag.dart';
import '../../features/communities/domain/communities_feature_flag.dart';
import '../../features/lists/domain/lists_feature_flag.dart';
import '../../features/graph/presentation/graph_feature_flags.dart';
import '../../features/graph/presentation/widgets/who_to_follow_card.dart';
import '../../features/messages/domain/messages_list_detail.dart';
import '../../features/messages/domain/messaging_feature_flag.dart';
import '../../features/messages/presentation/bloc/conversations_session.dart';
import '../../features/messages/presentation/bloc/messages_badge_cubit.dart';
import '../../features/messages/presentation/messages_list_detail.dart';
import '../../features/messages/presentation/widgets/messages_side_card.dart';
import '../../features/notifications/domain/notifications_feature_flag.dart';
import '../../features/notifications/presentation/bloc/unread_badge_cubit.dart';
import '../../features/notifications/presentation/widgets/follow_requests_card.dart'
    show followRequestsCardAllowed;
import '../../features/notifications/presentation/widgets/follow_requests_side_card.dart';
import '../../features/onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../features/onboarding/presentation/widgets/account_refresh_banner.dart';
import '../../features/posts/domain/posts_feature_flag.dart';
import '../../features/profile/presentation/widgets/profile_media_strip.dart'
    show ProfileMediaStripPlaceholder;
import '../../features/timeline/domain/profile_tabs_feature_flag.dart';
import '../../features/search/domain/search_feature_flags.dart';
import '../../features/search/presentation/widgets/app_search_field.dart';
import '../../features/search/presentation/widgets/whats_happening_card.dart';
import '../../gen/dzeroth/messaging/v1/messaging.pbenum.dart' show Folder;
import 'shell_entries.dart';
import '../../shared/widgets/primitives/app_side_column.dart';
import '../feature_flags/feature_flags.dart';
import '../feature_flags/ui_shell_feature_flag.dart';
import '../theme/app_theme.dart';
import '../widgets/app_account_chip.dart';
import '../../features/settings/domain/settings_categories.dart';
import '../../features/settings/presentation/settings_screen.dart';
import '../widgets/app_drawer.dart';
import '../widgets/app_more_menu.dart';
import '../widgets/context_pane_slots.dart';
import '../widgets/responsive_scaffold.dart';
import '../widgets/privacy_policy_link.dart';
import '../widgets/shell_fab.dart';
import '../widgets/splash_screen.dart';
import '../widgets/shell_geometry.dart';
import 'app_router.dart';
import 'compose_gate.dart';
import 'page_below.dart';

/// The navigation chrome around the authenticated top-level destinations.
///
/// With the `ui_shell` flag on (ADR-0034): Home, Explore, Plans, Notifications
/// and Messages (each behind its flag, except Plans: it is never turned off,
/// and with `beacons` off its page shows the paused state) are the bottom
/// bar and the first rail items; Lists, Communities, History, Profile and More
/// follow on the rail and in the drawer (Profile also from the avatar);
/// Settings and Sign out live in the avatar drawer (phones) and the account
/// chip menu (wide screens), like X. With it off: the legacy chrome, Settings
/// as a fourth destination (and the Messages entry inside it), no drawer, no
/// account chip, and the compose button wherever posting is offered. The flag
/// gates the navigation structure only, not the colours.
/// Wired as a `ShellRoute` builder in
/// [AppRouter] so it persists navigation state across pushes.
class MainShell extends StatelessWidget {
  const MainShell({
    super.key,
    required this.location,
    required this.child,
    this.uri,
    this.splitFolder,
  });

  /// The matched location (a path, no query).
  final String location;
  final Widget child;

  /// Non-null when this shell is the Messages split page (tablet plan section
  /// 5.3): built by `ThreadRoutePage` inside the root thread route at
  /// 840-1199dp, not by the `ShellRoute`. [location] is then the thread's
  /// (`/messages/<id>`, `/messages/new/draft`), [child] the thread, and the
  /// list pane shows this folder with the open conversation selected.
  final Folder? splitFolder;

  /// The whole location, query included (the `ShellRoute` passes
  /// `state.uri`); defaults to [location]. Settings' list pane reads its
  /// category (`?c=`) from it (tablet plan section 4.3).
  final Uri? uri;

  /// The destinations, in display order (primaries first, then secondaries).
  static List<_Destination> _destinationsFor({
    required bool newShell,
    required bool explore,
    required bool notifications,
    required bool messages,
    required bool bookmarks,
    required bool lists,
    required bool communities,
    required bool plans,
    required bool settings,
    void Function(BuildContext anchor)? onMore,
  }) {
    const secondary = AppNavGroup.secondary;
    // Home, Explore, Plans, Notifications, Messages are the primaries
    // (ADR-0034); Lists, Communities, History, Profile, More follow as
    // secondary. The legacy chrome keeps its old list: Home, Notifications,
    // Profile, Settings, all in the bar.
    const home = _Destination(
      _Tab.home,
      AppNavDestination(
        icon: Icons.home_outlined,
        selectedIcon: Icons.home,
        label: 'Home',
      ),
    );
    final exploreTab = explore
        ? const _Destination(
            _Tab.explore,
            AppNavDestination(
              icon: Icons.search,
              selectedIcon: Icons.manage_search,
              label: 'Explore',
            ),
          )
        : null;
    final plansTab = plans
        ? const _Destination(
            _Tab.plans,
            AppNavDestination(
              // The design's target glyph, from the bundled icon font.
              icon: Icons.track_changes,
              selectedIcon: Icons.adjust,
              label: 'Plans',
            ),
          )
        : null;
    final notificationsTab = notifications
        ? const _Destination(
            _Tab.notifications,
            AppNavDestination(
              icon: Icons.notifications_none,
              selectedIcon: Icons.notifications,
              label: 'Notifications',
            ),
          )
        : null;
    final messagesTab = messages
        ? const _Destination(
            _Tab.messages,
            AppNavDestination(
              icon: Icons.mail_outline,
              selectedIcon: Icons.mail,
              label: 'Messages',
            ),
          )
        : null;
    final profileTab = _Destination(
      _Tab.profile,
      AppNavDestination(
        icon: Icons.person_outline,
        selectedIcon: Icons.person,
        label: 'Profile',
        // Off the phone bar in the new shell: the avatar and the drawer
        // header open it (ADR-0034 section 2).
        group: newShell ? secondary : AppNavGroup.primary,
      ),
    );
    final settingsTab = settings
        ? const _Destination(
            _Tab.settings,
            AppNavDestination(
              icon: Icons.settings_outlined,
              selectedIcon: Icons.settings,
              label: 'Settings',
            ),
          )
        : null;
    return [
      home,
      ?exploreTab,
      ?plansTab,
      ?notificationsTab,
      ?messagesTab,
      if (!newShell) ...[profileTab, ?settingsTab],
      if (lists)
        const _Destination(
          _Tab.lists,
          AppNavDestination(
            icon: Icons.list_alt_outlined,
            selectedIcon: Icons.list_alt,
            label: 'Lists',
            group: secondary,
          ),
        ),
      if (communities)
        const _Destination(
          _Tab.communities,
          AppNavDestination(
            icon: Icons.groups_outlined,
            selectedIcon: Icons.groups,
            label: 'Communities',
            group: secondary,
          ),
        ),
      if (bookmarks)
        const _Destination(
          _Tab.bookmarks,
          AppNavDestination(
            icon: Icons.bookmark_border,
            selectedIcon: Icons.bookmark,
            label: 'History',
            group: secondary,
          ),
        ),
      if (newShell) ...[profileTab, ?settingsTab],
      // Rail only: the menu of the shell entries (Creator Studio, Premium, ...).
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
            group: secondary,
            onActivate: onMore,
          ),
        ),
    ];
  }

  /// The selected tab, or null on screens that belong to no tab (Settings in
  /// the new shell, where it is not a destination).
  _Tab? _selectedTab({required bool settingsTab}) {
    if (location.startsWith(AppRouter.explorePath)) return _Tab.explore;
    if (location.startsWith('/notifications')) return _Tab.notifications;
    // The inbox and its Requests folder (the shell's children). A conversation
    // and the people picker are full-screen routes outside the shell; at
    // 840-1199dp the thread routes draw a split page whose shell is given the
    // thread's location (`/messages/<id>`, `/messages/new/draft`).
    if (location == AppRouter.messagesPath ||
        location.startsWith('${AppRouter.messagesPath}/')) {
      return _Tab.messages;
    }
    if (location == AppRouter.bookmarksPath) return _Tab.bookmarks;
    if (location.startsWith(AppRouter.listsPath)) return _Tab.lists;
    if (location.startsWith(AppRouter.communitiesPath)) return _Tab.communities;
    if (location.startsWith(AppRouter.plansPath)) return _Tab.plans;
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
    // Until GetMe has said which features are on, every flag reads off: the
    // Home placeholder and the legacy bar would flash. Hold the splash.
    final pending = context.select(
      (OnboardingBloc bloc) => bloc.state.featuresPending,
    );
    if (pending) return const SplashScreen();
    // The pages under the shell offer their floating button here.
    return ShellFabHost(child: Builder(builder: _build));
  }

  /// The phone's floating button at [location]: Home's New post, else the
  /// action the page offers (Plans, Messages, Lists, Communities, a
  /// community), else none (Profile, Explore, Notifications...).
  ShellFabAction? _fabAt(
    BuildContext context, {
    required bool canCompose,
    required VoidCallback openCompose,
  }) {
    // The page on top decides: a page pushed over another one of the shell
    // (a community over Communities, a profile over Home) has its own button
    // or none, never the one underneath. The pages key their action by their
    // own location, which is the top one's.
    final location = _shellTopLocation(context) ?? this.location;
    if (location == AppRouter.homePath) {
      return canCompose
          ? ShellFabAction(
              tooltip: 'New post',
              icon: Icons.edit_outlined,
              onPressed: openCompose,
            )
          : null;
    }
    final registry = ShellFabScope.watch(context);
    final offered = registry?.actionAt(location);
    if (registry == null || offered == null) return null;
    // Read when pressed: the page may have published a fresh callback.
    return ShellFabAction(
      tooltip: offered.tooltip,
      icon: offered.icon,
      onPressed: () => registry.actionAt(location)?.onPressed(),
    );
  }

  Widget _build(BuildContext context) {
    final ownProfile = context.select(
      (OnboardingBloc bloc) => bloc.state.profile,
    );
    final ownHandle = ownProfile?.handle;

    final refreshFailed = context.select(
      (OnboardingBloc bloc) => bloc.state.refreshFailed,
    );
    final canCompose = canComposeAt(context, location);
    final newShell = isFeatureEnabled(context, kFeatureUiShell);

    final notificationsEnabled = isFeatureEnabled(
      context,
      kFeatureNotifications,
    );
    // The badge cubit is read only when the tab exists.
    final unread = notificationsEnabled
        ? context.select((UnreadBadgeCubit cubit) => cubit.state)
        : 0;
    // Messages: the new shell with `messaging` on for the caller. The
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
    // Explore: the new shell with `search` on, second after Home.
    final exploreEntry = newShell && isFeatureEnabled(context, kFeatureSearch);
    final shellEntries = shellEntriesFor(context);
    // The tablet shell (600-1199dp): `ui_shell` and `ui_tablet` both on.
    // Either off keeps today's 600-1199dp layout; phones and desktop never
    // change with it.
    final width = MediaQuery.sizeOf(context).width;
    final tabletLayout =
        newShell &&
        isFeatureEnabled(context, kFeatureUiTablet) &&
        ShellBand.of(width).isTablet;
    // More's own rows: the shell entries and Articles (`posts`).
    final moreHasOwnRows =
        shellEntries.isNotEmpty || isFeatureEnabled(context, kFeaturePosts);
    final tabs = _destinationsFor(
      newShell: newShell,
      explore: exploreEntry,
      notifications: notificationsEnabled,
      messages: messagesEnabled,
      bookmarks: bookmarksEntry,
      lists: newShell && isFeatureEnabled(context, kFeatureLists),
      communities: newShell && isFeatureEnabled(context, kFeatureCommunities),
      // Never gated on `beacons` (ADR-0034 section 4); the legacy chrome has
      // no Plans tab.
      plans: newShell,
      settings: !newShell,
      // The tablet rail keeps More whenever it has rows, folded secondary
      // destinations included (a short window); `AppNavRail` hides it when
      // it has none.
      onMore: moreHasOwnRows || tabletLayout
          ? (anchor) => AppMoreMenu.show(anchor, entries: shellEntries)
          : null,
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
            badgeCount: unreadMessages,
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
    // only in the new shell. On the tablet layout it is list-detail from
    // 840dp (band B): the categories beside the category or leaf page, which
    // the route draws itself (`SettingsScreen`), so the shell navigator is
    // never swapped out. The scaffold and `SettingsScreen` take the same
    // 840 / 1200 decisions from the same flags and width.
    final onSettings = isSettingsLocation(location);
    final masterDetail =
        newShell && onSettings && width >= AppBreakpoints.tablet;
    final settingsListDetail =
        tabletLayout && onSettings && ShellBand.of(width) == ShellBand.expanded;
    // Plans is list-detail in band B too (T5), on `/plans` and `/plans/:id`
    // only, with `beacons` on and the app's hoisted list (`PlansSession`).
    // The decision is published to the page ([PlansMasterScope]), which then
    // draws the placeholder (`/plans`) or drops its back arrow (the plan).
    final beaconsOn = isFeatureEnabled(context, kFeatureBeacons);
    final plansBandB =
        tabletLayout && ShellBand.of(width) == ShellBand.expanded;
    // The top page of the shell's own navigator decides, not the shell's
    // base route: My plans, New plan, a plan's People or Edit (or a profile)
    // pushed over `/plans` or `/plans/:id` have no list pane beside them
    // (plan section 3), and popping back to the plan brings it back. A root
    // page over the shell (a dialog page, the composer) changes nothing.
    // The split page is a root route: the shell navigator under it belongs
    // to another page, so neither its top page nor Plans decide anything here.
    final split = splitFolder != null;
    final plansMatch = split
        ? null
        : plansMasterMatch(
            plansBandB ? _shellTopLocation(context) ?? location : location,
          );
    final plansListDetail =
        plansBandB &&
        beaconsOn &&
        plansMatch != null &&
        context.read<PlansSession?>() != null;
    // Messages is list-detail in band B too (T6), with the app's hoisted
    // folders (`ConversationsSession`): on the shell's `/messages` and
    // `/messages/requests` (read from the shell navigator's top page, as
    // Plans) beside the route's placeholder, and in the split page beside the
    // thread.
    final messagesBandB =
        plansBandB && context.read<ConversationsSession?>() != null;
    final messagesMaster = !messagesBandB
        ? null
        : split
        ? splitFolder
        : messagesShellMasterFolder(_shellTopLocation(context) ?? location);

    // The desktop side column's route: the shell navigator's top page (a
    // profile pushed over Home decides), else the matched location.
    final sidePaneLocation = _shellTopLocation(context) ?? location;

    void select(int index) {
      switch (tabs[index].tab) {
        case _Tab.home:
          context.go('/home');
        case _Tab.explore:
          context.go(AppRouter.explorePath);
        case _Tab.notifications:
          context.go(AppRouter.notificationsPath);
        case _Tab.messages:
          context.go(AppRouter.messagesPath);
        case _Tab.lists:
          context.go(AppRouter.listsPath);
        case _Tab.communities:
          context.go(AppRouter.communitiesPath);
        case _Tab.plans:
          context.go(AppRouter.plansPath);
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
    }

    // The slots through which a page lends the context pane sections built
    // over its own state (T8a). Present at every width and in every mode, so
    // the tree around the shell navigator keeps its shape.
    return ContextPaneSlotsHost(
      child: ResponsiveScaffold(
        // The redesigned rail look (600dp and up) with the new shell only.
        redesignedRail: newShell,
        // Both flags at any width: from 1200dp the desktop composition is
        // unchanged, but modals and snack bars centre on its column (D1).
        layout: newShell && isFeatureEnabled(context, kFeatureUiTablet)
            ? ShellLayout.tablet
            : ShellLayout.legacy,
        moreHasOwnRows: moreHasOwnRows,
        // A short tablet rail folds Lists, Communities, History and Profile
        // into More: they head its menu and open as from the rail.
        onMoreFolded: (anchor, folded) => AppMoreMenu.show(
          anchor,
          entries: shellEntries,
          folded: [
            for (final i in folded)
              AppMoreMenuFoldedRow(
                icon: tabs[i].destination.icon,
                label: tabs[i].destination.label,
                selected: tabs[i].tab == selected,
                onSelected: () => select(i),
              ),
          ],
        ),
        masterPane: masterDetail
            // The desktop mock: the categories beside the open one (Your
            // account when none is chosen) or its leaf page.
            ? SettingsCategoriesPane(
                selected:
                    settingsCategoryForUri(uri ?? Uri.parse(location)) ??
                    (location == AppRouter.settingsPath
                        ? SettingsCategory.account
                        : null),
              )
            : settingsListDetail
            ? SettingsCategoriesPane(
                selected: settingsCategoryForUri(uri ?? Uri.parse(location)),
              )
            : plansListDetail
            ? PlansListPane(selectedId: plansMatch.selectedId)
            : messagesMaster != null
            ? ConversationsListPane(
                // The folder decides the list; a new folder is a new list.
                key: ValueKey(messagesMaster),
                folder: messagesMaster,
                selectedId: split ? messagesThreadIdOf(location) : null,
                split: split,
              )
            : null,
        selectedIndex: selectedIndex == null || selectedIndex < 0
            ? null
            : selectedIndex,
        onCompose: canCompose ? openCompose : null,
        fab: _fabAt(context, canCompose: canCompose, openCompose: openCompose),
        // A community's page draws its cover, and a profile its hero, under the
        // status bar on a phone
        // (while the account banner is up, the banner needs the inset).
        extendBodyUnderStatusBar:
            (isCommunityPageAt(location) ||
                isProfilePageAt(_shellTopLocation(context) ?? location)) &&
            !refreshFailed,
        drawer: newShell ? const AppDrawer() : null,
        floatingBar: newShell,
        accountChipBuilder: newShell
            ? (extended) => AppAccountChip(extended: extended)
            : null,
        sideColumn: AppSideColumn(
          // The search pill: the new shell with `search` on, except on
          // Explore and the search results, where the pill is in the centre
          // header (desktop SearchResults has none in the side column).
          header:
              exploreEntry &&
                  !location.startsWith(AppRouter.explorePath) &&
                  location != AppRouter.searchRoute
              ? const AppSearchField()
              : null,
          // "You might like": the new shell, `graph` and
          // `follow_suggestions` all on. The card draws nothing until the shared
          // list has rows, so the column is unchanged otherwise.
          sections: [
            // F16 (R8): on Notifications, the follow-requests card (its own
            // `ListFollowRequests(3)`), above the trends. The page's inline
            // row steps aside under the same rule (`followRequestsCardBeside`).
            // A page pushed over Notifications (a profile) hides the card but
            // keeps it mounted, so coming back asks nothing again.
            if (location == AppRouter.notificationsPath &&
                followRequestsCardAllowed(context))
              Visibility(
                visible:
                    (_shellTopLocation(context) ?? location) ==
                    AppRouter.notificationsPath,
                maintainState: true,
                child: const FollowRequestsSideCard(),
              ),
            // The inbox beside nothing: "Select a conversation" (desktop
            // Conversations; the tablet draws its detail placeholder).
            if (messagesShellMasterFolder(
                  _shellTopLocation(context) ?? location,
                ) !=
                null)
              const MessagesSideCard(),
            // "What's happening": the top 5 trends; draws nothing unless
            // `search` + `trends` are on and the shared list has rows.
            if (exploreEntry) const WhatsHappeningCard(),
            // The profile's latest images (the desktop Profile mock's Media
            // grid): the page lends the strip over its own Media tab feed,
            // through a slot. Only on a profile, with `posts` and
            // `profile_tabs` on.
            if (newShell &&
                isFeatureEnabled(context, kFeaturePosts) &&
                isFeatureEnabled(context, kFeatureProfileTabs) &&
                _isProfileHomeLocation(sidePaneLocation))
              ContextPaneSlot(
                location: sidePaneLocation,
                placeholder: const ProfileMediaStripPlaceholder(),
              ),
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
        onDestinationSelected: select,
        // A failed GetMe behind a cached profile: a non-blocking Retry over
        // every destination, never a hard stop (offline warm start).
        // The tablet pane keeps the top inset (no outer SafeArea): while the
        // banner shows it sits below the inset and the page under it does not
        // pad by the inset again. Elsewhere the inset is already taken (0).
        body: Builder(
          builder: (pane) {
            final inset = refreshFailed ? MediaQuery.paddingOf(pane).top : 0.0;
            return Column(
              children: [
                Padding(
                  padding: EdgeInsets.only(top: inset),
                  child: const AccountRefreshBanner(),
                ),
                Expanded(
                  child: MediaQuery.removePadding(
                    context: pane,
                    removeTop: inset > 0,
                    // Present at every width and in every mode, so the tree
                    // around the shell navigator keeps its shape at 840.
                    child: PlansMasterScope(
                      shown: plansListDetail,
                      selectedId: plansListDetail
                          ? plansMatch.selectedId
                          : null,
                      child: ConversationsMasterScope(
                        shown: messagesMaster != null && !split,
                        child:
                            masterDetail && location == AppRouter.settingsPath
                            ? SettingsDesktopDetail(
                                categoryId: (uri ?? Uri.parse(location))
                                    .queryParameters[kSettingsCategoryParam],
                              )
                            : child,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The location of the top page inside the shell's navigator (a page pushed
/// over a shell page included; a root page pushed over the shell excluded),
/// or null without a router or a shell match.
String? _shellTopLocation(BuildContext context) {
  final router = GoRouter.maybeOf(context);
  if (router == null) return null;
  for (final match
      in router.routerDelegate.currentConfiguration.matches.reversed) {
    if (match is! ShellRouteMatch) continue;
    var leaf = match.matches.last;
    while (leaf is ShellRouteMatch) {
      leaf = leaf.matches.last;
    }
    return leaf.matchedLocation;
  }
  return null;
}

/// Whether [location] is a profile page itself (`/profile/:handle` or
/// `/u/:id`, not its Followers / Following): where the desktop side column
/// shows the profile's media strip.
bool _isProfileHomeLocation(String location) {
  final segments = [
    for (final s in Uri.parse(location).pathSegments)
      if (s.isNotEmpty) s,
  ];
  return switch (segments) {
    ['profile', _] || ['u', _] => true,
    _ => false,
  };
}

enum _Tab {
  home,
  explore,
  notifications,
  messages,
  bookmarks,
  lists,
  communities,
  plans,
  profile,
  settings,
  more,
}

class _Destination {
  const _Destination(this.tab, this.destination);
  final _Tab tab;
  final AppNavDestination destination;
}
