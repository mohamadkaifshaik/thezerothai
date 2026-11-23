import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../shared/widgets/primitives/app_dialog.dart';
import '../../../account/presentation/widgets/password_prompt_dialog.dart';
import '../../../auth/data/auth_repository.dart';
import '../../../auth/domain/auth_failure.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../../messages/presentation/e2ee/encryption_copy.dart';

/// "Confirm it's you" before a REMOTE device removal (lane D PR 4, ruling 3;
/// removal design §4, "Task 11 queue"): the user signs in again, so the
/// removal call that follows is inside the server's recent-sign-in window.
///
/// Reuses the account-deletion re-auth path: [AuthRepository.reauthenticate]
/// (Google, Apple or password; it force-refreshes the ID token, so the next
/// call carries the new `auth_time`) and [showPasswordPromptDialog].
///
/// - A password account goes straight to the password prompt (it is the
///   "Confirm it's you" prompt; nothing opens a popup).
/// - Other accounts first see this prompt; its Continue starts the provider
///   sign-in inside the tap, so a web popup is not blocked.
///
/// [again]: the removal answered REAUTH_REQUIRED (it missed the window) and
/// the same prompt is asked again. True only when the sign-in succeeded; a
/// cancel is false; any other failure shows its text and is false.
Future<bool> confirmItsYou(
  BuildContext context,
  AuthRepository auth, {
  bool again = false,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final password =
      context.read<AuthBloc?>()?.state.user?.isPasswordProvider ?? false;

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

  if (password) return signIn();
  final started = await showAppMaterialDialog<Future<bool>>(
    context: context,
    builder: (_) => _ConfirmItsYouDialog(
      body: again ? kConfirmItsYouAgainBody : kConfirmItsYouBody,
      onContinue: signIn,
    ),
  );
  return started == null ? false : await started;
}

class _ConfirmItsYouDialog extends StatelessWidget {
  const _ConfirmItsYouDialog({required this.body, required this.onContinue});

  final String body;
  final Future<bool> Function() onContinue;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text(kConfirmItsYouTitle),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          // Started inside the tap (a web popup needs the gesture); the
          // dialog closes with the sign-in's future.
          onPressed: () => Navigator.of(context).pop(onContinue()),
          child: const Text(kConfirmItsYouAction),
        ),
      ],
    );
  }
}
