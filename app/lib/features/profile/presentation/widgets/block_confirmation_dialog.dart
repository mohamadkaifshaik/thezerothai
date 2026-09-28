import 'package:flutter/material.dart';

/// Confirms a block before it happens (ADR-0008 D9: irreversible follow-edge
/// removal, and the target won't be able to follow back or see the profile
/// until unblocked). Returns `true` only if the user tapped "Block".
Future<bool> showBlockConfirmationDialog(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Block this account?'),
      content: const Text(
        "They won't be able to follow you or see your profile, and "
        "you'll unfollow each other.",
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Block'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
