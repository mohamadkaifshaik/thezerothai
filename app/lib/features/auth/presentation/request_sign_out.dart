import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/session_wiring.dart' show UnexpectedErrorReporter;
import '../../../core/theme/app_theme.dart';
import '../../../core/vault/vault_status.dart';
import '../../../core/widgets/tablet_modal.dart';
import '../../../shared/widgets/primitives/app_dialog.dart';
import '../../messages/domain/e2ee/encryption_device.dart';
import '../../messages/presentation/e2ee/encryption_copy.dart';
import '../../posts/data/drafts_repository.dart';
import '../../posts/presentation/widgets/draft_dialogs.dart';
import 'bloc/auth_bloc.dart';
import 'bloc/auth_event.dart';

/// The snackbar when "Delete them" failed: the user stays signed in, so the
/// failure is never silent (a sign-out clears every snackbar anyway).
const kSignOutDeleteFailed =
    "Couldn't delete your unsent posts. You're still signed in.";

/// Whether a sign-out is being decided for this [AuthBloc] (the count is read,
/// the dialog is up), so a second tap cannot open a second dialog. Keyed by the
/// bloc, not a global flag, so an abandoned dialog never blocks another app.
final Expando<bool> _deciding = Expando<bool>('requestSignOut');

/// Whether this device keeps an encrypted vault that a sign-out deletes: a
/// device is provided, the platform supports a vault and one is known to
/// exist. Any failure to read the fact is "no": a sign-out is never blocked
/// by bookkeeping. Nothing is logged.
bool _hasVaultToLose(BuildContext context) {
  try {
    final device = context.read<EncryptionDevice>();
    return device.vaultStatus.value != VaultStatus.unsupported &&
        device.vaultKnown;
  } catch (_) {
    return false;
  }
}

/// The one way every "Sign out" button leaves the account (security
/// L-5).
///
/// - Nobody signed in, no `DraftsRepository` in the tree, no unsent posts for
///   this uid, or a storage failure while counting them: signs out at once,
///   as before. A sign-out is never blocked by bookkeeping.
/// - Unsent posts on this device (whatever the `drafts` flag says: the rows are
///   what is readable on a shared computer): [showSignOutDraftsDialog]. "Keep"
///   signs out and keeps them, "Delete them" deletes this uid's rows first and
///   then signs out, "Cancel" or a dismissed dialog leaves the user signed in.
///   If the delete fails the user stays signed in with
///   [kSignOutDeleteFailed].
/// - An `EncryptionDevice` in the tree on a supported platform with a vault
///   known on this device (whatever the `e2ee_dm` flag says): first an alert
///   that signing out deletes the encrypted messages kept here. Cancel or
///   dismiss leaves the user signed in; confirm continues as above. The wipe
///   itself stays in session teardown.
///
/// Everything the flow needs is read from [context] before the first `await`:
/// the drawer closes itself before it calls this, so the row's own context is
/// gone by the time the dialog opens, and the dialog uses the root navigator.
/// 0 RPCs; nothing about a draft is logged.
Future<void> requestSignOut(BuildContext context) async {
  final auth = context.read<AuthBloc>();
  final uid = auth.state.user?.uid;
  final drafts = context.read<DraftsRepository?>();
  // Every request carries the uid it was expressed for (captured here,
  // before any await), so a user switch meanwhile never wipes the other
  // account's vault.
  if (uid == null || uid.isEmpty) {
    auth.add(AuthSignOutRequested(uid: uid));
    return;
  }
  // Read before the first await; false when there is no device, no vault, an
  // unsupported platform or any failure to read it.
  final warnVault = _hasVaultToLose(context);
  if (drafts == null && !warnVault) {
    auth.add(AuthSignOutRequested(uid: uid));
    return;
  }
  if (_deciding[auth] ?? false) return;
  _deciding[auth] = true;
  final navigator = Navigator.of(context, rootNavigator: true);
  // Where the dialog sits on the tablet layout is decided here, from the
  // button (a shell page or the rail: beside the rail); the navigator's own
  // context below knows nothing of the shell.
  final host = TabletModalHost.of(context);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final report = context.read<UnexpectedErrorReporter?>();
  try {
    if (warnVault) {
      var confirmed = true;
      try {
        if (!navigator.mounted) return;
        confirmed =
            await showAppDialog<bool>(
              context: navigator.context,
              host: host,
              destructive: true,
              maxWidth: AppSize.alertDialogMax,
              builder: (_) => const AppConfirmDialog(
                title: kSignOutVaultTitle,
                message: kSignOutVaultMessage,
                confirmLabel: kSignOutVaultLabel,
                destructive: true,
              ),
            ) ??
            false;
      } catch (_, stack) {
        // A dialog that cannot open never makes sign-out impossible.
        report?.call(StateError('Sign-out warning could not be shown.'), stack);
        confirmed = true;
      }
      if (!confirmed) return;
    }
    if (drafts == null) {
      auth.add(AuthSignOutRequested(uid: uid));
      return;
    }
    int count;
    try {
      count = await drafts.count(uid);
    } catch (_, stack) {
      // Without details: a storage error can carry a draft's text.
      report?.call(StateError('Unsent posts could not be counted.'), stack);
      count = 0;
    }
    if (count == 0) {
      auth.add(AuthSignOutRequested(uid: uid));
      return;
    }
    if (!navigator.mounted) return;
    final choice = await showSignOutDraftsDialog(navigator.context, host: host);
    if (choice == null) return;
    if (choice == SignOutDraftsChoice.delete) {
      try {
        await drafts.deleteAll(uid);
      } catch (_, stack) {
        report?.call(StateError('Unsent posts could not be deleted.'), stack);
        messenger
          ?..clearSnackBars()
          ..showSnackBar(const SnackBar(content: Text(kSignOutDeleteFailed)));
        return;
      }
    }
    auth.add(AuthSignOutRequested(uid: uid));
  } finally {
    _deciding[auth] = false;
  }
}
