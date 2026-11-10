import 'package:flutter/material.dart';

import '../../../../shared/widgets/primitives/app_dialog.dart';

/// Asks before a plan form is closed with edits in it. True to discard.
/// Dismissing the dialog counts as "Keep editing".
Future<bool> confirmDiscardPlan(
  BuildContext context, {
  required String title,
  required String body,
}) async {
  final discard = await showAppMaterialDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Keep editing'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Discard'),
        ),
      ],
    ),
  );
  return discard == true;
}
