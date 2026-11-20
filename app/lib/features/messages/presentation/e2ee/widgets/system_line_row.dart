import 'package:material_ui/material_ui.dart';

import '../../../../../core/theme/app_theme.dart';
import '../../../domain/e2ee/encrypted_messaging.dart';
import '../../widgets/message_bubble.dart' show kBubbleMaxWidthFraction;
import '../encryption_copy.dart';

/// The words of a system line. A missing side on a device line reads as
/// unattributed. A `deviceAdded` line on the caller's own side is the
/// own-device alert, never a quiet line; it reads as the alert's title here only
/// so no value is left without text.
String systemLineText(SystemLineEntry line, String peerName) {
  return switch (line.kind) {
    SystemLineKind.encryptionReset => kLineEncryptionReset,
    SystemLineKind.deviceAdded => switch (line.side) {
      LineSide.mine => kOwnDeviceAlertTitle,
      LineSide.theirs => lineDeviceAddedTheirs(peerName),
      LineSide.unattributed || null => kLineUnknownDevice,
    },
    SystemLineKind.deviceRemoved => switch (line.side) {
      LineSide.mine => kLineDeviceRemovedMine,
      LineSide.theirs => lineDeviceRemovedTheirs(peerName),
      LineSide.unattributed || null => kLineUnknownDeviceRemoved,
    },
    SystemLineKind.unknownDevice => kLineUnknownDevice,
  };
}

/// Whether the line is the warning kind (an unknown device was added).
bool systemLineIsWarning(SystemLineEntry line) => switch (line.kind) {
  SystemLineKind.unknownDevice => true,
  SystemLineKind.deviceAdded => switch (line.side) {
    LineSide.mine || LineSide.theirs => false,
    LineSide.unattributed || null => true,
  },
  SystemLineKind.encryptionReset || SystemLineKind.deviceRemoved => false,
};

/// A centred, quiet line in an encrypted thread: `bodySmall` in
/// `onSurfaceVariant`, with a small lock before the reset line and the warning
/// icon and error colour for an unknown device. One semantics node read as plain
/// text. Wraps at any text scale; at most the bubble column's width from the
/// tablet width up.
class SystemLineRow extends StatelessWidget {
  const SystemLineRow({super.key, required this.line, required this.peerName});

  final SystemLineEntry line;
  final String peerName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final text = systemLineText(line, peerName);
    final warning = systemLineIsWarning(line);
    final color = warning ? colors.error : colors.onSurfaceVariant;
    final icon = warning
        ? Icons.warning_amber_rounded
        : line.kind == SystemLineKind.encryptionReset
        ? Icons.lock_outline
        : null;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide =
              MediaQuery.sizeOf(context).width >= AppBreakpoints.mobile;
          return Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: wide
                    ? constraints.maxWidth * kBubbleMaxWidthFraction
                    : constraints.maxWidth,
              ),
              child: Semantics(
                container: true,
                excludeSemantics: true,
                label: text,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (icon != null) ...[
                      Padding(
                        padding: const EdgeInsets.only(top: AppSpacing.xs / 2),
                        child: Icon(
                          icon,
                          size: AppMessagesLayout.lineIcon,
                          color: color,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.xs),
                    ],
                    Flexible(
                      child: Text(
                        text,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: color,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
