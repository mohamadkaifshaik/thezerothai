import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/primitives/app_main_column.dart';

/// The cover band's height without the status bar (the design's 150 dp less
/// its 44 dp status area); the band draws under the status bar, so on a phone
/// it is this plus the top inset.
const double kCommunityCoverBandHeight = 106;

/// The diameter of the Back and options circles on the band (dz `44`); the
/// tap target around each is [AppSpacing.minTapTarget].
const double kCommunityBandButtonSize = 44;

/// The centre of the rings, in from the end edge and down from the top
/// (Community.dc.html: `left: 330px` of 390, `top: 40px`).
const double kCommunityRingsEndInset = 60;
const double kCommunityRingsTop = 40;

/// The three ring radii and their stroke opacities (Community.dc.html).
const List<(double, double)> kCommunityRings = [
  (56, 0.4),
  (104, 0.24),
  (160, 0.12),
];

/// The cover band of a community page (the design's navy 135 degree
/// gradient with three teal rings; `Community` has no cover image field, so
/// the band is the same for every community). Back and, when given,
/// [action] sit on it. Decorative: the rings carry no semantics.
class CommunityCoverBand extends StatelessWidget {
  const CommunityCoverBand({super.key, required this.onBack, this.action});

  final VoidCallback onBack;

  /// The options control (a [CommunityBandAction]); null draws nothing.
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    // On the tablet layout the band spans the pane; its buttons keep to the
    // readable column.
    final inset = AppMainColumnBleed.of(context);
    final band = SizedBox(
      height: kCommunityCoverBandHeight + top,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppPalette.navy2, AppPalette.navy],
          ),
        ),
        child: ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: [
              ExcludeSemantics(
                child: CustomPaint(
                  key: const ValueKey('community-cover-rings'),
                  painter: _RingsPainter(
                    textDirection: Directionality.of(context),
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsetsDirectional.fromSTEB(
                  AppSpacing.sm + inset,
                  top + AppSpacing.sm,
                  AppSpacing.sm + inset,
                  0,
                ),
                child: Align(
                  alignment: AlignmentDirectional.topStart,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      CommunityBandAction(
                        icon: Icons.chevron_left,
                        tooltip: 'Back',
                        onPressed: onBack,
                      ),
                      const Spacer(),
                      ?action,
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    // Under the status bar (the tablet pane keeps the inset) its icons turn
    // light for as long as the band is on screen: the region follows the
    // band when it scrolls away.
    if (top == 0) return band;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
      child: band,
    );
  }
}

/// One circle on the band: 44 dp, 8 % pearl fill and the 1 dp on-dark
/// boundary, inside a 48 dp tap target. With [onPressed] it is a button
/// named [tooltip]; [popup] wraps it for a menu button instead.
class CommunityBandAction extends StatelessWidget {
  const CommunityBandAction({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  /// The circle alone, for a control that supplies its own tap (the popup
  /// menu button's child).
  static Widget circle(IconData icon) => SizedBox.square(
    dimension: AppSpacing.minTapTarget,
    child: Center(
      child: Container(
        width: kCommunityBandButtonSize,
        height: kCommunityBandButtonSize,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppPalette.pearl.withValues(alpha: 0.08),
          border: Border.all(color: AppPalette.uiBorderOnDark),
        ),
        child: Icon(icon, size: AppIconSize.md, color: AppPalette.pearl),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    // Pearl, so the hover, focus and press overlays show on the navy band.
    style: IconButton.styleFrom(foregroundColor: AppPalette.pearl),
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints.tightFor(
      width: AppSpacing.minTapTarget,
      height: AppSpacing.minTapTarget,
    ),
    icon: circle(icon),
  );
}

class _RingsPainter extends CustomPainter {
  const _RingsPainter({required this.textDirection});

  final TextDirection textDirection;

  @override
  void paint(Canvas canvas, Size size) {
    final x = textDirection == TextDirection.rtl
        ? kCommunityRingsEndInset
        : size.width - kCommunityRingsEndInset;
    final centre = Offset(x, kCommunityRingsTop);
    for (final (radius, alpha) in kCommunityRings) {
      canvas.drawCircle(
        centre,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = AppPalette.tealElectric.withValues(alpha: alpha),
      );
    }
  }

  @override
  bool shouldRepaint(_RingsPainter old) => old.textDirection != textDirection;
}
