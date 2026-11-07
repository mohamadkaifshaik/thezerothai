import '../../../../core/theme/app_theme.dart' show AppAuthPalette;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../../app/app_config.dart';
import 'auth_design.dart';

/// Google + Apple sign-in buttons. Apple is only shown on iOS, macOS and web
/// per Apple's guidelines. There is no phone/SMS sign-in.
class SocialSignInButtons extends StatelessWidget {
  const SocialSignInButtons({
    super.key,
    required this.isSubmitting,
    required this.onGoogleTap,
    required this.onAppleTap,
  });

  final bool isSubmitting;
  final VoidCallback onGoogleTap;
  final VoidCallback onAppleTap;

  /// Web needs an Apple Services ID (`APPLE_SERVICE_ID`), otherwise the button
  /// can only fail. Checked before the platform because on web
  /// `defaultTargetPlatform` reports the browser's OS (macOS/iOS on Apple devices).
  bool get _showApple {
    if (kIsWeb) return AppConfig.appleSignInOnWebConfigured;
    return defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AuthActionButton(
          onPressed: isSubmitting ? null : onGoogleTap,
          icon: const SizedBox(
            width: 19,
            height: 19,
            child: CustomPaint(painter: _GoogleMark()),
          ),
          label: 'Continue with Google',
        ),
        if (_showApple) ...[
          const SizedBox(height: 12),
          AuthActionButton(
            onPressed: isSubmitting ? null : onAppleTap,
            icon: const Icon(Icons.apple, size: 19),
            label: 'Continue with Apple',
          ),
        ],
      ],
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
