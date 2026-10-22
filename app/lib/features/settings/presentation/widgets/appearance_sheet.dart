import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/theme/theme_mode_cubit.dart';

/// The bottom sheet of Settings > Appearance: System default, Light, Dark.
/// The choice applies at once and is saved on the device (0 RPCs).
class AppearanceSheet extends StatelessWidget {
  const AppearanceSheet({super.key});

  /// Opens the sheet; it reads the [ThemeModeCubit] of [context].
  static Future<void> show(BuildContext context) {
    final cubit = context.read<ThemeModeCubit>();
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => BlocProvider<ThemeModeCubit>.value(
        value: cubit,
        child: const AppearanceSheet(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final current = context.select((ThemeModeCubit cubit) => cubit.state);
    final theme = Theme.of(context);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              0,
              AppSpacing.md,
              AppSpacing.sm,
            ),
            child: Semantics(
              header: true,
              child: Text('Appearance', style: theme.textTheme.titleLarge),
            ),
          ),
          for (final mode in ThemeMode.values)
            Semantics(
              button: true,
              selected: mode == current,
              inMutuallyExclusiveGroup: true,
              label: themeModeLabel(mode),
              excludeSemantics: true,
              onTap: () => _select(context, mode),
              child: ListTile(
                minTileHeight: AppSpacing.minTapTarget,
                title: Text(themeModeLabel(mode)),
                trailing: mode == current
                    ? Icon(Icons.check, color: theme.colorScheme.primary)
                    : null,
                onTap: () => _select(context, mode),
              ),
            ),
        ],
      ),
    );
  }

  static void _select(BuildContext context, ThemeMode mode) {
    context.read<ThemeModeCubit>().select(mode);
    Navigator.of(context).pop();
  }
}
