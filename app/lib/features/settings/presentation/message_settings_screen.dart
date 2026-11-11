import 'package:flutter/material.dart';

import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/primitives/headline_message.dart';
import '../../../shared/widgets/primitives/settings_group.dart';
import '../../messages/presentation/widgets/messaging_access_builder.dart';
import '../../messages/domain/messaging_feature_gate.dart';
import '../domain/message_privacy.dart';
import 'message_settings_messages.dart';
import 'settings_up.dart';
import 'widgets/message_privacy_rows.dart';

/// Settings > Message settings (`/settings/messages`, also the Messages
/// gear): "Who can message you" (F9) and "Read receipts" (F3), each shown by
/// its own rule (flag, or the undo rule while it is set). With neither, a
/// "not available" line. 0 RPCs to open: the values are the server's answer
/// already in [MessagePrivacyScope]'s store.
class MessageSettingsScreen extends StatelessWidget {
  const MessageSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // The tablet layout with nothing to pop: up to Privacy & safety.
        leading: settingsUpButton(
          context,
          settingsUpLocation(AppRouter.messageSettingsPath),
        ),
        title: const Text(kMessageSettingsTitle),
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: AppBreakpoints.mobile),
            child: MessagePrivacyScope(
              child: MessagingAccessBuilder(
                builder: (context, access) => _body(context, access),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, MessagingAccess access) {
    final messagingOn = access == MessagingAccess.full;
    final visible = MessagePrivacyVisibility.of(
      context,
      messagingOn: messagingOn,
    );
    if (!visible.any) {
      return ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: const [
          HeadlineMessage(
            title: kMessageSettingsUnavailableTitle,
            body: kMessageSettingsUnavailableBody,
          ),
        ],
      );
    }
    final followingAllowed =
        messagingOn && isFeatureEnabled(context, kFeatureDmPolicy);
    return ListView(
      padding: EdgeInsets.only(
        top: AppSpacing.md,
        bottom: AppSpacing.lg + MediaQuery.paddingOf(context).bottom,
      ),
      children: [
        SettingsGroup(
          rows: [
            if (visible.whoCanMessage)
              WhoCanMessageRow(followingAllowed: followingAllowed),
            if (visible.readReceipts) const ReadReceiptsRow(),
          ],
        ),
      ],
    );
  }
}
