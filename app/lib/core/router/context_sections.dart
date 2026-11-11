import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../features/communities/domain/communities_feature_flag.dart';
import '../../features/communities/presentation/widgets/community_about.dart'
    show CommunityAboutPanePlaceholder;
import '../../features/communities/presentation/widgets/community_preview.dart'
    show CommunityPreviewCard;
import '../../features/communities/presentation/widgets/explore_communities_pane.dart'
    show ExploreCommunitiesPanePlaceholder;
import '../../features/communities/presentation/widgets/moderation_log_about.dart'
    show ModerationLogAboutPlaceholder;
import '../../features/graph/presentation/graph_feature_flags.dart';
import '../../features/graph/presentation/widgets/who_to_follow_card.dart';
import '../../features/onboarding/presentation/bloc/onboarding_bloc.dart';
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

  /// Notifications: What's happening.
  notifications,

  /// Search results: What's happening (the filters wait for F22).
  search,

  /// Follow requests, Followers and Following: Who to follow.
  people,

  /// A profile: You might like (the media strip is T8).
  profile,

  /// `/communities` (T8a): "Explore Communities", lent by the page (its
  /// directory and Join). F37's scoped "Search Communities" waits.
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
}

/// Whether [location] is one of the communities pages (`/communities` and
/// everything under it).
bool _isCommunitiesLocation(String location) {
  final segments = Uri.parse(location).pathSegments;
  return segments.isNotEmpty && segments.first == 'communities';
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
/// Everything else keeps T3's rule: the base route decides.
String contextPaneLocationFor(String base, String? top) {
  if (top == null) return base;
  return _isCommunitiesLocation(top) || _isCommunitiesLocation(base)
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
    ['plans', 'new'] || ['plans', 'mine'] => ContextFamily.global,
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
    // CommunityMembers: the global set (F36's "Search members" waits).
    ['communities', _, 'members'] => ContextFamily.global,
    ['communities', _] => ContextFamily.community,
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
    ContextFamily.moderationLog => true,
    _ => false,
  };
  if (communitiesFamily && !isFeatureEnabled(context, kFeatureCommunities)) {
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
      ContextFamily.global => [
        if (search)
          const ContextSection(
            ContextSectionKind.search,
            Padding(
              padding: EdgeInsets.only(bottom: AppSpacing.md),
              child: AppSearchField(),
            ),
          ),
        ?_profileSection(context),
        if (trends) whatsHappening,
        if (suggestions) whoToFollow('Who to follow'),
      ],
      ContextFamily.explore ||
      ContextFamily.people => [if (suggestions) whoToFollow('Who to follow')],
      ContextFamily.notifications ||
      ContextFamily.search => [if (trends) whatsHappening],
      ContextFamily.profile => [if (suggestions) whoToFollow('You might like')],
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
