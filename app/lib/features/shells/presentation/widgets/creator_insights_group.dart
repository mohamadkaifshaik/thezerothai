import 'package:flutter/material.dart';

import '../../../../shared/widgets/app_status_pill.dart';
import '../../../../shared/widgets/settings_group.dart';

/// The "Insights" group of Creator tools: four static rows, each with the
/// "Coming soon" pill and no number (not even 0 or a dash). Insights v1
/// replaces this widget and nothing else on the page.
class CreatorInsightsGroup extends StatelessWidget {
  const CreatorInsightsGroup({super.key});

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
    return SettingsGroup(
      title: title,
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
