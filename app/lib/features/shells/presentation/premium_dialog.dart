import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/app_empty_view.dart';

/// The Premium shell (`/premium`, a shell of plan W8): a modal dialog over the
/// current page, reached only by `push`. Full screen below 600 dp; a centred
/// card at most 600 dp wide from 600 dp. The title and a Close button are its
/// only chrome; Escape, system Back and a tap on the barrier close it. No RPC.
/// W8-5 replaces the body; the frame stays.
class PremiumDialog extends StatelessWidget {
  const PremiumDialog({super.key});

  static const title = 'Premium';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.sm,
            AppSpacing.xs,
            AppSpacing.sm,
          ),
          child: Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleLarge,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        const Flexible(
          child: SingleChildScrollView(
            child: AppEmptyView(
              icon: Icons.workspace_premium_outlined,
              title: 'Coming soon',
            ),
          ),
        ),
      ],
    );
    if (MediaQuery.sizeOf(context).width < AppBreakpoints.mobile) {
      return Dialog.fullscreen(child: SafeArea(child: body));
    }
    return Dialog(
      insetPadding: const EdgeInsets.all(AppSpacing.lg),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: AppLayout.mainColumnMaxWidth,
        ),
        child: body,
      ),
    );
  }
}

/// The page of the Premium route: a barrier-dismissible dialog on the root
/// navigator, so the page underneath (and its selected tab) stays as it was.
class PremiumDialogPage extends Page<void> {
  const PremiumDialogPage({super.key});

  @override
  Route<void> createRoute(BuildContext context) {
    return DialogRoute<void>(
      context: context,
      settings: this,
      barrierDismissible: true,
      barrierLabel: 'Close',
      builder: (context) => const PremiumDialog(),
    );
  }
}
