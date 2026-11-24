import 'package:material_ui/material_ui.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/primitives/app_pill_button.dart';
import '../../../messages/presentation/e2ee/encryption_copy.dart';

/// "A device removal is waiting": the removals the server asked a fresh
/// sign-in for (the port's `parkedRemovals`), with "Confirm it's you" and
/// "Don't remove". Knows no ref and no route: both actions are callbacks of
/// the page, which asks the user before it calls the port. A live region, so
/// it is announced when it appears. The actions sit under the text at every
/// width, so a long line keeps the whole width.
class ParkedRemovalsBanner extends StatelessWidget {
  const ParkedRemovalsBanner({
    super.key,
    required this.count,
    required this.onConfirm,
    required this.onDrop,
  });

  /// How many removals wait (at least one).
  final int count;

  /// Null while a removal or a sign-in is running: the actions show disabled.
  final VoidCallback? onConfirm;
  final VoidCallback? onDrop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final text = Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Text(
        parkedRemovalsText(count),
        style: theme.textTheme.bodyMedium?.copyWith(
          color: colors.onSurface,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
    final actions = Wrap(
      alignment: WrapAlignment.end,
      children: [
        AppPillButton(
          label: kParkedRemovalDropAction,
          variant: AppButtonVariant.text,
          onPressed: onDrop,
        ),
        AppPillButton(
          label: kConfirmItsYouTitle,
          variant: AppButtonVariant.text,
          onPressed: onConfirm,
        ),
      ],
    );
    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          0,
          AppSpacing.md,
          AppSpacing.md,
        ),
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            text,
            Align(alignment: AlignmentDirectional.centerEnd, child: actions),
          ],
        ),
      ),
    );
  }
}
