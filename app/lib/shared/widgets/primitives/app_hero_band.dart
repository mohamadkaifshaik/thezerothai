import 'package:material_ui/material_ui.dart';

import '../../../core/theme/app_theme.dart';
import 'app_rings.dart';

/// Where a [AppHeroBand]'s teal rings sit and how many there are, from the
/// artboards (rings are diameters in dp, then stroke alpha).
enum AppHeroRings {
  /// DzProfile: three rings, centre 60 dp in from the end and 90 dp down.
  profile(
    [(120, .35), (200, .22), (290, .12)],
    _profileCentre,
    strokeWidth: 1.5,
  ),

  /// ZListDetail: two rings, centre 50 dp in from the end and 40 dp down.
  list([(100, .3), (190, .15)], _listCentre),

  /// ZWelcome: three large rings, centre 195 dp from the start, 110 down.
  welcome(
    [(220, .22), (360, .14), (500, .08)],
    _welcomeCentre,
    strokeWidth: 1.5,
  );

  const AppHeroRings(this.rings, this.centre, {this.strokeWidth = 1});

  /// (diameter, alpha) from the inside out.
  final List<(double, double)> rings;
  final Offset Function(Size) centre;
  final double strokeWidth;
}

Offset _profileCentre(Size s) => Offset(s.width - 60, 90);
Offset _listCentre(Size s) => Offset(s.width - 50, 40);
Offset _welcomeCentre(Size s) => const Offset(195, 110);

/// The navy hero band of DzProfile, ZListDetail and ZWelcome: [AppPalette.navy]
/// in both themes with the teal rings of [rings] behind [child], clipped to the
/// band. The rings take no input and are not in the semantics tree.
///
/// The band sizes itself to [child] plus [padding]; put it at the top of a page
/// (a header: pass [safeTop] so it clears the status bar) or inside a sliver
/// box. Text in the band is white, muted copy [AppPalette.mutedOnDark]; set
/// them on the child (the band does not restyle text).
class AppHeroBand extends StatelessWidget {
  const AppHeroBand({
    super.key,
    required this.child,
    this.rings = AppHeroRings.profile,
    this.padding = const EdgeInsetsDirectional.fromSTEB(8, 8, 16, 16),
    this.safeTop = false,
    this.borderRadius,
  });

  /// The band's content, over the rings.
  final Widget child;
  final AppHeroRings rings;

  /// Space around [child] (artboards: 8 / 8 / 16 / 16 for the list; the
  /// profile adds its own).
  final EdgeInsetsGeometry padding;

  /// Add the top safe-area inset (the band is a screen header).
  final bool safeTop;

  /// Rounds the band (a wide layout's card); null keeps square edges.
  final BorderRadiusGeometry? borderRadius;

  @override
  Widget build(BuildContext context) {
    final content = Padding(padding: padding, child: child);
    return ClipRRect(
      borderRadius: borderRadius ?? BorderRadius.zero,
      child: ColoredBox(
        color: AppPalette.navy,
        child: Stack(
          children: [
            Positioned.fill(
              child: AppRings(
                rings: rings.rings,
                color: AppPalette.tealElectric,
                centre: rings.centre,
                strokeWidth: rings.strokeWidth,
              ),
            ),
            safeTop ? SafeArea(bottom: false, child: content) : content,
          ],
        ),
      ),
    );
  }
}
