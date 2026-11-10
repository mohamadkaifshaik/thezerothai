import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/session_wiring.dart' show UnexpectedErrorReporter;
import '../../../core/widgets/tablet_modal.dart';
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
///
/// Everything the flow needs is read from [context] before the first `await`:
/// the drawer closes itself before it calls this, so the row's own context is
/// gone by the time the dialog opens, and the dialog uses the root navigator.
/// 0 RPCs; nothing about a draft is logged.
Future<void> requestSignOut(BuildContext context) async {
  final auth = context.read<AuthBloc>();
  final uid = auth.state.user?.uid;
  final drafts = context.read<DraftsRepository?>();
  if (uid == null || uid.isEmpty || drafts == null) {
    auth.add(const AuthSignOutRequested());
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
    int count;
    try {
      count = await drafts.count(uid);
    } catch (_, stack) {
      // Without details: a storage error can carry a draft's text.
      report?.call(StateError('Unsent posts could not be counted.'), stack);
      count = 0;
    }
    if (count == 0) {
      auth.add(const AuthSignOutRequested());
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
    auth.add(const AuthSignOutRequested());
  } finally {
    _deciding[auth] = false;
  }
}
