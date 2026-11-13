import 'package:flutter/material.dart';

import '../../../../shared/widgets/primitives/app_alert_confirm.dart';

/// Confirms a block before it happens (irreversible follow-edge
/// removal, and the target won't be able to follow back or see the profile
/// until unblocked). Returns `true` only if the user tapped "Block".
///
/// A destructive `AppConfirmDialog`: Cancel takes the initial focus, so Enter
/// never blocks.
Future<bool> showBlockConfirmationDialog(BuildContext context) {
  return showAppAlertConfirm(
    context,
    title: 'Block this account?',
    message:
        "They won't be able to follow you or see your profile, and "
        "you'll unfollow each other.",
    confirmLabel: 'Block',
    destructive: true,
  );
}
