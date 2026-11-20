import 'package:material_ui/material_ui.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/shell_geometry.dart';
import '../../../../shared/widgets/primitives/app_card.dart';
import '../../../../shared/widgets/primitives/app_pill_button.dart';
import 'encryption_copy.dart';
import 'encryption_status.dart';

/// The card title of [status]'s kind; null when the kind has no title line (a progress line or a one-line note).
String? encryptionStatusTitle(EncryptionStatus status) => switch (status.kind) {
  EncryptionStatusKind.none => null,
  EncryptionStatusKind.opening => null,
  EncryptionStatusKind.keyLostPending => kStatusKeyLostTitle,
  EncryptionStatusKind.storageChanged => kStatusStorageChangedTitle,
  EncryptionStatusKind.unavailable => kStatusUnavailableTitle,
  EncryptionStatusKind.heldElsewhere => kStatusHeldElsewhereTitle,
  EncryptionStatusKind.engineUnavailable => kStatusEngineUnavailableTitle,
  EncryptionStatusKind.removedElsewhere => kStatusRemovedTitle,
  EncryptionStatusKind.deviceLimitReached => kStatusDeviceLimitTitle,
  EncryptionStatusKind.deviceRecordUnusable => kStatusDeviceRecordTitle,
  EncryptionStatusKind.setupFailed => null,
  EncryptionStatusKind.dormant => null,
  EncryptionStatusKind.offline => null,
};

/// The card body of [status]'s kind (for a kind without a title this is its only line).
String? encryptionStatusBody(EncryptionStatus status) => switch (status.kind) {
  EncryptionStatusKind.none => null,
  EncryptionStatusKind.opening => kStatusOpeningText,
  EncryptionStatusKind.keyLostPending =>
    status.mayStart ? kStatusKeyLostBody : kStatusKeyLostBodyNoRestart,
  EncryptionStatusKind.storageChanged => kStatusStorageChangedBody,
  EncryptionStatusKind.unavailable =>
    status.unavailableLong
        ? kStatusUnavailableLongBody
        : kStatusUnavailableBody,
  EncryptionStatusKind.heldElsewhere => kStatusHeldElsewhereBody,
  EncryptionStatusKind.engineUnavailable => kStatusEngineUnavailableBody,
  EncryptionStatusKind.removedElsewhere =>
    status.mayStart ? kStatusRemovedBody : kStatusRemovedBodyNoRestart,
  EncryptionStatusKind.deviceLimitReached => kStatusDeviceLimitBody,
  EncryptionStatusKind.deviceRecordUnusable => kStatusDeviceRecordBody,
  EncryptionStatusKind.setupFailed => kStatusSetupFailedText,
  EncryptionStatusKind.dormant => kStatusDormantText,
  EncryptionStatusKind.offline => kStatusOfflineText,
};

/// Title, body and actions for the Settings page and the thread's blocked state. Knows no route and calls no port:
/// every action is a callback of the call site; a null callback omits its button. With `historyLost` the history
/// card is drawn above the kind's card.
class EncryptionStatusCard extends StatelessWidget {
  const EncryptionStatusCard({
    super.key,
    required this.status,
    this.onRetry,
    this.retrying = false,
    this.onReset,
    this.onManageDevices,
    this.onSetUpAgain,
    this.onCheckAgain,
    this.onSignOut,
    this.onDismissHistoryLost,
  });

  final EncryptionStatus status;
  final VoidCallback? onRetry;
  final bool retrying;
  final VoidCallback? onReset;
  final VoidCallback? onManageDevices;
  final VoidCallback? onSetUpAgain;
  final VoidCallback? onCheckAgain;
  final VoidCallback? onSignOut;
  final VoidCallback? onDismissHistoryLost;

  @override
  Widget build(BuildContext context) {
    final hasKind = status.kind != EncryptionStatusKind.none;
    if (!hasKind && !status.historyLost) return const SizedBox.shrink();
    final stack = MediaQuery.sizeOf(context).width < AppBreakpoints.mobile;
    final sections = <Widget>[
      if (status.historyLost)
        _Section(
          icon: Icons.history,
          title: kStatusHistoryLostTitle,
          body: kStatusHistoryLostBody,
          stack: stack,
          actions: [
            if (onDismissHistoryLost != null)
              AppPillButton(
                label: kStatusDismiss,
                variant: AppButtonVariant.text,
                onPressed: onDismissHistoryLost,
              ),
          ],
        ),
      if (hasKind)
        _Section(
          icon: status.kind == EncryptionStatusKind.opening
              ? Icons.hourglass_empty
              : status.blocksMessaging
              ? Icons.lock_outline
              : Icons.info_outline,
          title: encryptionStatusTitle(status),
          body: encryptionStatusBody(status)!,
          progress: status.kind == EncryptionStatusKind.opening,
          stack: stack,
          actions: _kindActions(),
        ),
    ];
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: ShellGeometry.readableMaxWidth(context),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < sections.length; i++) ...[
              if (i > 0) const SizedBox(height: AppSpacing.sm),
              sections[i],
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _kindActions() {
    Widget button(
      String label,
      VoidCallback? onPressed, {
      AppButtonVariant variant = AppButtonVariant.outline,
      bool busy = false,
    }) => AppPillButton(
      label: label,
      variant: variant,
      onPressed: onPressed,
      busy: busy,
    );
    return switch (status.kind) {
      EncryptionStatusKind.keyLostPending => [
        if (onRetry != null)
          button(
            kStatusTryAgain,
            onRetry,
            variant: AppButtonVariant.primary,
            busy: retrying,
          ),
        if (onReset != null) button(kStatusReset, onReset),
      ],
      EncryptionStatusKind.storageChanged ||
      EncryptionStatusKind.deviceRecordUnusable => [
        if (onReset != null) button(kStatusReset, onReset),
      ],
      EncryptionStatusKind.unavailable ||
      EncryptionStatusKind.heldElsewhere => [
        if (onRetry != null)
          button(
            kStatusTryAgain,
            onRetry,
            variant: AppButtonVariant.primary,
            busy: retrying,
          ),
      ],
      EncryptionStatusKind.removedElsewhere => [
        if (status.mayStart && onSetUpAgain != null)
          button(
            kSetUpAgainAction,
            onSetUpAgain,
            variant: AppButtonVariant.primary,
          ),
        if (onCheckAgain != null) button(kStatusCheckAgain, onCheckAgain),
        if (onSignOut != null) button(kSignOutVaultLabel, onSignOut),
      ],
      EncryptionStatusKind.deviceLimitReached => [
        if (onManageDevices != null)
          button(
            kStatusManageDevices,
            onManageDevices,
            variant: AppButtonVariant.primary,
          ),
      ],
      EncryptionStatusKind.none ||
      EncryptionStatusKind.opening ||
      EncryptionStatusKind.engineUnavailable ||
      EncryptionStatusKind.setupFailed ||
      EncryptionStatusKind.dormant ||
      EncryptionStatusKind.offline => const [],
    };
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.icon,
    required this.body,
    required this.actions,
    required this.stack,
    this.title,
    this.progress = false,
  });

  final IconData icon;
  final String? title;
  final String body;
  final List<Widget> actions;
  final bool stack;
  final bool progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurface;
    final bodyText = Text(
      body,
      style: theme.textTheme.bodyMedium?.copyWith(color: color),
    );
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExcludeSemantics(child: Icon(icon, size: 20, color: color)),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: title == null
                    ? Semantics(liveRegion: progress, child: bodyText)
                    : Semantics(
                        header: true,
                        child: Text(
                          title!,
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: color,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
              ),
            ],
          ),
          if (title != null) ...[
            const SizedBox(height: AppSpacing.sm),
            bodyText,
          ],
          if (actions.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            if (stack)
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < actions.length; i++) ...[
                    if (i > 0) const SizedBox(height: AppSpacing.sm),
                    actions[i],
                  ],
                ],
              )
            else
              Wrap(
                alignment: WrapAlignment.end,
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: actions,
              ),
          ],
        ],
      ),
    );
  }
}
