import 'package:go_router/go_router.dart';

import '../../../features/location/presentation/location_rationale_screen.dart';
import '../../../features/location/presentation/location_settings_screen.dart';
import '../../../features/search/presentation/explore_settings_screen.dart';

import '../../../features/account/presentation/data_export_screen.dart';
import '../../../features/account/presentation/delete_account_screen.dart';
import '../../../features/auth/presentation/widgets/auth_gate.dart';
import '../../../features/engagement/presentation/bookmarks_screen.dart';
import '../../../features/communities/presentation/communities_screen.dart';
import '../../../features/communities/presentation/community_members_screen.dart';
import '../../../features/communities/presentation/community_moderation_log_screen.dart';
import '../../../features/communities/presentation/community_screen.dart';
import '../../../features/communities/presentation/create_community_screen.dart';
import '../../../features/beacons/presentation/beacon_people_screen.dart';
import '../../../features/beacons/presentation/beacon_screen.dart';
import '../../../features/beacons/presentation/beacons_screen.dart';
import '../../../features/beacons/presentation/create_beacon_screen.dart';
import '../../../features/beacons/presentation/edit_beacon_screen.dart';
import '../../../features/beacons/presentation/my_beacons_screen.dart';
import '../../../features/lists/presentation/discover_lists_screen.dart';
import '../../../features/lists/presentation/list_detail_screen.dart';
import '../../../features/lists/presentation/list_members_screen.dart';
import '../../../features/lists/presentation/manage_pinned_screen.dart';
import '../../../features/lists/presentation/lists_screen.dart';
import '../../../features/lists/presentation/user_lists_screen.dart';
import '../../../features/graph/domain/graph_list_extra.dart';
import '../../../features/graph/presentation/follow_requests_screen.dart';
import '../../../features/graph/presentation/graph_list_screen.dart';
import '../../../features/graph/presentation/managed_accounts_screen.dart';
import '../../../features/home/presentation/home_screen.dart';
import '../../../features/messages/presentation/conversations_screen.dart';
import '../../../features/search/domain/search_results_tab.dart';
import '../../../features/search/presentation/search_results_screen.dart';
import '../../../features/notifications/presentation/notification_settings_screen.dart';
import '../../../features/notifications/presentation/notifications_screen.dart';
import '../../../features/search/presentation/bloc/explore_media_cubit.dart';
import '../../../features/search/presentation/explore_media_screen.dart';
import '../../../features/search/domain/explore_tab.dart';
import '../../../features/search/domain/search_routes.dart';
import '../../../features/search/presentation/explore_screen.dart';
import '../../../features/search/presentation/explore_trending_screen.dart';
import '../../../gen/dzeroth/messaging/v1/messaging.pbenum.dart' show Folder;
import '../../../features/onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../../features/posts/presentation/post_detail_screen.dart';
import '../shell_entries.dart';
import '../../../features/advertise/presentation/advertise_screen.dart';
import '../../../features/calls/presentation/calls_screen.dart';
import '../../../features/creator_studio/presentation/creator_studio_screen.dart';
import '../../../features/profile/presentation/change_handle_screen.dart';
import '../../../features/profile/presentation/edit_profile_screen.dart';
import '../../../features/profile/presentation/profile_screen.dart';
import '../../../features/settings/domain/settings_categories.dart';
import '../../../features/settings/presentation/data_usage_screen.dart';
import '../../../features/settings/presentation/message_settings_screen.dart';
import '../../../features/settings/presentation/settings_screen.dart';
import '../main_shell.dart';
import '../app_router.dart';
import '../../session/user_ids.dart';

/// The ShellRoute with every route that renders inside the navigation chrome.
RouteBase shellRoute({required OnboardingBloc onboardingBloc}) => ShellRoute(
  builder: (context, state, child) => MainShell(
    location: state.matchedLocation,
    // The query too: Settings' list pane reads its `?c=`.
    uri: state.uri,
    child: child,
  ),
  routes: [
    GoRoute(
      path: AppRouter.homePath,
      builder: (context, state) => const AuthGate(child: HomeScreen()),
    ),
    GoRoute(
      path: AppRouter.followRequestsPath,
      builder: (context, state) =>
          const AuthGate(child: FollowRequestsScreen()),
    ),
    GoRoute(
      path: AppRouter.explorePath,
      builder: (context, state) => AuthGate(
        child: ExploreScreen(
          // `?tab=nearby` (the side column's "Happening nearby" card).
          initialTab: state.uri.queryParameters['tab'] == 'nearby'
              ? ExploreTab.nearby
              : null,
          // `?tag=go`: Trending filtered to a hashtag. An in-app navigation
          // to the same link carries a new `extra`, so it applies again.
          initialTag: exploreTagOfLink(state.uri.queryParameters['tag']),
          linkKey: state.extra,
        ),
      ),
    ),
    GoRoute(
      path: AppRouter.exploreSettingsPath,
      builder: (context, state) =>
          const AuthGate(child: ExploreSettingsScreen()),
    ),
    GoRoute(
      path: AppRouter.exploreTrendingPath,
      builder: (context, state) =>
          const AuthGate(child: ExploreTrendingScreen()),
    ),
    GoRoute(
      path: AppRouter.exploreMediaPath,
      builder: (context, state) => AuthGate(
        // Explore hands over its cubit, so the grid starts with the
        // photos it already has; a link or reload makes its own.
        child: ExploreMediaScreen(
          cubit: state.extra is ExploreMediaCubit
              ? state.extra as ExploreMediaCubit
              : null,
        ),
      ),
    ),
    GoRoute(
      path: AppRouter.notificationsPath,
      builder: (context, state) => const AuthGate(child: NotificationsScreen()),
    ),
    GoRoute(
      path: AppRouter.messagesPath,
      builder: (context, state) => AuthGate(
        child: ConversationsScreen(
          onOpenConversation: (id) => context.push(AppRouter.messagePath(id)),
          onNewMessage: () => context.push(AppRouter.messageNewPath),
        ),
      ),
    ),
    GoRoute(
      path: AppRouter.messageRequestsPath,
      builder: (context, state) => AuthGate(
        child: ConversationsScreen(
          folder: Folder.FOLDER_REQUESTS,
          // The thread's split page (840-1199dp) keeps the Requests
          // list beside it; the extra changes nothing elsewhere.
          onOpenConversation: (id) => context.push(
            AppRouter.messagePath(id),
            extra: Folder.FOLDER_REQUESTS,
          ),
          // The band B placeholder's action.
          onNewMessage: () => context.push(AppRouter.messageNewPath),
        ),
      ),
    ),
    GoRoute(
      path: AppRouter.searchRoute,
      builder: (context, state) {
        final query = state.uri.queryParameters['q'] ?? '';
        return AuthGate(
          child: SearchResultsScreen(
            query: query,
            initialTab: SearchResultsTab.fromQuery(
              state.uri.queryParameters['tab'],
              query: query,
            ),
          ),
        );
      },
    ),
    GoRoute(
      path: AppRouter.bookmarksPath,
      builder: (context, state) => AuthGate(
        // `?tab=likes` opens the Likes tab; the screen ignores
        // it while the `likes_list` flag is off.
        child: BookmarksScreen(
          initialTab: HistoryTab.fromQuery(state.uri.queryParameters['tab']),
        ),
      ),
    ),
    GoRoute(
      path: AppRouter.pinnedPath,
      builder: (context, state) => const AuthGate(child: ManagePinnedScreen()),
    ),
    GoRoute(
      path: AppRouter.listsPath,
      builder: (context, state) => const AuthGate(child: ListsScreen()),
    ),
    GoRoute(
      path: AppRouter.discoverListsPath,
      builder: (context, state) => const AuthGate(child: DiscoverListsScreen()),
    ),
    GoRoute(
      path: '/lists/:id',
      builder: (context, state) => AuthGate(
        child: ListDetailScreen(listId: state.pathParameters['id']!),
      ),
    ),
    GoRoute(
      path: AppRouter.communitiesPath,
      builder: (context, state) => const AuthGate(child: CommunitiesScreen()),
    ),
    GoRoute(
      path: AppRouter.communityNewPath,
      builder: (context, state) =>
          const AuthGate(child: CreateCommunityScreen()),
    ),
    GoRoute(
      path: '/communities/:id',
      builder: (context, state) => AuthGate(
        child: CommunityScreen(communityId: state.pathParameters['id']!),
      ),
    ),
    GoRoute(
      path: '/communities/:id/members',
      builder: (context, state) => AuthGate(
        child: CommunityMembersScreen(communityId: state.pathParameters['id']!),
      ),
    ),
    GoRoute(
      path: '/communities/:id/moderation-log',
      builder: (context, state) => AuthGate(
        child: CommunityModerationLogScreen(
          communityId: state.pathParameters['id']!,
        ),
      ),
    ),
    // Plans (beacons): `/plans/new` before `/plans/:id`.
    GoRoute(
      path: AppRouter.plansPath,
      builder: (context, state) => const AuthGate(child: BeaconsScreen()),
    ),
    GoRoute(
      path: AppRouter.planNewPath,
      builder: (context, state) => const AuthGate(child: CreateBeaconScreen()),
    ),
    GoRoute(
      path: AppRouter.plansMinePath,
      builder: (context, state) => const AuthGate(child: MyBeaconsScreen()),
    ),
    GoRoute(
      path: '/plans/:id',
      builder: (context, state) =>
          AuthGate(child: BeaconScreen(beaconId: state.pathParameters['id']!)),
    ),
    GoRoute(
      path: '/plans/:id/people',
      builder: (context, state) => AuthGate(
        child: BeaconPeopleScreen(beaconId: state.pathParameters['id']!),
      ),
    ),
    GoRoute(
      path: '/plans/:id/edit',
      builder: (context, state) => AuthGate(
        child: EditBeaconScreen(beaconId: state.pathParameters['id']!),
      ),
    ),
    GoRoute(
      path: '/lists/:id/members',
      builder: (context, state) => AuthGate(
        child: ListMembersScreen(listId: state.pathParameters['id']!),
      ),
    ),
    if (kVisibleShells.contains(ShellKind.creatorStudio))
      GoRoute(
        path: AppRouter.creatorStudioPath,
        builder: (context, state) =>
            const AuthGate(child: CreatorStudioScreen()),
      ),
    if (kVisibleShells.contains(ShellKind.advertise))
      GoRoute(
        path: AppRouter.advertisePath,
        builder: (context, state) => const AuthGate(child: AdvertiseScreen()),
      ),
    if (kVisibleShells.contains(ShellKind.calls))
      GoRoute(
        path: AppRouter.callsPath,
        builder: (context, state) => const AuthGate(child: CallsScreen()),
      ),
    GoRoute(
      path: '/u/:userId',
      builder: (context, state) => AuthGate(
        child: ProfileScreen(userId: state.pathParameters['userId']!),
      ),
    ),
    GoRoute(
      path: '/u/:userId/lists',
      builder: (context, state) => AuthGate(
        child: UserListsScreen(
          userId: state.pathParameters['userId']!,
          handle: state.extra as String?,
        ),
      ),
    ),
    GoRoute(
      path: '/post/:id',
      builder: (context, state) => AuthGate(
        child: PostDetailScreen(postId: state.pathParameters['id']!),
      ),
    ),
    GoRoute(
      path: '/profile/:handle',
      builder: (context, state) => AuthGate(
        child: ProfileScreen(handle: state.pathParameters['handle']!),
      ),
    ),
    GoRoute(
      path: '/profile/:handle/followers',
      builder: (context, state) {
        final extra = state.extra;
        final known = extra is GraphListExtra ? extra : null;
        return AuthGate(
          child: GraphListScreen(
            handle: state.pathParameters['handle']!,
            userId: known?.userId,
            displayName: known?.displayName,
            initialTab: GraphListTab.followers,
            viewerUserId: onboardingBloc.state.myUserId,
          ),
        );
      },
    ),
    GoRoute(
      path: '/profile/:handle/following',
      builder: (context, state) {
        final extra = state.extra;
        final known = extra is GraphListExtra ? extra : null;
        return AuthGate(
          child: GraphListScreen(
            handle: state.pathParameters['handle']!,
            userId: known?.userId,
            displayName: known?.displayName,
            initialTab: GraphListTab.following,
            viewerUserId: onboardingBloc.state.myUserId,
          ),
        );
      },
    ),
    GoRoute(
      path: AppRouter.settingsPath,
      // `?c=<category>` opens a category on the tablet layout (tablet
      // plan section 4.3); every other layout ignores it.
      builder: (context, state) => AuthGate(
        child: SettingsScreen(
          categoryId: state.uri.queryParameters[kSettingsCategoryParam],
        ),
      ),
    ),
    GoRoute(
      path: AppRouter.blockedAccountsPath,
      builder: (context, state) =>
          const AuthGate(child: BlockedAccountsScreen()),
    ),
    GoRoute(
      path: AppRouter.exportDataPath,
      builder: (context, state) => const AuthGate(child: DataExportScreen()),
    ),
    GoRoute(
      path: AppRouter.mutedAccountsPath,
      builder: (context, state) => const AuthGate(child: MutedAccountsScreen()),
    ),
    GoRoute(
      path: AppRouter.editProfilePath,
      builder: (context, state) => const AuthGate(child: EditProfileScreen()),
    ),
    GoRoute(
      path: AppRouter.changeHandlePath,
      builder: (context, state) => const AuthGate(child: ChangeHandleScreen()),
    ),
    GoRoute(
      path: AppRouter.deleteAccountPath,
      builder: (context, state) => const AuthGate(child: DeleteAccountScreen()),
    ),
    GoRoute(
      path: AppRouter.notificationSettingsPath,
      builder: (context, state) =>
          const AuthGate(child: NotificationSettingsScreen()),
    ),
    GoRoute(
      path: AppRouter.messageSettingsPath,
      builder: (context, state) =>
          const AuthGate(child: MessageSettingsScreen()),
    ),
    GoRoute(
      path: AppRouter.dataUsagePath,
      builder: (context, state) => const AuthGate(child: DataUsageScreen()),
    ),
    GoRoute(
      path: AppRouter.locationSettingsPath,
      builder: (context, state) =>
          const AuthGate(child: LocationSettingsScreen()),
    ),
    GoRoute(
      path: AppRouter.locationConsentPath,
      builder: (context, state) =>
          const AuthGate(child: LocationRationaleScreen()),
    ),
  ],
);
