import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/session_wiring.dart' show UnexpectedErrorReporter;
import '../../../core/feature_flags/device_sign_out_feature_flag.dart';
import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/vault/vault_status.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../core/widgets/shell_bottom_inset_sliver.dart';
import '../../../core/widgets/shell_geometry.dart';
import '../../../shared/widgets/primitives/app_alert_confirm.dart';
import '../../../shared/widgets/primitives/app_dialog.dart';
import '../../../shared/widgets/primitives/app_pill_button.dart';
import '../../../shared/widgets/primitives/app_section_header.dart';
import '../../../shared/widgets/primitives/headline_message.dart';
import '../../../shared/widgets/primitives/settings_group.dart';
import '../../messages/domain/e2ee/encrypted_messaging.dart';
import '../../messages/domain/e2ee/encryption_access.dart';
import '../../messages/presentation/e2ee/connected_encryption_status_card.dart';
import '../../messages/presentation/e2ee/encryption_access_builder.dart';
import '../../messages/presentation/e2ee/encryption_copy.dart';
import '../../messages/presentation/e2ee/encryption_status.dart';
import '../../messages/presentation/e2ee/widgets/claim_headline.dart';
import '../../auth/data/auth_repository.dart';
import 'bloc/encryption_devices_cubit.dart';
import 'settings_up.dart';
import 'widgets/confirm_its_you.dart';
import 'widgets/own_device_row.dart';
import 'widgets/parked_removals_banner.dart';

/// Settings > Encrypted messages (`/settings/encryption`): the status card, this device, the other devices with
/// Remove, the removal progress and the About lines (R4, R17, K5).
///
/// With access `hidden` or `unsupported` (also a typed URL) it shows the "not available" headline and makes no call.
/// The device list is loaded only while the vault on this device is ready and the device was not removed elsewhere
/// (the pipeline has stopped then): with the vault in any other state only the card and About are shown. The status
/// comes from the nearest [EncryptionStatusCubit]; without one (no wiring) only About shows.
class EncryptionSettingsScreen extends StatelessWidget {
  const EncryptionSettingsScreen({super.key, this.now});

  /// The clock of "Last active ...", injectable for tests.
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: settingsUpButton(
          context,
          settingsUpLocation(AppRouter.encryptionSettingsPath),
        ),
        title: const Text(kEncryptionSettingsTitle),
      ),
      body: SafeArea(
        bottom: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: ShellGeometry.readableMaxWidth(context),
            ),
            child: EncryptionAccessBuilder(
              builder: (context, access) => switch (access) {
                EncryptionAccess.full ||
                EncryptionAccess.manage => _EncryptionPage(now: now),
                EncryptionAccess.hidden ||
                EncryptionAccess.unsupported => ListView(
                  padding:
                      const EdgeInsets.all(AppSpacing.md) +
                      shellBottomInsets(context),
                  children: const [
                    HeadlineMessage(
                      title: kEncryptionSettingsUnavailableTitle,
                      body: kEncryptionSettingsUnavailableBody,
                    ),
                  ],
                ),
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _EncryptionPage extends StatelessWidget {
  const _EncryptionPage({this.now});

  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) {
    final cubit = context.watch<EncryptionStatusCubit?>();
    final port = context.read<EncryptedMessaging?>();
    return ListView(
      padding:
          const EdgeInsets.only(top: AppSpacing.md, bottom: AppSpacing.lg) +
          shellBottomInsets(context),
      children: [
        if (cubit != null)
          BlocBuilder<EncryptionStatusCubit, EncryptionStatus>(
            bloc: cubit,
            builder: (context, status) {
              final hasCard =
                  status.kind != EncryptionStatusKind.none ||
                  status.historyLost;
              // The pipeline has stopped when the device was removed
              // elsewhere, and a vault that is not open has no device facts.
              final devices =
                  port != null &&
                  status.vault == VaultStatus.ready &&
                  status.kind != EncryptionStatusKind.removedElsewhere;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (hasCard)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(
                        AppSpacing.md,
                        0,
                        AppSpacing.md,
                        AppSpacing.md,
                      ),
                      // This page is the manage screen: its action stays out;
                      // Reset opens the reset screen.
                      child: ConnectedEncryptionStatusCard(
                        showManageDevices: false,
                      ),
                    ),
                  if (devices) _DevicesSection(port: port, now: now),
                ],
              );
            },
          ),
        const _AboutGroup(),
      ],
    );
  }
}

class _DevicesSection extends StatelessWidget {
  const _DevicesSection({required this.port, this.now});

  final EncryptedMessaging port;
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) {
    return BlocProvider<EncryptionDevicesCubit>(
      create: (context) => EncryptionDevicesCubit(
        messaging: port,
        onUnexpectedError: context.read<UnexpectedErrorReporter?>(),
        // Fix round 1, R2 / round 2, F1: a true answer is checked before
        // anything is shown, through the auth bloc (it records the remover's
        // reason first). Read when needed (a Remove tap reads the same
        // repository), so a page opened without one still builds; a failed
        // read is an unknown answer (the screen then signs out as the
        // server said).
        checkSignIn: () {
          final auth = context.read<AuthRepository>();
          final uid = auth.currentUser?.uid;
          return uid == null
              ? Future.value(SignInProbe.unknown)
              : auth.checkOwnRemoval(uid);
        },
      )..load(),
      child: _DevicesView(port: port, now: now ?? DateTime.now),
    );
  }
}

/// The parked-removals banner: drawn while the port says a removal waits for
/// a re-sign-in ([EncryptedMessaging.needsReauth]), whatever `device_sign_out`
/// says. The refs are only counted, never shown. The actions are off while a
/// removal or a sign-in runs.
class _ParkedRemovals extends StatelessWidget {
  const _ParkedRemovals({
    required this.port,
    required this.cubit,
    required this.onConfirm,
    required this.onDrop,
  });

  final EncryptedMessaging port;
  final EncryptionDevicesCubit cubit;
  final VoidCallback onConfirm;
  final void Function(int count) onDrop;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([port.needsReauth, port.parkedRemovals]),
      builder: (context, _) {
        final count = port.parkedRemovals.value.length;
        if (!port.needsReauth.value || count == 0) {
          return const SizedBox.shrink();
        }
        return BlocBuilder<EncryptionDevicesCubit, EncryptionDevicesState>(
          bloc: cubit,
          buildWhen: (a, b) =>
              (a.removing != null || a.confirming) !=
              (b.removing != null || b.confirming),
          builder: (context, state) {
            final busy = state.removing != null || state.confirming;
            return ParkedRemovalsBanner(
              count: count,
              onConfirm: busy ? null : onConfirm,
              onDrop: busy ? null : () => onDrop(count),
            );
          },
        );
      },
    );
  }
}

class _DevicesView extends StatelessWidget {
  const _DevicesView({required this.port, required this.now});

  final EncryptedMessaging port;
  final DateTime Function() now;

  Future<void> _remove(
    BuildContext context,
    EncryptionDevicesCubit cubit,
    OwnDevice device,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final status = context.read<EncryptionStatusCubit?>();
    // Lane D PR 4, fix round ruling 1: every Remove here is a REMOTE removal
    // of another device (this device has no Remove: signing out removes it),
    // and the server wants a recent sign-in for every REMOTE removal (H1),
    // whatever the flags. So EVERY tap asks for a re-sign-in before anything
    // is sent, in full and manage access alike. The repository is read
    // non-null: a missing provider is a programming error and fails loudly,
    // never a promptless send. device_sign_out (the removal also signs out
    // the other sessions) only changes the copy.
    final signOut = featureEnabledSnapshot(context, kFeatureDeviceSignOut);
    final auth = context.read<AuthRepository>();
    // The account the removal is for (read before any await): only it is
    // signed out when the removal ends every session.
    final uid = auth.currentUser?.uid;
    final added = device.addedAt;
    final confirmed = await showAppAlertConfirm(
      context,
      title: signOut
          ? deviceRemoveTitleNamed(
              added == null ? null : DateFormat.yMMMd().format(added.toLocal()),
            )
          : kDeviceRemoveTitle,
      message: signOut ? kDeviceRemoveSignOutMessage : kDeviceRemoveMessage,
      confirmLabel: kDeviceRemoveAction,
      destructive: true,
    );
    if (!confirmed || !context.mounted) return;
    // Registering this device again is only asked for at the 5-device limit
    // (read now, after the dialog), never from `manage` access.
    final atLimit =
        status?.state.kind == EncryptionStatusKind.deviceLimitReached;
    Future<bool> Function() confirm(bool again) =>
        () => context.mounted
        ? confirmItsYou(context, auth, again: again)
        : Future.value(false);
    var outcome = await cubit.remove(
      device.ref,
      retrySetup: atLimit,
      confirmItsYou: confirm(false),
    );
    // REAUTH_REQUIRED: the call missed the sign-in window and the removal
    // waits. The same prompt is asked once more; on success the removal is
    // sent again at once (the queue's parked intent for the same id).
    if (outcome == RemoveOutcome.needsReauth && context.mounted) {
      outcome = await cubit.remove(
        device.ref,
        retrySetup: atLimit,
        confirmItsYou: confirm(true),
        // Fix round 2, F2: the same user action.
        continued: true,
      );
    }
    await _finish(
      context.mounted ? context : null,
      messenger,
      cubit,
      outcome,
      auth: auth,
      uid: uid,
    );
  }

  /// After a removal run. Remover copy (controller ruling 2026-11-27, H1
  /// options a + b): when any answer said `other_sessions_ended`, H1 revoked
  /// every sign-in of the account, normally this device's too. Fix round 1,
  /// R2 / round 2, F1: the cubit has already checked this device's sign-in
  /// through the auth bloc (the remover's reason recorded first, then one
  /// forced refresh), under the row's spinner, BEFORE anything is shown:
  /// - alive, and only when a check actually ran (F2): the snackbar
  ///   [kDeviceRemovedSessionsEnded] ("Your other devices were signed out"),
  ///   no sign-out;
  /// - dead, unknown, or no check ran: the user first reads
  ///   [kDeviceRemovedThisDeviceToo] in a one-action dialog, then this
  ///   device signs out on purpose (the report carries the check's answer,
  ///   so the bloc signs out at once without a second probe; it probes only
  ///   when no check ran), instead of failing at a token refresh within the
  ///   hour. If the session already ended during the check (the SDK signed
  ///   out on its own), no dialog is shown: the sign-in screen's remover
  ///   notice explains it.
  /// Why a dialog and not the snackbar: the sign-out leaves this screen at
  /// once, so a snackbar would be read (if at all) on the sign-in screen
  /// beside its notice; the dialog keeps the order "result, then sign-out"
  /// with one tap. Closing it with the action or the system back signs out
  /// (the barrier and Escape do not close it: `barrierDismissible: false`),
  /// and so does a screen that is gone by the time the answer came.
  ///
  /// The sign-out follows the server's answer and the probe, not the
  /// `device_sign_out` snapshot: a true answer is a cut the server made,
  /// whatever this client read. With no session ended the snackbar is as
  /// before.
  Future<void> _finish(
    BuildContext? context,
    ScaffoldMessengerState messenger,
    EncryptionDevicesCubit cubit,
    RemoveOutcome outcome, {
    required AuthRepository auth,
    required String? uid,
  }) async {
    if (cubit.sessionsEnded && cubit.probed == SignInProbe.alive) {
      // A check ran and found this sign-in alive: only the others were
      // signed out (F2: never assumed without a check).
      if (!messenger.mounted) return;
      if (outcome == RemoveOutcome.removed) {
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(content: Text(kDeviceRemovedSessionsEnded)),
          );
      } else {
        _sayOutcome(messenger, cubit, outcome, signOutOn: false);
      }
      return;
    }
    if (cubit.thisSignInEnded && uid != null) {
      final probed = cubit.probed;
      if (outcome == RemoveOutcome.removed &&
          context != null &&
          context.mounted &&
          auth.currentUser?.uid == uid) {
        messenger.hideCurrentSnackBar();
        // Fix round 1, m2 / round 2, F4: reported once, when the dialog
        // closes OR when its content leaves the tree without closing (a
        // navigator disposed under it never completes its future).
        var reported = false;
        void report() {
          if (reported) return;
          reported = true;
          auth.reportRemovalSignedOutAll(uid, probed: probed);
        }

        await _showSignedOutAll(context, onGone: report);
        report();
        return;
      }
      // No dialog: the screen is gone or the session already ended (the
      // sign-in notice explains), or the run failed after an earlier
      // removal ended the sessions. The sign-out comes first, so nothing
      // below can keep a revoked session in.
      auth.reportRemovalSignedOutAll(uid, probed: probed);
      if (outcome != RemoveOutcome.removed && messenger.mounted) {
        _sayOutcome(messenger, cubit, outcome, signOutOn: false);
      }
      return;
    }
    _sayOutcome(
      messenger,
      cubit,
      outcome,
      signOutOn:
          context != null &&
          context.mounted &&
          featureEnabledSnapshot(context, kFeatureDeviceSignOut),
    );
  }

  /// The removed result when this sign-in ended too: one action, not
  /// dismissible by the barrier or Escape; resolves when it closes. [onGone]
  /// runs when its content leaves the tree, also when the navigator is
  /// disposed under it (its future then never completes).
  Future<void> _showSignedOutAll(
    BuildContext context, {
    required VoidCallback onGone,
  }) => showAppDialog<void>(
    context: context,
    barrierDismissible: false,
    maxWidth: AppSize.alertDialogMax,
    builder: (dialogContext) => _OnGone(
      onGone: onGone,
      child: AppDialog(
        title: kDeviceRemovedSignInAgainTitle,
        body: const Text(kDeviceRemovedThisDeviceToo),
        actions: [
          AppPillButton(
            label: kDeviceRemovedSignInAgainAction,
            autofocus: true,
            onPressed: () => Navigator.of(dialogContext).pop(),
          ),
        ],
      ),
    ),
  );

  /// The banner's "Confirm it's you": the removals REAUTH_REQUIRED parked are
  /// sent only after a fresh re-sign-in (review gate G2: the cubit runs
  /// `confirmItsYou` before any `removeDevice`). Missing the window again asks
  /// once more, as a Remove tap does.
  Future<void> _resumeParked(
    BuildContext context,
    EncryptionDevicesCubit cubit,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final auth = context.read<AuthRepository>();
    final uid = auth.currentUser?.uid;
    Future<bool> Function() confirm(bool again) =>
        () => context.mounted
        ? confirmItsYou(context, auth, again: again)
        : Future.value(false);
    var outcome = await cubit.resumeParked(confirmItsYou: confirm(false));
    if (outcome == RemoveOutcome.needsReauth && context.mounted) {
      // Fix round 2, F2: the same user action keeps a true answer the first
      // run got before its REAUTH_REQUIRED.
      outcome = await cubit.resumeParked(
        confirmItsYou: confirm(true),
        continued: true,
      );
    }
    await _finish(
      context.mounted ? context : null,
      messenger,
      cubit,
      outcome,
      auth: auth,
      uid: uid,
    );
  }

  /// The banner's "Don't remove": asks first, in words that say the device
  /// stays, then drops every parked removal (no call to the server).
  Future<void> _dropParked(
    BuildContext context,
    EncryptionDevicesCubit cubit,
    int count,
  ) async {
    final confirmed = await showAppAlertConfirm(
      context,
      title: parkedRemovalDropTitle(count),
      message: parkedRemovalDropMessage(count),
      confirmLabel: kParkedRemovalDropAction,
      destructive: true,
    );
    if (!confirmed || !context.mounted) return;
    await cubit.dropParked();
  }

  /// The snackbar for a finished removal; nothing when none was attempted or
  /// the user did not confirm it was them.
  void _sayOutcome(
    ScaffoldMessengerState messenger,
    EncryptionDevicesCubit cubit,
    RemoveOutcome outcome, {
    required bool signOutOn,
  }) {
    // Nothing was attempted (a removal was already running) or the user did
    // not confirm it was them: nothing to say.
    if (outcome == RemoveOutcome.notAttempted ||
        outcome == RemoveOutcome.cancelled) {
      return;
    }
    // `other_sessions_ended` keys the text only with `device_sign_out` on,
    // read now (the flag may have changed while the removal ran); a null
    // answer, or the flag off, gives the plain text that claims nothing about
    // the other sessions.
    // With several removals in one run the answer is a summary: no
    // per-device claim, the plain text. A true answer never reaches this
    // snackbar any more ([_finish] shows the sign-out dialog instead).
    final ended = signOutOn && cubit.removedCount == 1
        ? cubit.otherSessionsEnded
        : null;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(switch (outcome) {
            RemoveOutcome.removed => deviceRemovedText(
              otherSessionsEnded: ended,
            ),
            // N5: still outside the sign-in window after the second
            // "Confirm it's you": about the sign-in, not conversations.
            RemoveOutcome.needsReauth => kDeviceRemoveReauthFailedText,
            _ => kDeviceRemoveFailedText,
          }),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<EncryptionDevicesCubit>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ParkedRemovals(
          port: port,
          cubit: cubit,
          onConfirm: () => unawaited(_resumeParked(context, cubit)),
          onDrop: (count) => unawaited(_dropParked(context, cubit, count)),
        ),
        _devices(context, cubit),
      ],
    );
  }

  Widget _devices(BuildContext context, EncryptionDevicesCubit cubit) {
    return BlocBuilder<EncryptionDevicesCubit, EncryptionDevicesState>(
      builder: (context, state) {
        final list = state.list;
        if (state.status == EncryptionDevicesStatus.failed) {
          return AppErrorView(
            error: state.error ?? const UnknownApiException(''),
            onRetry: cubit.load,
          );
        }
        if (list == null) {
          return const SettingsGroupPlaceholder(
            rows: 2,
            semanticsLabel: kDevicesLoading,
          );
        }
        final at = now();
        final thisDevice = list.devices.where((d) => d.thisDevice).firstOrNull;
        final others = [
          for (final d in list.devices)
            if (!d.thisDevice) d,
        ];
        final listed = list.devices.where((d) => d.inDirectory).length;
        final theme = Theme.of(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!list.directoryKnown)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  0,
                  AppSpacing.md,
                  AppSpacing.md,
                ),
                child: Row(
                  children: [
                    Expanded(
                      // The port cannot say why the list was not read
                      // (offline or a server failure), so no offline note.
                      child: Text(
                        kDevicesLoadFailed,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: cubit.load,
                      child: const Text(kStatusTryAgain),
                    ),
                  ],
                ),
              ),
            const AppSectionHeader(title: kDevicesThisHeader),
            SettingsGroup(
              rows: [
                OwnDeviceRow(
                  device:
                      thisDevice ??
                      const OwnDevice(
                        ref: '',
                        thisDevice: true,
                        inDirectory: false,
                      ),
                  now: at,
                  directoryKnown: list.directoryKnown,
                ),
              ],
            ),
            Row(
              children: [
                const Expanded(
                  child: AppSectionHeader(title: kDevicesOthersHeader),
                ),
                if (list.directoryKnown)
                  // Flexible: at a large text size the count wraps instead
                  // of pushing the row past the edge.
                  Flexible(
                    child: Padding(
                      padding: const EdgeInsetsDirectional.only(
                        end: AppSpacing.md,
                      ),
                      child: Text(
                        devicesCount(listed),
                        textAlign: TextAlign.end,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            SettingsGroup(
              rows: [
                if (others.isEmpty)
                  const SettingsRow(
                    icon: Icons.devices_other_outlined,
                    title: kDevicesNoOthers,
                  )
                else
                  for (final d in others)
                    OwnDeviceRow(
                      device: d,
                      now: at,
                      directoryKnown: list.directoryKnown,
                      removing: state.removing == d.ref,
                      // No Remove while the directory is unread, while any
                      // removal runs, or while a removal's "Confirm it's
                      // you" is open (N7: never a tap that does nothing).
                      onRemove:
                          d.inDirectory &&
                              list.directoryKnown &&
                              state.removing == null &&
                              !state.confirming
                          ? () => _remove(context, cubit, d)
                          : null,
                    ),
              ],
            ),
            if (others.isNotEmpty &&
                isFeatureEnabled(context, kFeatureDeviceSignOut))
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  0,
                  AppSpacing.md,
                  AppSpacing.md,
                ),
                child: Text(
                  kDevicesUnrecognisedFooter,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            if (state.removalsPending > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  0,
                  AppSpacing.md,
                  AppSpacing.md,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        removalsPendingText(state.removalsPending),
                        style: theme.textTheme.bodyLarge,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      kRemovalsNote,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class _AboutGroup extends StatelessWidget {
  const _AboutGroup();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lines = encryptionHelpLines(web: kIsWeb);
    // Plan 6 Task 4.A: the claim headline with its "What this covers" link
    // leads the group only while `claimVisible` holds; otherwise the group
    // is exactly today's lines.
    return ClaimVisibilityBuilder(
      builder: (context, claim) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const AppSectionHeader(title: kDevicesAboutHeader),
          SettingsGroup(
            rows: [
              if (claim)
                const Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.xs,
                  ),
                  child: ClaimHeadlineBody(),
                ),
              for (final line in lines)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.sm,
                  ),
                  child: Text(line, style: theme.textTheme.bodyMedium),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Runs [onGone] when it leaves the tree (fix round 1, m2). Fix round 2, F4:
/// a pageless route removed with its page is normally completed, so the
/// dialog's future resolves; only a navigator that is disposed under it
/// leaves that future incomplete, and this covers that case. A rebuild (a
/// resize, a rotation) keeps the same state, so it never runs then.
class _OnGone extends StatefulWidget {
  const _OnGone({required this.onGone, required this.child});

  final VoidCallback onGone;
  final Widget child;

  @override
  State<_OnGone> createState() => _OnGoneState();
}

class _OnGoneState extends State<_OnGone> {
  @override
  void dispose() {
    widget.onGone();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
