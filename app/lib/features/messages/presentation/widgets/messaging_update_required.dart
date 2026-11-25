import 'package:material_ui/material_ui.dart';

import '../../../../core/page_reload.dart';
import '../../../../core/theme/app_theme.dart';
import '../messaging_update_copy.dart';

/// What Messages shows, in place of the inbox, when `messaging` is off for this
/// build only because the build is older than the server's floor
/// (`GetMe.features_needing_update`; plan 6, section 3.2).
///
/// One prompt per platform ([MessagingUpdateKind]):
/// - Android: "Update the app to keep messaging" with an Update button when
///   [onUpdate] is given. No store link is known to the app yet, so the shell
///   passes none and the button is left out (no invented URL).
/// - Web: "A new version is available" with Reload ([onReload], by default a
///   real page reload).
/// - iOS: "Messages aren't available on iPhone yet", no action.
///
/// Three looks, one content: centred on a phone (< 600dp), a bordered card on
/// the tablet (600-1199dp), a wider card on the desktop (>= 1200dp).
class MessagingUpdateRequired extends StatelessWidget {
  const MessagingUpdateRequired({
    super.key,
    this.kind,
    this.onUpdate,
    this.onReload,
  });

  /// The look to show; null follows the running platform.
  final MessagingUpdateKind? kind;

  /// Opens the store listing (Android). Null leaves the button out.
  final VoidCallback? onUpdate;

  /// Reloads the page (web). Null reloads the real page.
  final VoidCallback? onReload;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final kind = this.kind ?? messagingUpdateKindFor();
    final width = MediaQuery.sizeOf(context).width;
    final phone = width < AppBreakpoints.mobile;
    final desktop = width >= AppBreakpoints.tablet;
    final body = messagingUpdateBody(kind);
    final label = messagingUpdateActionLabel(kind);
    final VoidCallback? action = switch (kind) {
      MessagingUpdateKind.android => onUpdate,
      MessagingUpdateKind.web => onReload ?? reloadPage,
      MessagingUpdateKind.ios => null,
    };
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ExcludeSemantics(
          child: Icon(
            kind == MessagingUpdateKind.ios
                ? Icons.phone_iphone
                : Icons.system_update_alt,
            size: phone ? AppSpacing.xxl : AppIconSize.xl,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          messagingUpdateTitle(kind),
          style: desktop
              ? theme.textTheme.headlineSmall
              : theme.textTheme.titleLarge,
          textAlign: TextAlign.center,
        ),
        if (body != null) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            body,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ],
        if (label != null && action != null) ...[
          const SizedBox(height: AppSpacing.lg),
          FilledButton(onPressed: action, child: Text(label)),
        ],
      ],
    );
    final Widget framed = phone
        ? Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.xxl,
            ),
            child: content,
          )
        : ConstrainedBox(
            constraints: BoxConstraints(maxWidth: desktop ? 520 : 440),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadius.card),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: Padding(
                padding: EdgeInsets.all(
                  desktop ? AppSpacing.xl : AppSpacing.lg,
                ),
                child: content,
              ),
            ),
          );
    return Center(child: SingleChildScrollView(child: framed));
  }
}
