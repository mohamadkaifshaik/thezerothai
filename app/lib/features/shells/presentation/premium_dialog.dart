import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/app_status_pill.dart';
import '../../../shared/widgets/app_surface.dart';
import '../domain/premium_plans.dart';

/// The Premium shell (`/premium`, a shell of plan W8): a modal dialog over the
/// current page, reached only by `push`. Full screen below 600 dp; a centred
/// card at most 600 dp wide from 600 dp. The title and a Close button are its
/// only chrome; Escape, system Back and a tap on the barrier close it. No RPC.
/// W8-5: the body is the coming-soon hero and two static plan cards
/// (ADR-0026 D3); nothing in it can be bought, reserved or followed.
class PremiumDialog extends StatelessWidget {
  const PremiumDialog({super.key});

  static const title = 'Premium';
  static const titleKey = ValueKey('premium-dialog-title');

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
                child: Focus(
                  autofocus: true,
                  child: Semantics(
                    header: true,
                    child: Text(
                      title,
                      key: titleKey,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleLarge,
                    ),
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
        const Flexible(child: SingleChildScrollView(child: _PremiumBody())),
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

/// The hero, the two static plan cards and the footer. Nothing here is
/// tappable and no price comes from anywhere but [kPremiumPlans].
class _PremiumBody extends StatelessWidget {
  const _PremiumBody();

  static const heroTitle = 'Premium is coming soon';
  static const heroSubtitle =
      'Optional paid plans to help cover running costs. Nothing is for sale '
      'yet, and your account works the same either way.';
  static const footer = 'No payment details are asked for anywhere in the app.';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    final sideBySide =
        media.size.width >= AppBreakpoints.mobile &&
        media.textScaler.scale(1) < 2;
    final cards = [for (final plan in kPremiumPlans) _PlanCard(plan: plan)];
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: AppSpacing.sm),
          Center(
            child: ExcludeSemantics(
              child: Container(
                width: AppSpacing.xxl + AppSpacing.md,
                height: AppSpacing.xxl + AppSpacing.md,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: theme.colorScheme.surfaceContainerHigh,
                ),
                child: Icon(
                  Icons.workspace_premium_outlined,
                  size: AppSpacing.xl,
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            heroTitle,
            style: theme.textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            heroSubtitle,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.lg),
          if (sideBySide)
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: cards[0]),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(child: cards[1]),
                ],
              ),
            )
          else ...[
            cards[0],
            const SizedBox(height: AppSpacing.md),
            cards[1],
          ],
          const SizedBox(height: AppSpacing.lg),
          Text(
            footer,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

/// One plan: name, price, "incl. GST" and a "Coming soon" pill. One semantics
/// node ("Plus, ₹235 a month including GST, coming soon"); not a button.
class _PlanCard extends StatelessWidget {
  const _PlanCard({required this.plan});

  final PremiumPlan plan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      label: '${plan.name}, ${plan.spokenPrice} including GST, coming soon',
      child: ExcludeSemantics(
        child: AppSurface(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(plan.name, style: theme.textTheme.titleMedium),
              const SizedBox(height: AppSpacing.sm),
              Text(plan.priceLabel, style: theme.textTheme.headlineSmall),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'incl. GST',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AppSpacing.smd),
              const AppStatusPill(label: 'Coming soon'),
            ],
          ),
        ),
      ),
    );
  }
}
