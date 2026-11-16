import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/feature_flags/feature_flags.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../location/domain/location_feature_flag.dart';
import '../../../search/domain/search_feature_flags.dart';
import '../../domain/beacons_feature_flag.dart';
import '../bloc/happening_nearby_session.dart';

/// Where the card leads: Explore on its Nearby tab.
const kHappeningNearbyPath = '${AppRouter.explorePath}?tab=nearby';

/// The flags the card needs: the count (`location`, `beacons`) and a route to
/// land on (`search`, which Explore needs).
const kHappeningNearbyFlags = {
  kFeatureLocation,
  kFeatureBeacons,
  kFeatureSearch,
};

/// The pages whose desktop side column carries the card (the Home feed,
/// Drafts, Plans and My plans mocks).
bool happeningNearbyOnLocation(String location) {
  final path = Uri.parse(location).path;
  return path == AppRouter.homePath ||
      path == AppRouter.draftsPath ||
      path == AppRouter.plansPath ||
      path == AppRouter.plansMinePath;
}

/// The desktop side column's "Happening nearby" hero (the desktop Feed,
/// Drafts, Home and MyPlans mocks): "14 plans tonight." over the viewer's
/// area, one tap to Explore's Nearby tab.
///
/// Draws nothing, and asks nothing, below 1200 dp, with `location`,
/// `beacons` or `search` off, with no session above, or while there is no
/// answer to show (loading, failed, no saved area, no plan tonight).
class HappeningNearbyCard extends StatefulWidget {
  const HappeningNearbyCard({super.key});

  @override
  State<HappeningNearbyCard> createState() => _HappeningNearbyCardState();
}

class _HappeningNearbyCardState extends State<HappeningNearbyCard> {
  bool _allowed(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= AppBreakpoints.tablet &&
      kHappeningNearbyFlags.every((f) => isFeatureEnabled(context, f));

  @override
  Widget build(BuildContext context) {
    final session = context.read<HappeningNearbySession?>();
    if (session == null || !_allowed(context)) return const SizedBox.shrink();
    // Starts the one shared call (a no-op within 5 minutes or while one is
    // under way); it answers asynchronously, never during this build.
    session.ensure();
    return ValueListenableBuilder<HappeningNearby?>(
      valueListenable: session.result,
      builder: (context, nearby, _) =>
          nearby == null ? const SizedBox.shrink() : _HeroBody(nearby: nearby),
    );
  }
}

class _HeroBody extends StatelessWidget {
  const _HeroBody({required this.nearby});

  final HappeningNearby nearby;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = nearby.tonight.phrase;
    final headline = theme.textTheme.displaySmall?.copyWith(
      color: AppPalette.pearl,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Semantics(
        button: true,
        excludeSemantics: true,
        label: '$count tonight near ${nearby.areaName}. See plans',
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.card),
          child: Ink(
            key: const ValueKey('happening-nearby'),
            decoration: BoxDecoration(
              gradient: AppGradients.hero,
              borderRadius: BorderRadius.circular(AppRadius.card),
              boxShadow: AppShadows.brand,
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(AppRadius.card),
              onTap: () => context.go(kHappeningNearbyPath),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.card),
                child: Stack(
                  children: [
                    const Positioned(
                      right: -90,
                      top: -90,
                      child: _Ring(size: 260),
                    ),
                    const Positioned(
                      right: -40,
                      top: -40,
                      child: _Ring(size: 160),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(AppSpacing.lg),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Happening nearby'.toUpperCase(),
                            style: AppTextStyles.eyebrow(theme)
                                .copyWith(color: AppPalette.tealElectric),
                          ),
                          const SizedBox(height: AppSpacing.smd),
                          Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(text: '$count '),
                                const TextSpan(
                                  text: 'tonight',
                                  style: TextStyle(
                                    color: AppPalette.tealElectric,
                                  ),
                                ),
                                const TextSpan(text: '.'),
                              ],
                            ),
                            style: headline,
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          Text(
                            'Near ${nearby.areaLabel}',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: AppPalette.mutedOnDark,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.md),
                          Text(
                            'See plans',
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: AppPalette.tealElectric,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A decorative outline circle of the hero (the mock's `.ring`).
class _Ring extends StatelessWidget {
  const _Ring({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: AppPalette.pearl.withValues(alpha: 0.08)),
        ),
      ),
    ),
  );
}
