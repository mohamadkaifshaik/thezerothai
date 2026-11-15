import 'package:flutter/material.dart';

import '../../../../core/feature_flags/feature_flags.dart';
import '../../../../shared/widgets/primitives/app_status_pill.dart';
import '../../../../shared/widgets/primitives/settings_group.dart';
import '../../../creator_insights/domain/creator_insights_feature_flag.dart';
import '../../../creator_insights/presentation/widgets/insights_panel.dart';

/// The "Insights" group of Creator Studio. With `creator_insights` on it is
/// the live [InsightsPanel] (tiles, sparklines, top posts). With it off it is
/// the static rows, each with the "Coming soon" pill and no number (not even
/// 0 or a dash), and no repository is read.
class CreatorInsightsGroup extends StatelessWidget {
  const CreatorInsightsGroup({super.key, required this.style});

  final SettingsGroupStyle style;

  static const title = 'Insights';
  static const comingSoon = 'Coming soon';

  static const _rows = <(IconData, String)>[
    (Icons.visibility_outlined, 'Impressions'),
    (Icons.touch_app_outlined, 'Engagements'),
    (Icons.account_circle_outlined, 'Profile visits'),
    (Icons.trending_up, 'Top posts'),
  ];

  @override
  Widget build(BuildContext context) {
    if (isFeatureEnabled(context, kFeatureCreatorInsights)) {
      return InsightsPanel(style: style);
    }
    return SettingsGroup(
      title: title,
      style: style,
      rows: [
        for (final (icon, label) in _rows)
          SettingsRow(
            key: ValueKey('creator-insight-$label'),
            icon: icon,
            title: label,
            value: const AppStatusPill(label: comingSoon),
          ),
      ],
    );
  }
}
