import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// The raised card (dz.css `.card`): the `card` gradient (white to
/// `#EEF1F4`) on light, `darkCard` (navy2 to navy) on dark, the `card`
/// radius and [AppShadows.card]. Flutter has no inset shadow, so the 1.5 dp
/// top highlight is a white line painted along the top edge, inset by the
/// corner radius. Only the container: [child] owns its content and padding.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.md),
    this.margin = EdgeInsets.zero,
  });

  /// Height of the top highlight.
  static const double highlightHeight = 1.5;

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;

  /// The gradient the card paints for [brightness].
  static Gradient gradientFor(Brightness brightness) =>
      brightness == Brightness.dark ? AppGradients.darkCard : AppGradients.card;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final radius = BorderRadius.circular(AppRadius.card);
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        gradient: gradientFor(brightness),
        borderRadius: radius,
        boxShadow: AppShadows.card,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Stack(
          children: [
            Padding(padding: padding, child: child),
            // Decorative: never hit-testable, never announced.
            Positioned(
              top: 0,
              left: AppRadius.card / 2,
              right: AppRadius.card / 2,
              height: highlightHeight,
              child: ExcludeSemantics(
                child: IgnorePointer(
                  child: DecoratedBox(
                    key: const ValueKey('app-card-highlight'),
                    decoration: BoxDecoration(
                      color: brightness == Brightness.dark
                          ? AppPalette.white.withValues(alpha: 0.12)
                          : AppPalette.white,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The plan strip container (dz.css `.plan`): a navy bar with the `cardSmall`
/// radius, 12 x 16 padding and pearl text. Only the container; the plan
/// content stays in the beacons feature. Pearl on navy is 15+:1; the accent
/// on it is the electric teal (9.61).
class AppPlanStrip extends StatelessWidget {
  const AppPlanStrip({super.key, required this.child, this.onTap});

  final Widget child;

  /// Makes the whole strip a tappable region (the caller labels it).
  final VoidCallback? onTap;

  /// The accent colour for text on the strip (the `.eyebrow` and `.go`).
  static const Color accent = AppPalette.tealElectric;

  /// The keyboard focus overlay: pearl, so focus shows on the navy fill in
  /// both themes (the theme's default overlay is navy-family and vanishes on
  /// it). Over navy it reads at 3:1 or more.
  static final Color focusOverlay = AppPalette.pearl.withValues(alpha: 0.4);

  /// Hover and press overlays, in the same pearl.
  static final Color hoverOverlay = AppPalette.pearl.withValues(alpha: 0.08);
  static final Color pressOverlay = AppPalette.pearl.withValues(alpha: 0.16);

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(AppRadius.cardSmall);
    final content = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.smd,
      ),
      child: DefaultTextStyle.merge(
        style: const TextStyle(color: AppPalette.pearl),
        child: IconTheme.merge(
          data: const IconThemeData(color: AppPalette.pearl),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: AppSpacing.minTapTarget - AppSpacing.md,
            ),
            child: child,
          ),
        ),
      ),
    );
    final strip = Material(
      color: AppPalette.navy,
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: onTap == null
          ? content
          : InkWell(
              onTap: onTap,
              focusColor: focusOverlay,
              hoverColor: hoverOverlay,
              highlightColor: pressOverlay,
              splashColor: pressOverlay,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: AppSpacing.minTapTarget,
                ),
                child: content,
              ),
            ),
    );
    // On the navy page of the dark theme the strip would have no edge: the
    // dark hairline draws one (decorative, over the fill).
    if (Theme.of(context).brightness != Brightness.dark) return strip;
    return DecoratedBox(
      key: const ValueKey('app-plan-strip-edge'),
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(color: AppPalette.hairlineDark),
      ),
      child: strip,
    );
  }
}
