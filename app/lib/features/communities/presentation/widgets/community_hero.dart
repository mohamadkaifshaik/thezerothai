import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';

/// The tablet and desktop bar of a community page (dz.css `.bar`): Back, the
/// "Community" title and, when given, the options [action] at the end. The
/// phone has the cover band's buttons instead.
class CommunityTopBar extends StatelessWidget {
  const CommunityTopBar({super.key, required this.onBack, this.action});

  final VoidCallback onBack;

  /// The options control; null draws nothing.
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: SizedBox(
        height: AppSize.headerRow,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Back',
                icon: const Icon(Icons.arrow_back),
                onPressed: onBack,
              ),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    'Community',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ),
              ?action,
            ],
          ),
        ),
      ),
    );
  }
}

/// The navy card under the bar on tablet and desktop (dz.css `.hero`: the
/// radial wash, 28 dp bottom corners and a teal ring at the top end). Its
/// [child] reads the dark theme, so text, links and pills are pearl on it.
class CommunityHero extends StatelessWidget {
  const CommunityHero({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: AppGradients.hero,
        borderRadius: BorderRadius.vertical(
          bottom: Radius.circular(AppCommunitiesLayout.heroRadius),
        ),
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(
          bottom: Radius.circular(AppCommunitiesLayout.heroRadius),
        ),
        child: Stack(
          children: [
            const PositionedDirectional(
              end: AppCommunitiesLayout.heroRingEnd,
              top: AppCommunitiesLayout.heroRingTop,
              child: ExcludeSemantics(child: _Ring()),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppCommunitiesLayout.heroPaddingH,
                AppCommunitiesLayout.heroPaddingTop,
                AppCommunitiesLayout.heroPaddingH,
                AppCommunitiesLayout.heroPaddingBottom,
              ),
              child: Theme(data: appDarkTheme, child: child),
            ),
          ],
        ),
      ),
    );
  }
}

class _Ring extends StatelessWidget {
  const _Ring();

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('community-hero-ring'),
    width: AppCommunitiesLayout.heroRingDiameter,
    height: AppCommunitiesLayout.heroRingDiameter,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      border: Border.all(
        color: AppPalette.tealElectric.withValues(
          alpha: AppCommunitiesLayout.heroRingAlpha,
        ),
      ),
    ),
  );
}
