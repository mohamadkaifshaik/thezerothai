import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../features/beacons/domain/beacons_feature_flag.dart';
import '../../features/beacons/presentation/widgets/plan_preview.dart'
    show PlanPreviewCard;
import '../../features/beacons/presentation/widgets/plan_tips.dart'
    show PlanTipsCard;
import '../../features/communities/domain/communities_feature_flag.dart';
import '../../features/communities/presentation/widgets/community_about.dart'
    show CommunityAboutPanePlaceholder;
import '../../features/communities/presentation/widgets/community_preview.dart'
    show CommunityPreviewCard;
import '../../features/communities/presentation/widgets/community_search_field.dart'
    show CommunitySearchField, kSearchMembersHint, kSearchMembersLabel;
import '../../features/communities/presentation/widgets/explore_communities_pane.dart'
    show ExploreCommunitiesPanePlaceholder;
import '../../features/communities/presentation/widgets/moderation_log_about.dart'
    show ModerationLogAboutPlaceholder;
import '../../features/graph/presentation/graph_feature_flags.dart';
import '../../features/graph/presentation/widgets/who_to_follow_card.dart';
import '../../features/lists/domain/lists_feature_flag.dart';
import '../../features/lists/presentation/widgets/home_tabs_preview.dart'
    show HomeTabsPreviewPlaceholder;
import '../../features/lists/presentation/widgets/list_members_pane.dart'
    show ListMembersPanePlaceholder;
import '../../features/lists/presentation/widgets/lists_owner_card.dart'
    show ListsOwnerCardPlaceholder;
import '../../features/notifications/presentation/widgets/follow_requests_card.dart'
    show FollowRequestsCardSlot, followRequestsCardAllowed;
import '../../features/onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../features/posts/domain/posts_feature_flag.dart';
import '../../features/profile/presentation/widgets/profile_media_strip.dart'
    show ProfileMediaStripPlaceholder;
import '../../features/timeline/domain/profile_tabs_feature_flag.dart';
import '../../features/search/domain/search_feature_flags.dart';
import '../../features/search/presentation/widgets/app_search_field.dart';
import '../../features/search/presentation/widgets/whats_happening_card.dart';
import '../../shared/widgets/primitives/app_side_column.dart';
import '../feature_flags/feature_flags.dart';
import '../theme/app_theme.dart';
import '../widgets/context_pane.dart';
import '../widgets/context_pane_slots.dart';
import '../widgets/privacy_policy_link.dart';
import 'app_router.dart';

/// The route families of band B's context pane (tablet plan section 4.1).
/// Each shell location maps to one; [contextSectionsFor] turns it into
/// sections. Later phases add families or sections here: T5 the Plans
/// list-detail, T8 the per-feature panes (community rules, list members,
/// previews).
enum ContextFamily {
  /// No context pane: the primary pane keeps the whole content width. The
  /// list-detail families (Settings T4, Plans T5, Messages T6; plan section
  /// 3, "the context pane is not shown with LD") and the pages section 4.1
  /// draws as F in band B (PlanPeople, Creator Studio, Advertise, Calls).
  none,

  /// The global set (the default): the search pill, the profile card,
  /// What's happening and Who to follow, then the footer.
  global,

  /// Explore: Who to follow (the trends and the search field are the page
  /// itself).
  explore,

  /// Notifications: the follow-requests card (F16, lent by the page), then
  /// What's happening.
  notifications,

  /// Search results: What's happening (the filters wait for F22).
  search,

  /// Follow requests, Followers and Following: Who to follow.
  people,

  /// A profile: its media strip, lent by the page (T8c), and You might
  /// like.
  profile,

  /// `/communities` (T8a): "Search communities" over "Explore
  /// communities", lent by the page (its filter, directory and Join; F37,
  /// R10).
  communities,

  /// `/communities/new` (T8a): the live preview of the form, lent by the
  /// page.
  communityCreate,

  /// `/communities/:id` (T8a): the community's rules, moderators and "View
  /// moderation log", lent by the page (its one `GetCommunity`).
  community,

  /// `/communities/:id/moderation-log` (T8a): "About this log", lent by the
  /// page once its log lists entries (the caller moderates).
  moderationLog,

  /// `/communities/:id/members` (R10): "Search members", lent by the page,
  /// with `community_member_search` on (F36); the global set without it.
  communityMembers,

  /// `/lists/:id` (T8b): a preview of the List's members, lent by the page.
  listDetail,

  /// `/home/pinned` (T8b): the preview of the Home tabs, lent by the page.
  managePinned,

  /// `/u/:id/lists` (T8b): the owner card, lent by the page (from the Lists
  /// it loaded).
  userLists,

  /// `/plans/new` (T8d): the live preview of the form and "Tips for a good
  /// plan", lent by the page.
  planCreate,

  /// `/plans/:id/edit` (T8d): the live preview of the edit and the tips,
  /// lent by the page once its plan is loaded.
  planEdit,
}

/// Whether [location] is one of the Lists pages (T8b): `/lists` and
/// everything under it, `/u/:id/lists` and `/home/pinned`.
bool _isListsLocation(String location) {
  final segments = [
    for (final s in Uri.parse(location).pathSegments)
      if (s.isNotEmpty) s,
  ];
  return switch (segments) {
    ['lists', ...] || ['u', _, 'lists'] || ['home', 'pinned'] => true,
    _ => false,
  };
}

/// Whether [location] is the plan create or edit form (`/plans/new`,
/// `/plans/:id/edit`; T8d).
bool _isPlanFormLocation(String location) => switch ([
  for (final s in Uri.parse(location).pathSegments)
    if (s.isNotEmpty) s,
]) {
  ['plans', 'new'] || ['plans', _, 'edit'] => true,
  _ => false,
};

/// Whether [location] is one of the communities pages (`/communities` and
/// everything under it).
bool _isCommunitiesLocation(String location) {
  final segments = Uri.parse(location).pathSegments;
  return segments.isNotEmpty && segments.first == 'communities';
}

/// Whether [location] is a Settings page (`/settings` and everything under
/// it).
bool _isSettingsLocation(String location) {
  final segments = Uri.parse(location).pathSegments;
  return segments.isNotEmpty && segments.first == 'settings';
}

/// Whether [location] is one of the profile pages (`/profile/...` and
/// `/u/...`: a profile, its Followers / Following, a person's Lists).
bool _isProfileLocation(String location) {
  final segments = Uri.parse(location).pathSegments;
  return segments.isNotEmpty &&
      (segments.first == 'profile' || segments.first == 'u');
}

/// The location whose family the context pane shows, from the shell's
/// [base] route and the [top] page of the shell navigator (null when it is
/// not known).
///
/// The communities pages are pushed (directory rows, Members, the log,
/// Create, a post's community label from any feed), so when either side is
/// a communities page the top page decides, as Plans' list pane does (T5):
/// a community pushed over Home gets its own pane, and a page pushed over a
/// community gets its own family, never the community's lent sections.
/// The Lists pages are pushed too (T8b: a List from Lists, Manage pinned or
/// a person's Lists; Members from a List; Manage pinned from Home's "+"; a
/// person's Lists from their profile), so they follow the same rule.
/// The plan forms are pushed too (over the Plans list, a plan, My plans), so
/// when the top page is one of them it decides (T8d).
/// Everything else keeps T3's rule: the base route decides.
String contextPaneLocationFor(String base, String? top) {
  if (top == null) return base;
  // A Settings page pushed over another page (Edit profile from a profile
  // that was itself pushed over Home; T8c) has no pane of its own, never the
  // page underneath's.
  if (_isSettingsLocation(top)) return top;
  // The profile pages are pushed too (post cards, Who to follow, search,
  // notifications, a chat), and Followers, Following and Edit profile are
  // pushed from a profile (T8c): a profile pushed over Home gets its own
  // pane, and a page pushed over a profile gets its own family. A person's
  // Lists (`/u/:id/lists`) is both a profile and a Lists page: the top page
  // decides by either rule.
  if (_isProfileLocation(top) || _isProfileLocation(base)) return top;
  return _isCommunitiesLocation(top) ||
          _isCommunitiesLocation(base) ||
          _isListsLocation(top) ||
          _isListsLocation(base) ||
          _isPlanFormLocation(top)
      ? top
      : base;
}

/// The family of the matched shell [location] (a path; a query is ignored).
/// A pure function of the route, never of data: whether the pane exists must
/// not wait for a section to load, or the primary width would jump.
ContextFamily contextFamilyFor(String location) {
  final segments = [
    for (final s in Uri.parse(location).pathSegments)
      if (s.isNotEmpty) s,
  ];
  return switch (segments) {
    ['settings', ...] => ContextFamily.none,
    ['messages', ...] => ContextFamily.none,
    ['creator-studio'] || ['advertise'] || ['calls'] => ContextFamily.none,
    // `/plans/new` and `/plans/mine` are matched before `/plans/:id`.
    ['plans', 'new'] => ContextFamily.planCreate,
    ['plans', 'mine'] => ContextFamily.global,
    ['plans', _, 'edit'] => ContextFamily.planEdit,
    ['plans'] || ['plans', _] || ['plans', _, 'people'] => ContextFamily.none,
    ['explore'] => ContextFamily.explore,
    ['notifications'] => ContextFamily.notifications,
    ['search'] => ContextFamily.search,
    ['follow-requests'] => ContextFamily.people,
    ['profile', _, 'followers' || 'following'] => ContextFamily.people,
    ['profile', _] || ['u', _] => ContextFamily.profile,
    // `/communities/new` is matched before `/communities/:id`.
    ['communities'] => ContextFamily.communities,
    ['communities', 'new'] => ContextFamily.communityCreate,
    ['communities', _, 'moderation-log'] => ContextFamily.moderationLog,
    // CommunityMembers: "Search members" (F36), or the global set with its
    // flag off (see [contextSectionsFor]).
    ['communities', _, 'members'] => ContextFamily.communityMembers,
    ['communities', _] => ContextFamily.community,
    // Lists (T8b). `/lists` and `/lists/:id/members` keep the global set
    // (F10 keeps "Discover new Lists" out; F31's suggestions wait).
    ['lists', _] => ContextFamily.listDetail,
    ['home', 'pinned'] => ContextFamily.managePinned,
    ['u', _, 'lists'] => ContextFamily.userLists,
    _ => ContextFamily.global,
  };
}

/// The context-pane sections of the shell page at [location], top to
/// bottom; empty when the page has no pane ([ContextFamily.none]). Used by
/// `MainShell` on the tablet layout only (`ResponsiveScaffold` shows them
/// from 840dp); desktop keeps its own side column (ruling R-1).
///
/// Each section is gated on `enabled_features` exactly like its desktop and
/// phone counterparts, and is only listed when its flags are on, so
/// [ContextPaneScope] tells the truth to pages with an inline copy. Every
/// section reads the shared app-level state it already reads elsewhere
/// (`TrendsCubit`, `SuggestionsCubit`, the loaded profile): no new call.
/// Every pane ends with the footer links.
List<ContextSection> contextSectionsFor(String location, BuildContext context) {
  var family = contextFamilyFor(location);
  if (family == ContextFamily.none) return const [];
  // The communities pages need `communities` (the router sends them Home
  // without it); should one show anyway, it gets the global set.
  final communitiesFamily = switch (family) {
    ContextFamily.communities ||
    ContextFamily.communityCreate ||
    ContextFamily.community ||
    ContextFamily.moderationLog ||
    ContextFamily.communityMembers => true,
    _ => false,
  };
  if (communitiesFamily && !isFeatureEnabled(context, kFeatureCommunities)) {
    family = ContextFamily.global;
  }
  // The members page's search needs its own flag too (F36); without it the
  // page keeps the global set (T8a ruling 11).
  if (family == ContextFamily.communityMembers &&
      !isFeatureEnabled(context, kFeatureCommunityMemberSearch)) {
    family = ContextFamily.global;
  }
  // Likewise the Lists pages need `lists` (T8b).
  final listsFamily = switch (family) {
    ContextFamily.listDetail ||
    ContextFamily.managePinned ||
    ContextFamily.userLists => true,
    _ => false,
  };
  if (listsFamily && !isFeatureEnabled(context, kFeatureLists)) {
    family = ContextFamily.global;
  }
  // The plan forms need `beacons` (the router sends them to `/plans`
  // without it); should one show anyway, it gets the global set.
  final planFormFamily =
      family == ContextFamily.planCreate || family == ContextFamily.planEdit;
  if (planFormFamily && !isFeatureEnabled(context, kFeatureBeacons)) {
    family = ContextFamily.global;
  }
  final search = isFeatureEnabled(context, kFeatureSearch);
  final trends = search && isFeatureEnabled(context, kFeatureTrends);
  final suggestions = isFollowSuggestionsEnabled(context);

  ContextSection whoToFollow(String title) => ContextSection(
    ContextSectionKind.whoToFollow,
    WhoToFollowCard(
      title: title,
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
    ),
  );
  const whatsHappening = ContextSection(
    ContextSectionKind.trends,
    WhatsHappeningCard(),
  );
  // Until the page has lent its section (a page being pushed takes its lease
  // as it builds), the slot draws that section's loading look, never the
  // footer alone.
  ContextSection lent(ContextSectionKind kind, Widget placeholder) =>
      ContextSection(
        kind,
        ContextPaneSlot(
          kind: kind,
          location: location,
          placeholder: placeholder,
        ),
      );

  return [
    ...switch (family) {
      ContextFamily.global => contextGlobalSections(context),
      ContextFamily.explore ||
      ContextFamily.people => [if (suggestions) whoToFollow('Who to follow')],
      // F16 (R8): the follow-requests card, lent by the page over its own
      // `ListFollowRequests(3)`, above What's happening. Listed only under
      // the card's own rule, so the page's inline row steps aside exactly
      // while the pane holds the card.
      ContextFamily.notifications => [
        // Only while Notifications itself is the top page: a post or a
        // search pushed over it keeps the family (base route) but not the
        // page's card, as on desktop.
        if ((_shellTopLocation(context) ?? location) ==
                AppRouter.notificationsPath &&
            followRequestsCardAllowed(context))
          const ContextSection(
            ContextSectionKind.followRequests,
            FollowRequestsCardSlot(),
          ),
        if (trends) whatsHappening,
      ],
      ContextFamily.search => [if (trends) whatsHappening],
      // The media strip (T8c), lent by the profile page over its own Media
      // tab feed: only with the feed's flags (`posts`, `profile_tabs`).
      ContextFamily.profile => [
        if (isFeatureEnabled(context, kFeaturePosts) &&
            isFeatureEnabled(context, kFeatureProfileTabs))
          lent(
            ContextSectionKind.profileMedia,
            const ProfileMediaStripPlaceholder(),
          ),
        if (suggestions) whoToFollow('You might like'),
      ],
      // Lent by the page, over its own state (no call of the pane's own).
      ContextFamily.communities => [
        lent(
          ContextSectionKind.exploreCommunities,
          const ExploreCommunitiesPanePlaceholder(),
        ),
      ],
      ContextFamily.communityCreate => [
        lent(ContextSectionKind.communityPreview, const CommunityPreviewCard()),
      ],
      ContextFamily.community => [
        lent(
          ContextSectionKind.communityAbout,
          const CommunityAboutPanePlaceholder(),
        ),
      ],
      ContextFamily.moderationLog => [
        lent(
          ContextSectionKind.moderationLogAbout,
          const ModerationLogAboutPlaceholder(),
        ),
      ],
      ContextFamily.communityMembers => [
        lent(
          ContextSectionKind.memberSearch,
          const CommunitySearchField(
            hint: kSearchMembersHint,
            label: kSearchMembersLabel,
          ),
        ),
      ],
      ContextFamily.listDetail => [
        lent(
          ContextSectionKind.listMembers,
          const ListMembersPanePlaceholder(),
        ),
      ],
      ContextFamily.managePinned => [
        lent(
          ContextSectionKind.homeTabsPreview,
          const HomeTabsPreviewPlaceholder(),
        ),
      ],
      ContextFamily.userLists => [
        lent(ContextSectionKind.listsOwner, const ListsOwnerCardPlaceholder()),
      ],
      // Lent by the form (T8d): the preview follows the typing, and the
      // edit form shows nothing over its loading or failed plan.
      ContextFamily.planCreate => [
        lent(ContextSectionKind.planPreview, const PlanPreviewCard()),
        lent(ContextSectionKind.planTips, const PlanTipsCard()),
      ],
      ContextFamily.planEdit => [
        lent(ContextSectionKind.planPreview, const PlanPreviewCard()),
        lent(ContextSectionKind.planTips, const SizedBox.shrink()),
      ],
      ContextFamily.none => const <ContextSection>[],
    },
    ContextSection(
      ContextSectionKind.links,
      AppSideLinks(
        links: [
          AppSideLink(
            icon: Icons.privacy_tip_outlined,
            label: 'Privacy Policy',
            onTap: () => launchPrivacyPolicy(context),
          ),
          AppSideLink(
            icon: Icons.rule_outlined,
            label: 'Community rules',
            onTap: () => launchCommunityRules(context),
          ),
        ],
      ),
    ),
  ];
}

/// The global set, top to bottom: the search pill, the profile card, What's
/// happening and Who to follow, each gated as everywhere else (no footer).
/// [contextSectionsFor]'s global family; a page whose own lent section goes
/// away may draw these in its slot instead of a blank pane (R10: the members
/// page when the server turns member search off).
List<ContextSection> contextGlobalSections(BuildContext context) {
  final search = isFeatureEnabled(context, kFeatureSearch);
  final trends = search && isFeatureEnabled(context, kFeatureTrends);
  return [
    if (search)
      const ContextSection(
        ContextSectionKind.search,
        Padding(
          padding: EdgeInsets.only(bottom: AppSpacing.md),
          child: AppSearchField(),
        ),
      ),
    ?_profileSection(context),
    if (trends)
      const ContextSection(ContextSectionKind.trends, WhatsHappeningCard()),
    if (isFollowSuggestionsEnabled(context))
      const ContextSection(
        ContextSectionKind.whoToFollow,
        WhoToFollowCard(
          title: 'Who to follow',
          margin: EdgeInsets.only(bottom: AppSpacing.md),
        ),
      ),
  ];
}

/// The signed-in user's card, from the profile already loaded (nothing is
/// fetched); null without one.
ContextSection? _profileSection(BuildContext context) {
  final profile = context.select((OnboardingBloc bloc) => bloc.state.profile);
  final handle = profile?.handle;
  if (profile == null || handle == null || handle.isEmpty) return null;
  return ContextSection(
    ContextSectionKind.profile,
    Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: AppSideProfileCard(
        profile: AppSideProfile(
          displayName: profile.displayName,
          handle: handle,
          avatarUrl: profile.avatarThumbUrl,
          onTap: () => context.go(AppRouter.profilePath(handle)),
        ),
      ),
    ),
  );
}

/// The location of the top page inside the shell's navigator, or null
/// without a router or a shell match (R8; the same rule as `MainShell`'s).
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
