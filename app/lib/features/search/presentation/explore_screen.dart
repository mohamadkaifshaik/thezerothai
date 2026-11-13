import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_shell_scope.dart';
import '../../../core/widgets/app_top_bar.dart';
import '../../../shared/widgets/primitives/app_icon_button.dart';
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
/// two-row sticky header (the search field and Settings, then a one-tab
/// "Trending" bar), the trends list, and the "Who to follow" card (W3's, which
/// draws nothing unless its own flags are on). No news, sports or
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

  bool _mediaAllowed(BuildContext context) =>
      isFeatureEnabled(context, kFeatureSearch) &&
      isFeatureEnabled(context, kFeatureMedia) &&
      isFeatureEnabled(context, kFeatureTrends);

  @override
  void dispose() {
    _media?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final rowHeight = searchFieldHeightFor(scaler) + AppSpacing.sm;
    final trends = isFeatureEnabled(context, kFeatureTrends);
    final showMedia = _mediaAllowed(context);
    // Made the first time the flags allow it and kept after that, so a flag
    // flicker never asks again.
    final media = showMedia
        ? _media ??= ExploreMediaCubit(
            repository: context.read<SearchRepository>(),
          )
        : null;
    Widget scroll = CustomScrollView(
      slivers: [
        SliverPersistentHeader(
          pinned: true,
          delegate: _ExploreHeader(extent: rowHeight, rowHeight: rowHeight),
        ),
        if (trends) const ExploreTrendsSection(),
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

class _ExploreHeader extends SliverPersistentHeaderDelegate {
  const _ExploreHeader({required this.extent, required this.rowHeight});

  final double extent;
  final double rowHeight;

  @override
  double get minExtent => extent;

  @override
  double get maxExtent => extent;

  @override
  bool shouldRebuild(_ExploreHeader old) =>
      old.extent != extent || old.rowHeight != rowHeight;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final colors = Theme.of(context).colorScheme;
    final narrow = MediaQuery.sizeOf(context).width < AppBreakpoints.mobile;
    return ColoredBox(
      color: colors.surface.withValues(alpha: 0.92),
      child: Column(
        children: [
          SizedBox(
            height: rowHeight,
            child: Row(
              children: [
                // Phones: the avatar opens the drawer (Profile, Lists...).
                if (narrow && AppShellScope.maybeOf(context) != null)
                  const Padding(
                    padding: EdgeInsets.only(left: AppSpacing.sm),
                    child: AppAvatarButton(),
                  )
                else
                  const SizedBox(width: AppSpacing.md),
                const Expanded(child: Center(child: AppSearchField())),
                AppIconButton(
                  icon: Icons.settings_outlined,
                  tooltip: 'Settings',
                  onPressed: () => context.push(AppRouter.settingsPath),
                ),
                const SizedBox(width: AppSpacing.xs),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
