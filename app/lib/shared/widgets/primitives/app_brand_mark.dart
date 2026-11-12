import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// The DZEROTH icon with its teal halo and brand shadow (the splash and
/// welcome mocks). Decorative: the wordmark beside it names the app.
class AppBrandMark extends StatelessWidget {
  const AppBrandMark({super.key, required this.size, required this.radius});

  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          BoxShadow(
            color: context.appColors.accentText.withValues(alpha: .08),
            spreadRadius: AppAuthLayout.splashLogoHalo,
          ),
          ...AppShadows.brand,
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Image.asset(
          'assets/branding/icon.png',
          width: size,
          height: size,
        ),
      ),
    ),
  );
}
