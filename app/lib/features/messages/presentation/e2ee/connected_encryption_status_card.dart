import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../app/session_wiring.dart' show UnexpectedErrorReporter;
import '../../../../core/router/app_router.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/tablet_modal.dart';
import '../../../../shared/widgets/primitives/app_dialog.dart';
import '../../../auth/presentation/request_sign_out.dart';
import '../../domain/e2ee/encrypted_messaging.dart';
import 'encryption_copy.dart';
import 'encryption_status.dart';
import 'encryption_status_card.dart';

/// [EncryptionStatusCard] fed by the nearest [EncryptionStatusCubit], with every callback wired in this one place
/// so no screen wires them itself:
/// - Try again: the cubit's `retry` (busy while it runs);
/// - Check again / Set up again: the port's `checkRemovedAgain` / `setUpDeviceAgain`, one call in flight at a time,
///   a failure reported as a fixed `StateError('<step>')` and nothing shown beyond the card's own copy. Passed only
///   when a port exists; with a port, Check again is always wired (the card shows it on every removed-elsewhere
///   status);
/// - Sign out: `requestSignOut` (which carries the vault warning);
/// - Manage devices / Reset: `AppRouter.encryptionSettingsPath` / `resetEncryptionPath` through go_router, unless
///   hidden by [showManageDevices] / [showReset] (the Settings screen is itself the manage screen).
/// No cubit in the tree draws nothing.
class ConnectedEncryptionStatusCard extends StatefulWidget {
  const ConnectedEncryptionStatusCard({
    super.key,
    this.showManageDevices = true,
    this.showReset = true,
  });

  final bool showManageDevices;
  final bool showReset;

  @override
  State<ConnectedEncryptionStatusCard> createState() =>
      _ConnectedEncryptionStatusCardState();
}

class _ConnectedEncryptionStatusCardState
    extends State<ConnectedEncryptionStatusCard> {
  bool _retrying = false;
  bool _checking = false;
  bool _settingUp = false;

  Future<void> _retry(EncryptionStatusCubit cubit) async {
    if (_retrying) return;
    setState(() => _retrying = true);
    try {
      await cubit.retry();
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  /// Asks first (the device gets a new identity), then calls the port. One tap at a time: the guard covers the
  /// dialog and the call. A dialog that cannot be shown reports `StateError('setUpAgainConfirm')` and makes no
  /// call; the next tap asks again.
  Future<void> _setUpAgain() async {
    final port = context.read<EncryptedMessaging?>();
    if (port == null || _settingUp) return;
    final report = context.read<UnexpectedErrorReporter?>();
    _settingUp = true;
    try {
      bool confirmed;
      try {
        final host = TabletModalHost.of(context);
        final navigator = Navigator.of(context, rootNavigator: true);
        confirmed =
            await showAppDialog<bool>(
              context: navigator.context,
              host: host,
              destructive: true,
              maxWidth: AppSize.alertDialogMax,
              builder: (_) => const AppConfirmDialog(
                title: kSetUpAgainTitle,
                message: kSetUpAgainMessage,
                confirmLabel: kSetUpAgainAction,
                destructive: true,
              ),
            ) ??
            false;
      } catch (_, stack) {
        report?.call(StateError('setUpAgainConfirm'), stack);
        return;
      }
      if (!confirmed) return;
      try {
        await port.setUpDeviceAgain();
      } catch (_, stack) {
        report?.call(StateError('setUpDeviceAgain'), stack);
      }
    } finally {
      _settingUp = false;
    }
  }

  Future<void> _portCall(
    String step,
    Future<void> Function(EncryptedMessaging port) call,
    bool Function() inFlight,
    void Function(bool) setInFlight,
  ) async {
    final port = context.read<EncryptedMessaging?>();
    if (port == null || inFlight()) return;
    final report = context.read<UnexpectedErrorReporter?>();
    setInFlight(true);
    try {
      await call(port);
    } catch (_, stack) {
      report?.call(StateError(step), stack);
    } finally {
      setInFlight(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.watch<EncryptionStatusCubit?>();
    if (cubit == null) return const SizedBox.shrink();
    final port = context.read<EncryptedMessaging?>();
    return BlocBuilder<EncryptionStatusCubit, EncryptionStatus>(
      bloc: cubit,
      builder: (context, status) => EncryptionStatusCard(
        status: status,
        retrying: _retrying,
        onRetry: () => unawaited(_retry(cubit)),
        onReset: widget.showReset
            ? () => unawaited(context.push(AppRouter.resetEncryptionPath))
            : null,
        onManageDevices: widget.showManageDevices
            ? () => unawaited(context.push(AppRouter.encryptionSettingsPath))
            : null,
        onSetUpAgain: port == null ? null : () => unawaited(_setUpAgain()),
        onCheckAgain: port == null
            ? null
            : () => unawaited(
                _portCall(
                  'checkRemovedAgain',
                  (p) => p.checkRemovedAgain(),
                  () => _checking,
                  (v) => _checking = v,
                ),
              ),
        onSignOut: () => unawaited(requestSignOut(context)),
        onDismissHistoryLost: cubit.dismissHistoryLost,
      ),
    );
  }
}
