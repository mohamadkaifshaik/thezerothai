import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

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
  final family = contextFamilyFor(location);
  if (family == ContextFamily.none) return const [];
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
