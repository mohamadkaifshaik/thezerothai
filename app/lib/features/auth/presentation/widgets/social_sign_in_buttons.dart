import '../../../../core/theme/app_theme.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../../app/app_config.dart';

/// Google + Apple sign-in buttons. Apple is only shown on iOS, macOS and web
/// per Apple's guidelines; on iOS it is additionally gated by
/// [AppConfig.appleSignInIosEnabled] (off until Sign in with Apple is set up
/// for iOS). There is no phone/SMS sign-in.
class SocialSignInButtons extends StatelessWidget {
  const SocialSignInButtons({
    super.key,
    required this.isSubmitting,
    required this.onGoogleTap,
    required this.onAppleTap,
    this.stacked = false,
    this.appleOnIosEnabled = AppConfig.appleSignInIosEnabled,
  });

  final bool isSubmitting;
  final VoidCallback onGoogleTap;
  final VoidCallback onAppleTap;

  /// The welcome page's full-width "Continue with ..." pills, one under the
  /// other, instead of the forms' two-up row.
  final bool stacked;

  /// Defaults to [AppConfig.appleSignInIosEnabled]; overridable in tests.
  final bool appleOnIosEnabled;

  /// Web needs an Apple Services ID (`APPLE_SERVICE_ID`), otherwise the button
  /// can only fail. Checked before the platform because on web
  /// `defaultTargetPlatform` reports the browser's OS (macOS/iOS on Apple devices).
  bool get _showApple {
    if (kIsWeb) return AppConfig.appleSignInOnWebConfigured;
    return (defaultTargetPlatform == TargetPlatform.iOS && appleOnIosEnabled) ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  @override
  Widget build(BuildContext context) {
    final google = _SocialPill(
      label: stacked ? 'Continue with Google' : 'Google',
      semanticsLabel: 'Continue with Google',
      onPressed: isSubmitting ? null : onGoogleTap,
      mark: const CustomPaint(painter: _GoogleMark()),
    );
    final apple = _showApple
        ? _SocialPill(
            label: stacked ? 'Continue with Apple' : 'Apple',
            semanticsLabel: 'Continue with Apple',
            onPressed: isSubmitting ? null : onAppleTap,
            mark: const Icon(Icons.apple, size: AppAuthLayout.socialMarkSize),
          )
        : null;
    if (stacked) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          google,
          if (apple != null) ...[
            const SizedBox(height: AppWelcomeLayout.providerGap),
            apple,
          ],
        ],
      );
    }
    // The mocks' two-up row; without Apple, Google spans the row alone.
    return Row(
      children: [
        Expanded(child: google),
        if (apple != null) ...[
          const SizedBox(width: AppAuthLayout.socialGap),
          Expanded(child: apple),
        ],
      ],
    );
  }
}

/// The mocks' outline provider pill (`.btn.outline.on-dark`): a 1.5dp
/// boundary, the provider mark and a short label.
class _SocialPill extends StatelessWidget {
  const _SocialPill({
    required this.label,
    required this.semanticsLabel,
    required this.onPressed,
    required this.mark,
  });

  final String label;
  final String semanticsLabel;
  final VoidCallback? onPressed;
  final Widget mark;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: semanticsLabel,
      onTap: onPressed,
      excludeSemantics: true,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(AppAuthLayout.socialHeight),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          foregroundColor: colors.onSurface,
          side: BorderSide(color: colors.outline, width: 1.5),
          shape: const StadiumBorder(),
          textStyle: theme.textTheme.labelLarge,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox.square(
              dimension: AppAuthLayout.socialMarkSize,
              child: mark,
            ),
            const SizedBox(width: AppSpacing.smd),
            Flexible(child: Text(label, textAlign: TextAlign.center)),
          ],
        ),
      ),
    );
  }
}

/// The reference's four Google SVG paths, translated to native Canvas paths.
class _GoogleMark extends CustomPainter {
  const _GoogleMark();
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    final paint = Paint();
    canvas.drawPath(
      Path()
        ..moveTo(21.6, 12.23)
        ..relativeCubicTo(0, -.71, -.06, -1.39, -.18, -2.05)
        ..lineTo(12, 10.18)
        ..relativeLineTo(0, 3.88)
        ..relativeLineTo(5.38, 0)
        ..relativeArcToPoint(
          const Offset(-1.99, 3.02),
          radius: const Radius.circular(4.6),
        )
        ..relativeLineTo(0, 2.52)
        ..relativeLineTo(3.23, 0)
        ..relativeCubicTo(1.89, -1.74, 2.98, -4.3, 2.98, -7.37)
        ..close(),
      paint..color = AppAuthPalette.googleBlue,
    );
    canvas.drawPath(
      Path()
        ..moveTo(12, 22)
        ..relativeCubicTo(2.7, 0, 4.96, -.9, 6.62, -2.4)
        ..relativeLineTo(-3.23, -2.52)
        ..relativeCubicTo(-.9, .6, -2.05, .97, -3.39, .97)
        ..relativeCubicTo(-2.6, 0, -4.8, -1.76, -5.59, -4.12)
        ..lineTo(3.07, 13.93)
        ..relativeLineTo(0, 2.6)
        ..arcToPoint(
          const Offset(12, 22),
          radius: const Radius.circular(10),
          clockwise: false,
        )
        ..close(),
      paint..color = AppAuthPalette.googleGreen,
    );
    canvas.drawPath(
      Path()
        ..moveTo(6.41, 13.93)
        ..relativeArcToPoint(
          const Offset(0, -3.86),
          radius: const Radius.circular(6),
        )
        ..relativeLineTo(0, -2.6)
        ..lineTo(3.07, 7.47)
        ..relativeArcToPoint(
          const Offset(0, 9.06),
          radius: const Radius.circular(10),
          clockwise: false,
        )
        ..relativeLineTo(3.34, -2.6)
        ..close(),
      paint..color = AppAuthPalette.googleYellow,
    );
    canvas.drawPath(
      Path()
        ..moveTo(12, 5.95)
        ..relativeCubicTo(1.47, 0, 2.79, .5, 3.83, 1.5)
        ..lineTo(18.7, 4.6)
        ..arcToPoint(
          const Offset(12, 2),
          radius: const Radius.circular(9.6),
          clockwise: false,
        )
        ..relativeArcToPoint(
          const Offset(-8.93, 5.47),
          radius: const Radius.circular(10),
          clockwise: false,
        )
        ..relativeLineTo(3.34, 2.6)
        ..arcToPoint(
          const Offset(12, 5.95),
          radius: const Radius.circular(5.98),
        )
        ..close(),
      paint..color = AppAuthPalette.googleRed,
    );
  }

  @override
  bool shouldRepaint(_GoogleMark oldDelegate) => false;
}
