import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import 'app_dialog.dart';

/// [AppConfirmDialog] at the alert width ([AppSize.alertDialogMax], 400 dp),
/// like the other confirm dialogs: resolves to `true` only when confirmed.
///
/// [AppConfirmDialog.show] uses the general dialog width; a short yes/no
/// question stays at the alert width on tablets and desktops.
Future<bool> showAppAlertConfirm(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = false,
}) async {
  final confirmed = await showAppDialog<bool>(
    context: context,
    destructive: destructive,
    maxWidth: AppSize.alertDialogMax,
    builder: (_) => AppConfirmDialog(
      title: title,
      message: message,
      confirmLabel: confirmLabel,
      destructive: destructive,
    ),
  );
  return confirmed ?? false;
}
