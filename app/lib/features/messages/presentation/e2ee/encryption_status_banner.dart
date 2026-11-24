import 'package:material_ui/material_ui.dart';

import '../../../../shared/widgets/primitives/app_notice_banner.dart';
import 'encryption_copy.dart';
import 'encryption_status.dart';
import 'encryption_status_card.dart';

/// One line with an optional action, for the inbox and an encrypted thread. Nothing for kind none, dormant
/// (Settings only) and setupFailed (Settings only). The action is [kStatusDetails] (opens the Settings page) for
/// every kind, and [kStatusDismiss] for the history-lost line, which is drawn above the kind's line. The banner
/// knows no route: a null callback omits its action. Each line is an `AppNoticeBanner` with its opt-in
/// `actionLabel` (same margins, border and live region).
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
        AppNoticeBanner(
          message: kStatusHistoryLostTitle,
          actionLabel: onDismissHistoryLost == null ? null : kStatusDismiss,
          onAction: onDismissHistoryLost,
        ),
      if (_showsKind)
        AppNoticeBanner(
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
