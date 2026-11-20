import 'package:material_ui/material_ui.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/primitives/app_pill_button.dart';
import 'encryption_copy.dart';
import 'encryption_status.dart';
import 'encryption_status_card.dart';

/// One line with an optional action, for the inbox and an encrypted thread. Nothing for kind none, dormant
/// (Settings only) and setupFailed (Settings only). The action is [kStatusDetails] (opens the Settings page) for
/// every kind, and [kStatusDismiss] for the history-lost line, which is drawn above the kind's line. The banner
/// knows no route: a null callback omits its action. It uses the margins and live region of `AppNoticeBanner`,
/// which cannot carry another label.
class EncryptionStatusBanner extends StatelessWidget {
  const EncryptionStatusBanner({
    super.key,
    required this.status,
    this.onDetails,
    this.onDismissHistoryLost,
  });

  final EncryptionStatus status;
  final VoidCallback? onDetails;
  final VoidCallback? onDismissHistoryLost;

  bool get _showsKind => switch (status.kind) {
    EncryptionStatusKind.none ||
    EncryptionStatusKind.dormant ||
    EncryptionStatusKind.setupFailed => false,
    EncryptionStatusKind.opening ||
    EncryptionStatusKind.keyLostPending ||
    EncryptionStatusKind.storageChanged ||
    EncryptionStatusKind.unavailable ||
    EncryptionStatusKind.heldElsewhere ||
    EncryptionStatusKind.engineUnavailable ||
    EncryptionStatusKind.removedElsewhere ||
    EncryptionStatusKind.deviceLimitReached ||
    EncryptionStatusKind.deviceRecordUnusable ||
    EncryptionStatusKind.offline => true,
  };

  @override
  Widget build(BuildContext context) {
    final lines = <Widget>[
      if (status.historyLost)
        _Line(
          message: kStatusHistoryLostTitle,
          actionLabel: onDismissHistoryLost == null ? null : kStatusDismiss,
          onAction: onDismissHistoryLost,
        ),
      if (_showsKind)
        _Line(
          message:
              encryptionStatusTitle(status) ?? encryptionStatusBody(status)!,
          actionLabel: onDetails == null ? null : kStatusDetails,
          onAction: onDetails,
        ),
    ];
    if (lines.isEmpty) return const SizedBox.shrink();
    return Column(mainAxisSize: MainAxisSize.min, children: lines);
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.message, this.actionLabel, this.onAction});

  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    // A large text scale puts the action under the message, so the message
    // keeps the width (a long line would otherwise wrap into a thin column).
    final stacked = MediaQuery.textScalerOf(context).scale(1) >= 1.5;
    final text = Text(
      message,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: colors.onSurface,
        fontWeight: FontWeight.w600,
      ),
    );
    final action = actionLabel == null
        ? null
        : AppPillButton(
            label: actionLabel!,
            variant: AppButtonVariant.text,
            onPressed: onAction,
          );
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.all(AppSpacing.sm),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: context.appColors.uiBorder),
        ),
        padding: const EdgeInsetsDirectional.only(
          start: AppSpacing.md,
          end: AppSpacing.sm,
          top: AppSpacing.xs,
          bottom: AppSpacing.xs,
        ),
        child: stacked
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: AppSpacing.sm,
                    ),
                    child: text,
                  ),
                  if (action != null)
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: action,
                    ),
                ],
              )
            : Row(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: AppSpacing.sm,
                      ),
                      child: text,
                    ),
                  ),
                  ?action,
                ],
              ),
      ),
    );
  }
}
