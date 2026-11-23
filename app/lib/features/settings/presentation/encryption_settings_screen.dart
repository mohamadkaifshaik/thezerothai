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
import '../../../shared/widgets/primitives/app_section_header.dart';
import '../../../shared/widgets/primitives/headline_message.dart';
import '../../../shared/widgets/primitives/settings_group.dart';
import '../../messages/domain/e2ee/encrypted_messaging.dart';
import '../../messages/domain/e2ee/encryption_access.dart';
import '../../messages/presentation/e2ee/connected_encryption_status_card.dart';
import '../../messages/presentation/e2ee/encryption_access_builder.dart';
import '../../messages/presentation/e2ee/encryption_copy.dart';
import '../../messages/presentation/e2ee/encryption_status.dart';
import '../../auth/data/auth_repository.dart';
import 'bloc/encryption_devices_cubit.dart';
import 'settings_up.dart';
import 'widgets/confirm_its_you.dart';
import 'widgets/own_device_row.dart';

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
      )..load(),
      child: _DevicesView(now: now ?? DateTime.now),
    );
  }
}

class _DevicesView extends StatelessWidget {
  const _DevicesView({required this.now});

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
      );
    }
    // Nothing was attempted (a removal was already running) or the user did
    // not confirm it was them: nothing to say.
    if (outcome == RemoveOutcome.notAttempted ||
        outcome == RemoveOutcome.cancelled) {
      return;
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(switch (outcome) {
            // `other_sessions_ended` is not passed on by the port yet
            // (Task 13-ii): the plain text until it is.
            RemoveOutcome.removed => deviceRemovedText(),
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
    final lines = <String>[
      kEncryptionHelp1,
      kEncryptionHelp2,
      kEncryptionHelp3,
      if (kIsWeb) kEncryptionHelpWeb,
      kEncryptionHelp4,
      kEncryptionHelp5,
      kEncryptionHelp6,
      kEncryptionHelp7,
      kEncryptionHelp8,
      kEncryptionHelp9,
      kEncryptionHelp10,
      if (kIsWeb) kWebStorageNote,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const AppSectionHeader(title: kDevicesAboutHeader),
        SettingsGroup(
          rows: [
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
    );
  }
}
