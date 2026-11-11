import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_router.dart';
import '../../../../core/widgets/app_top_bar.dart';
import '../notification_settings_messages.dart';
import '../notification_settings_screen.dart';

/// The gear in the Notifications header: opens Notification settings (F6).
/// Draws nothing unless `notifications` and `notification_prefs` are on.
class NotificationSettingsAction extends StatelessWidget {
  const NotificationSettingsAction({super.key});

  @override
  Widget build(BuildContext context) {
    if (!notificationPrefsEnabled(context)) return const SizedBox.shrink();
    return AppTopBarAction(
      icon: Icons.settings_outlined,
      tooltip: kNotificationSettingsTitle,
      onPressed: () => context.push(AppRouter.notificationSettingsPath),
    );
  }
}
