import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/feature_flags/feature_flags.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/widgets/app_top_bar.dart';
import '../../domain/message_privacy.dart';
import '../message_settings_messages.dart';

/// The gear in the Messages header: opens Message settings (F3, F9). Draws
/// nothing unless `read_receipts` or `dm_policy` is on for the caller (the
/// page itself also offers the undo of a setting whose flag went off, from
/// Settings > Privacy & safety).
class MessageSettingsAction extends StatelessWidget {
  const MessageSettingsAction({super.key});

  @override
  Widget build(BuildContext context) {
    final on =
        isFeatureEnabled(context, kFeatureReadReceipts) ||
        isFeatureEnabled(context, kFeatureDmPolicy);
    if (!on) return const SizedBox.shrink();
    return AppTopBarAction(
      icon: Icons.settings_outlined,
      tooltip: kMessageSettingsTitle,
      onPressed: () => context.push(AppRouter.messageSettingsPath),
    );
  }
}
