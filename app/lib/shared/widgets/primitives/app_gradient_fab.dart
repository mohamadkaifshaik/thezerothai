import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// The floating action button of the redesigned phone screens: a 58dp circle
/// with the primary gradient and its glow (the compose button above the
/// floating bar, Messages' New message).
class AppGradientFab extends StatelessWidget {
  const AppGradientFab({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.appColors;
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: const CircleBorder(),
        gradient: colors.primaryFillGradient,
        shadows: AppShadows.primaryGlow,
      ),
      child: Theme(
        data: theme.copyWith(
          floatingActionButtonTheme: theme.floatingActionButtonTheme.copyWith(
            backgroundColor: Colors.transparent,
            foregroundColor: colors.primaryFillLabel,
            sizeConstraints: const BoxConstraints.tightFor(
              width: AppSize.fabRedesign,
              height: AppSize.fabRedesign,
            ),
          ),
        ),
        child: FloatingActionButton(
          tooltip: tooltip,
          onPressed: onPressed,
          child: Icon(icon),
        ),
      ),
    );
  }
}
