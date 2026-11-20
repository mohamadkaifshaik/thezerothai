import 'package:material_ui/material_ui.dart';

import '../../../../../core/theme/app_theme.dart';
import '../../../../../shared/widgets/primitives/app_pill_button.dart';
import '../encryption_copy.dart';

/// "A new device was added to your account": a full-width card inside the
/// thread column (capped at 480 dp and centred on desktop) with the one action
/// "Check your devices". A live region, so it is announced when it appears; its
/// title is a header.
class OwnDeviceAlert extends StatelessWidget {
  const OwnDeviceAlert({super.key, required this.onCheckDevices});

  final VoidCallback onCheckDevices;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final desktop = MediaQuery.sizeOf(context).width >= AppBreakpoints.tablet;
    final card = DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.warning_amber_rounded, color: colors.error),
            const SizedBox(width: AppSpacing.smd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    header: true,
                    child: Text(
                      kOwnDeviceAlertTitle,
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    kOwnDeviceAlertBody,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: AppPillButton(
                      label: kOwnDeviceAlertAction,
                      variant: AppButtonVariant.text,
                      onPressed: onCheckDevices,
                    ),
                  ),
                ],
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
