import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_top_bar.dart';
import '../../../shared/widgets/primitives/app_tab_bar.dart';
import '../../beacons/data/beacons_repository.dart';
import '../../beacons/domain/beacons_feature_flag.dart';
import '../../beacons/presentation/bloc/beacons_cubit.dart';
import '../../beacons/presentation/bloc/nearby_plans_cubit.dart';

import '../../graph/presentation/graph_feature_flags.dart';
import '../../location/domain/location_feature_flag.dart';
import '../domain/explore_tab.dart';
import 'widgets/explore_people_section.dart';
import 'widgets/explore_nearby_section.dart';
import 'widgets/explore_plans_section.dart';
import '../../../core/feature_flags/feature_flags.dart';
import '../../graph/presentation/widgets/who_to_follow_card.dart';
import '../domain/search_feature_flags.dart';
import '../../media/domain/media_feature_flag.dart';
import '../data/search_repository.dart';
import 'bloc/explore_media_cubit.dart';
import 'widgets/explore_media_section.dart';
import 'widgets/explore_trends_section.dart';
import 'widgets/app_search_field.dart';
import '../../../core/widgets/shell_bottom_inset_sliver.dart';

/// `/explore`: a root destination of the new shell. A
/// sticky header (the search field and Settings, plus a tab bar only when
/// more than Trending is on), the trends list, and the "Who to follow" card
/// (W3's, which draws nothing unless its own flags are on). F18 tabs:
/// Trending, Plans (public plans, with `beacons`) and People (the suggestions,
/// with `graph` and `follow_suggestions`); a tab whose flag is off is not
/// shown and Trending alone has no bar. No Nearby tab, no news, sports or
/// entertainment tabs, no "Happening nearby" hero (nothing counts plans
/// tonight), no "Posts for you" (F7). The route needs `search` and `ui_shell`.
/// The height reserved for the search field in Explore's header at text scale
/// [scaler]: the 48dp target, or the text line plus the field's padding when the
/// text is scaled up. A pinned sliver header needs its extent up front.
double searchFieldHeightFor(TextScaler scaler) {
  final padded =
      scaler.scale(AppSpacing.lg + AppSpacing.xs) + 2 * AppSpacing.smd;
  return padded < AppSpacing.minTapTarget ? AppSpacing.minTapTarget : padded;
}

class ExploreScreen extends StatefulWidget {
  const ExploreScreen({super.key});

  @override
  State<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends State<ExploreScreen> {
  /// The Media section's photos, one fetch per open (null while a flag it
  /// needs is off). Shared with the Media page by its route's `extra`.
  ExploreMediaCubit? _media;

  /// The Plans tab's public list, made when the tab is first opened (opening
  /// Explore sends no ListBeacons) and kept for the session of the screen.
  BeaconsCubit? _plans;

  /// The Nearby tab's list, made when the tab is first opened. When the
  /// server says Nearby is off (FEATURE_DISABLED) the tab is hidden.
  NearbyPlansCubit? _nearby;
  StreamSubscription<NearbyPlansState>? _nearbySub;
  bool _nearbyOff = false;
  ExploreTab _tab = ExploreTab.trending;

  NearbyPlansCubit _makeNearby() {
    final cubit = NearbyPlansCubit(
      repository: context.read<BeaconsRepository>(),
    )..load();
    _nearbySub = cubit.stream.listen((s) {
      if (s.load == NearbyLoad.disabled && mounted && !_nearbyOff) {
        setState(() => _nearbyOff = true);
      }
    });
    return cubit;
  }

  bool _mediaAllowed(BuildContext context) =>
      isFeatureEnabled(context, kFeatureSearch) &&
      isFeatureEnabled(context, kFeatureMedia) &&
      isFeatureEnabled(context, kFeatureTrends);

  @override
  void dispose() {
    _media?.close();
    _plans?.close();
    _nearbySub?.cancel();
    _nearby?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final trends = isFeatureEnabled(context, kFeatureTrends);
    final showMedia = _mediaAllowed(context);
    // Made the first time the flags allow it and kept after that, so a flag
    // flicker never asks again.
    final media = showMedia
        ? _media ??= ExploreMediaCubit(
            repository: context.read<SearchRepository>(),
          )
        : null;
    final tabs = exploreTabsFor(
      nearby:
          !_nearbyOff &&
          isFeatureEnabled(context, kFeatureLocation) &&
          isFeatureEnabled(context, kFeatureBeacons),
      plans: isFeatureEnabled(context, kFeatureBeacons),
      people: isFollowSuggestionsEnabled(context),
    );
    final tab = resolveExploreTab(_tab, tabs);
    final showBar = showsExploreTabBar(tabs);
    BeaconsCubit? plans;
    if (tab == ExploreTab.plans) {
      plans = _plans ??= BeaconsCubit(
        repository: context.read<BeaconsRepository>(),
      )..load();
    }
    NearbyPlansCubit? nearby;
    if (tab == ExploreTab.nearby) {
      nearby = _nearby ??= _makeNearby();
    }
    // The same header as the other tab screens: the floating top bar (the
    // search field in the title slot, Settings as the round action) and,
    // with more than Trending, the pinned tab bar.
    final locationOn = isFeatureEnabled(context, kFeatureLocation);
    final header = [
      AppTopBar.sliver(
        titleWidget: const AppSearchField(),
        titleWidgetHeight: searchFieldHeightFor(scaler),
        actions: [
          AppTopBarAction(
            icon: Icons.settings_outlined,
            tooltip: 'Settings',
            // F8: with `location` on the gear opens Explore settings.
            onPressed: () => context.push(
              locationOn
                  ? AppRouter.exploreSettingsPath
                  : AppRouter.settingsPath,
            ),
          ),
        ],
      ),
      if (showBar)
        AppPinnedTabBarSliver(
          child: AppTabBar(
            tabs: [for (final t in tabs) AppTab(label: t.label)],
            selectedIndex: tabs.indexOf(tab),
            onChanged: (i) => setState(() => _tab = tabs[i]),
            autoWidth: true,
            semanticLabel: 'Explore',
          ),
        ),
    ];
    if (tab == ExploreTab.plans ||
        tab == ExploreTab.people ||
        tab == ExploreTab.nearby) {
      return Scaffold(
        body: RefreshIndicator(
          onRefresh: () => switch (tab) {
            ExploreTab.plans => plans!.load(),
            ExploreTab.nearby => nearby!.load(),
            _ => ExplorePeopleSection.reload(context),
          },
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              ...header,
              if (tab == ExploreTab.plans)
                ExplorePlansSection(cubit: plans!)
              else if (tab == ExploreTab.nearby)
                ExploreNearbySection(cubit: nearby!)
              else
                const ExplorePeopleSection(),
              const ShellBottomInsetSliver(),
            ],
          ),
        ),
      );
    }
    Widget scroll = CustomScrollView(
      slivers: [
        ...header,
        if (trends) ExploreTrendsSection(showTitle: !showBar),
        if (media != null) ExploreMediaSection(cubit: media),
        // Inline below desktop; from 1200 dp the shell's side column carries
        // the same suggestions ("You might like"), so one card, one place.
        // The sliver itself stays, so the list keeps its shape across 1200.
        SliverToBoxAdapter(
          child: MediaQuery.sizeOf(context).width >= AppBreakpoints.tablet
              ? const SizedBox.shrink()
              : const WhoToFollowCard(margin: EdgeInsets.all(AppSpacing.md)),
        ),
        const ShellBottomInsetSliver(),
      ],
    );
    if (media != null) {
      scroll = ExploreMediaStarter(cubit: media, child: scroll);
    }
    return Scaffold(body: scroll);
  }
}
