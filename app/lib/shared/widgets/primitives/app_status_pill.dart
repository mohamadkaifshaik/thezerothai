import 'package:flutter/material.dart';

import 'app_badge.dart';

/// The tone of an [AppStatusPill].
enum AppStatusTone {
  /// Raised-surface fill, muted label (the default).
  neutral,

  /// Accent label on a 14 % teal tint.
  info,
}

/// A small full-round status label ("Coming soon"): at least 24 dp tall, a
/// short [label], tokens only. It is an [AppTintBadge] (`neutral` / accent)
/// and both tones meet 4.5:1 in light and dark.
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
  static const double height = AppTintBadge.minHeight;

  @override
  Widget build(BuildContext context) {
    return AppTintBadge(
      label: label,
      tone: tone == AppStatusTone.info
          ? AppTintTone.accent
          : AppTintTone.neutral,
      excludeSemantics: true,
    );
  }
}
