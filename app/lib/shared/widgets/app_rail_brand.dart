import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// The brand mark at the top of the navigation rail: the "Dzeroth" wordmark
/// when the rail is [extended] (labels visible), a single "D" when it is
/// collapsed. Text only, no asset; read once as a header, "Dzeroth".
class AppRailBrand extends StatelessWidget {
  const AppRailBrand({super.key, required this.extended});

  final bool extended;

  static const String name = 'Dzeroth';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      header: true,
      label: name,
      excludeSemantics: true,
      child: SizedBox(
        height: AppSpacing.minTapTarget,
        width: extended ? AppLayout.railExtendedWidth : null,
        child: Align(
          alignment: extended ? Alignment.centerLeft : Alignment.center,
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: extended ? AppSpacing.lg : 0,
            ),
            child: Text(
              extended ? name : name[0],
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleLarge?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
