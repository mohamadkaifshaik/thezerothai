import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// The tone of an [AppStatusPill].
enum AppStatusTone {
  /// Raised-surface fill, muted label (the default).
  neutral,

  /// Page-colour fill with an accent hairline and `accentText` label.
  info,
}

/// A small full-round status label ("Coming soon"): about 22dp tall, a short
/// [label], tokens only. Both tones meet 4.5:1 in light and dark.
///
/// The pill has no semantics of its own ([ExcludeSemantics]): the row or card
/// that shows it must put [label] in its own spoken label (see
/// `SettingsRow.value`). It scales with the text size, so its height is a
/// minimum, never a fixed box.
class AppStatusPill extends StatelessWidget {
  const AppStatusPill({
    super.key,
    required this.label,
    this.tone = AppStatusTone.neutral,
  });

  final String label;
  final AppStatusTone tone;

  /// Minimum pill height (dp).
  static const double height = 22;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.appColors;
    final isInfo = tone == AppStatusTone.info;
    final fill = isInfo
        ? theme.colorScheme.surface
        : theme.colorScheme.surfaceContainerHigh;
    final labelColor = isInfo ? colors.accentText : colors.secondaryOnRaised;
    return ExcludeSemantics(
      child: Container(
        constraints: const BoxConstraints(minHeight: height),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.xs / 2,
        ),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: fill,
          border: isInfo ? Border.all(color: labelColor) : null,
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        child: Text(
          label,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelMedium?.copyWith(color: labelColor),
        ),
      ),
    );
  }
}
