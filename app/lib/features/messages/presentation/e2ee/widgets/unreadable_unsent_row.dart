import 'package:material_ui/material_ui.dart';

import '../../../../../core/theme/app_theme.dart';
import '../../../../../shared/widgets/primitives/app_pill_button.dart';
import '../encryption_copy.dart';

/// An own unsent message that no longer opens on this device (the port's
/// `unreadableUnsent`): its fixed text and the one action Delete. Nothing of
/// the message is known, so nothing of it is shown; the row knows no handle
/// (the screen's callback closes over it).
///
/// Capped to the same width as the thread's other cards (480 dp, centred on
/// desktop) and a live region, so it is announced when it appears.
class UnreadableUnsentRow extends StatelessWidget {
  const UnreadableUnsentRow({super.key, required this.onDelete});

  /// Null while a delete runs: the action shows disabled.
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final desktop = MediaQuery.sizeOf(context).width >= AppBreakpoints.tablet;
    final card = DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: colors.error),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(kUnsentUnreadableText, style: theme.textTheme.bodyMedium),
            const SizedBox(height: AppSpacing.sm),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: AppPillButton(
                label: kUnsentUnreadableDeleteAction,
                variant: AppButtonVariant.text,
                onPressed: onDelete,
              ),
            ),
          ],
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      child: Semantics(
        container: true,
        liveRegion: true,
        child: desktop
            ? Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: AppMessagesLayout.ownDeviceAlertMaxWidth,
                  ),
                  child: card,
                ),
              )
            : card,
      ),
    );
  }
}
