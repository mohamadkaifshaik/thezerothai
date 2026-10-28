import 'package:flutter/material.dart';

import '../../../../shared/widgets/app_status_pill.dart';
import '../../../../shared/widgets/settings_group.dart';

/// The "Programs" group of Creator tools: two static rows with the "Coming
/// soon" pill. Nothing to sign up for, so no button and no promise.
/// Monetisation replaces this widget and nothing else on the page.
class CreatorProgramsGroup extends StatelessWidget {
  const CreatorProgramsGroup({super.key});

  static const title = 'Programs';
  static const comingSoon = 'Coming soon';
  static const subtitle = 'Nothing to sign up for yet.';

  static const _rows = <(IconData, String)>[
    (Icons.payments_outlined, 'Earnings from posts'),
    (Icons.card_membership_outlined, 'Creator subscriptions'),
  ];

  @override
  Widget build(BuildContext context) {
    return SettingsGroup(
      title: title,
      rows: [
        for (final (icon, label) in _rows)
          SettingsRow(
            key: ValueKey('creator-program-$label'),
            icon: icon,
            title: label,
            subtitle: subtitle,
            value: const AppStatusPill(label: comingSoon),
          ),
      ],
    );
  }
}
