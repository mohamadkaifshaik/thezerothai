import 'package:flutter/material.dart';

/// Asks a password-account user for their password so the app can
/// re-authenticate before a sensitive account call. Returns null when the
/// user dismisses it (the account cubit treats that as "cancelled": nothing
/// is sent). Plug it into `AccountCubit`'s `PasswordPrompt`.
Future<String?> showPasswordPromptDialog(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (_) => const _PasswordPromptDialog(),
  );
}

class _PasswordPromptDialog extends StatefulWidget {
  const _PasswordPromptDialog();

  @override
  State<_PasswordPromptDialog> createState() => _PasswordPromptDialogState();
}

class _PasswordPromptDialogState extends State<_PasswordPromptDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text;
    Navigator.of(context).pop(value.isEmpty ? null : value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Confirm it is you'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        obscureText: true,
        autofillHints: const [AutofillHints.password],
        decoration: const InputDecoration(labelText: 'Password'),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Continue')),
      ],
    );
  }
}
