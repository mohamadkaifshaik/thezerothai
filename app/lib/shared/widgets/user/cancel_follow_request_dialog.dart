import 'package:flutter/material.dart';

/// Asks "Cancel your follow request?" before a REQUESTED follow is withdrawn
/// (ADR-0025 D7: Unfollow of a REQUESTED target withdraws it; there is no undo,
/// the person can ask again). Returns `true` only if the user chose to cancel.
Future<bool> showCancelFollowRequestDialog(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Cancel your follow request?'),
      content: const Text(
        "They won't see your request anymore. You can send a new one later.",
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Keep request'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Cancel request'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
