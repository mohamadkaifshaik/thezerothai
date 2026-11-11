import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/primitives/app_chip.dart';
import '../../../../shared/widgets/primitives/app_tile_icon.dart';

/// One option of a [SettingsChoiceRow].
class SettingsChoice<T> {
  const SettingsChoice(this.value, this.label);

  final T value;
  final String label;
}

/// A Settings row with its choices inline (the design's Appearance row): the
/// tile icon, the [title] and the current choice's label, then one pill per
/// choice. The pills wrap onto more lines when they do not fit (narrow
/// widths, large text), so a label never ellipsizes.
///
/// The pills are a group named [title]; each is a selected / not selected
/// button with a 48 dp hit area ([AppFilterPill]). [onSelected] null (a save
/// running) disables them. [selected] is what the pills show as chosen: for a
/// server setting, the server's value, never the one being saved.
class SettingsChoiceRow<T> extends StatelessWidget {
  const SettingsChoiceRow({
    super.key,
    required this.icon,
    required this.title,
    required this.choices,
    required this.selected,
    required this.onSelected,
    this.note,
  });

  final IconData icon;
  final String title;
  final List<SettingsChoice<T>> choices;
  final T selected;
  final ValueChanged<T>? onSelected;

  /// A line under the pills (what the choice does); null draws nothing.
  final String? note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    String labelOf(T value) => choices
        .firstWhere((c) => c.value == value, orElse: () => choices.first)
        .label;
    final onSelected = this.onSelected;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Spoken once: the pills below carry the choices and the selection.
          ExcludeSemantics(
            child: Row(
              children: [
                AppTileIcon(icon: icon, size: AppSpacing.xl + AppSpacing.sm),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: colors.onSurface,
                        ),
                      ),
                      Text(
                        labelOf(selected),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Semantics(
            container: true,
            label: title,
            explicitChildNodes: true,
            child: Wrap(
              spacing: AppSpacing.sm,
              children: [
                for (final choice in choices)
                  AppFilterPill(
                    label: choice.label,
                    selected: choice.value == selected,
                    // A choice is never cut: at large text it wraps.
                    maxLines: null,
                    onPressed: onSelected == null
                        ? null
                        : () => onSelected(choice.value),
                  ),
              ],
            ),
          ),
          if (note case final note?)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text(
                note,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
