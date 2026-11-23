import 'package:material_ui/material_ui.dart';

import '../../../../shared/widgets/primitives/app_dialog.dart';
import '../../../account/presentation/widgets/password_prompt_dialog.dart';
import '../../../auth/data/auth_repository.dart';
import '../../../auth/domain/auth_failure.dart';
import '../../../messages/presentation/e2ee/encryption_copy.dart';

/// "Confirm it's you" before a REMOTE device removal (lane D PR 4, ruling 3;
/// removal design §4, "Task 11 queue"): the user signs in again, so the
/// removal call that follows is inside the server's recent-sign-in window.
///
/// Reuses the account-deletion re-auth path: [AuthRepository.reauthenticate]
/// (Google, Apple or password; it force-refreshes the ID token, so the next
/// call carries the new `auth_time`) and [showPasswordPromptDialog].
///
/// - A password-only account ([AuthRepository.reauthUsesPassword]) goes
///   straight to the password prompt (it is the "Confirm it's you" prompt;
///   nothing opens a popup).
/// - Other accounts, a password linked next to Google or Apple included,
///   first see this prompt; its Continue starts the provider sign-in inside
///   the tap, so a web popup is not blocked.
///
/// [again]: the removal answered REAUTH_REQUIRED (it missed the window) and
/// the same prompt is asked again, with the "expired" text (a password
/// account too, before its password prompt). True only when the sign-in succeeded; a
/// cancel is false; any other failure shows its text and is false.
Future<bool> confirmItsYou(
  BuildContext context,
  AuthRepository auth, {
  bool again = false,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  // Fix round ruling 4: decided by reauthenticate's own provider order.
  final password = auth.reauthUsesPassword;

  Future<String?> promptPassword() => context.mounted
      ? showPasswordPromptDialog(context)
      : Future<String?>.value();

  Future<bool> signIn() async {
    try {
      await auth.reauthenticate(promptPassword: promptPassword);
      return true;
    } on AuthCancelled {
      return false;
    } on AuthFailure catch (failure) {
      if (failure.message.isNotEmpty) {
        messenger
          ?..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(failure.message)));
      }
      return false;
    }
  }

  // N6: asked again, a password account sees why (the expired text) before
  // its password prompt, like every other account.
  if (password && !again) return signIn();
  final started = await showAppMaterialDialog<Future<bool>>(
    context: context,
    builder: (_) => _ConfirmItsYouDialog(
      body: again ? kConfirmItsYouAgainBody : kConfirmItsYouBody,
      onContinue: signIn,
    ),
  );
  return started == null ? false : await started;
}

class _ConfirmItsYouDialog extends StatefulWidget {
  const _ConfirmItsYouDialog({required this.body, required this.onContinue});

  final String body;
  final Future<bool> Function() onContinue;

  @override
  State<_ConfirmItsYouDialog> createState() => _ConfirmItsYouDialogState();
}

class _ConfirmItsYouDialogState extends State<_ConfirmItsYouDialog> {
  /// SA Info: one sign-in per dialog, whatever the taps.
  bool _started = false;

  void _continue() {
    if (_started) return;
    _started = true;
    // Started inside the tap (a web popup needs the gesture); the dialog
    // closes with the sign-in's future.
    Navigator.of(context).pop(widget.onContinue());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text(kConfirmItsYouTitle),
      content: Text(widget.body),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _continue,
          child: const Text(kConfirmItsYouAction),
        ),
      ],
    );
  }
}
