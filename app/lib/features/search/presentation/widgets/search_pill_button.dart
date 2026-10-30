import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';

/// The pill-shaped "Search" entry of Explore's header and of the desktop side
/// column (W4-17/18): a 1dp outlined, fully rounded button with a search icon
/// and the grey placeholder. It is a button that opens the search page, not a
/// text field; W4-14's field replaces it once it is on main. Grows with the
/// text scale; never shorter than the 48dp tap target.
class SearchPillButton extends StatelessWidget {
  const SearchPillButton({super.key, required this.onTap});

  final VoidCallback onTap;

  /// The pill's height at text scale [scaler]: the 48dp target, or the text
  /// line plus padding when the user scaled the text up.
  static double heightFor(TextScaler scaler) {
    final line = scaler.scale(AppSpacing.lg + AppSpacing.xs);
    final padded = line + 2 * AppSpacing.sm;
    return padded < AppSpacing.minTapTarget ? AppSpacing.minTapTarget : padded;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Semantics(
      button: true,
      label: 'Search',
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Ink(
            height: heightFor(MediaQuery.textScalerOf(context)),
            decoration: ShapeDecoration(
              shape: StadiumBorder(
                side: BorderSide(color: colors.outlineVariant),
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Row(
              children: [
                Icon(
                  Icons.search,
                  size: AppSpacing.lg - AppSpacing.xs,
                  color: colors.onSurfaceVariant,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    'Search',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
