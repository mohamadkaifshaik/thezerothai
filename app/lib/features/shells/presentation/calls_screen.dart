import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../shared/widgets/app_back_header.dart';
import '../../../shared/widgets/app_empty_view.dart';
import '../../../shared/widgets/app_main_column.dart';
import '../../../shared/widgets/app_status_pill.dart';
import '../../../shared/widgets/settings_group.dart';

/// Calls (`/calls`, a shell of plan W8): says calls are coming soon. No RPC,
/// no repository, no permission and no calling package; the rows are static.
class CallsScreen extends StatelessWidget {
  const CallsScreen({super.key});

  static const title = 'Calls';

  @override
  Widget build(BuildContext context) {
    return AppMainColumn(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppBackHeader(
            title: title,
            onBack: () => context.canPop()
                ? context.pop()
                : context.go(AppRouter.homePath),
          ),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const AppEmptyView(
                    icon: Icons.call_outlined,
                    title: 'Calls are coming soon',
                    subtitle:
                        "Voice and video calls aren't available yet. You can "
                        'still reach people by replying to or mentioning them.',
                  ),
                  SettingsGroup(
                    title: 'Calls',
                    rows: const [
                      SettingsRow(
                        icon: Icons.call_outlined,
                        title: 'Voice calls',
                        value: AppStatusPill(label: 'Coming soon'),
                      ),
                      SettingsRow(
                        icon: Icons.videocam_outlined,
                        title: 'Video calls',
                        value: AppStatusPill(label: 'Coming soon'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
