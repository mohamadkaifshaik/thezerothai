import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'bloc/subscription_cubit.dart';
import '../domain/subscription_models.dart';

import '../../../core/router/page_below.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/tablet_modal.dart';
import '../../../shared/widgets/primitives/app_accent_headline.dart';
import '../../../shared/widgets/primitives/app_status_pill.dart';
import '../../../shared/widgets/primitives/app_surface.dart';
import '../domain/premium_plans.dart';

/// The Premium shell (`/premium`, a shell of plan W8): a modal dialog over the
/// current page, reached only by `push`. Full screen below 600 dp; a centred
/// card at most 600 dp wide from 600 dp. The title and a Close button are its
/// only chrome; Escape, system Back and a tap on the barrier close it.
/// With billing configured, the body shows account status and server-gated
/// billing actions. Otherwise it retains the informational coming-soon cards.
///
/// On the tablet layout ([host], tablet plan section 4.1 "Premium") the card
/// is `min(600, C - 48)` wide and centred on the content area beside the
/// rail; the barrier still covers the whole window, rail included.
class PremiumDialog extends StatelessWidget {
  const PremiumDialog({super.key, this.host});

  /// The tablet presentation (`dialogPageHost`); null: today's.
  final TabletModalHost? host;

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
        Flexible(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (context.read<SubscriptionCubit?>() case final cubit?)
                  _SubscriptionActions(cubit: cubit),
                if (context.read<SubscriptionCubit?>() == null)
                  const _PremiumBody(),
              ],
            ),
          ),
        ),
      ],
    );
    if (MediaQuery.sizeOf(context).width < AppBreakpoints.mobile) {
      return Dialog.fullscreen(child: SafeArea(child: body));
    }
    return Dialog(
      insetPadding:
          host?.dialogInsets(context, maxWidth: AppLayout.mainColumnMaxWidth) ??
          const EdgeInsets.all(AppSpacing.lg),
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

class _SubscriptionActions extends StatelessWidget {
  const _SubscriptionActions({required this.cubit});
  final SubscriptionCubit cubit;

  @override
  Widget build(
    BuildContext context,
  ) => BlocBuilder<SubscriptionCubit, SubscriptionState>(
    bloc: cubit,
    builder: (context, state) {
      final busy =
          state.phase == SubscriptionPhase.purchasing ||
          state.phase == SubscriptionPhase.loading;
      final tier = state.access?.effectiveTier(DateTime.now());
      final native =
          !kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS);
      final canBuy =
          native &&
          state.phase == SubscriptionPhase.ready &&
          state.offerings.isNotEmpty &&
          state.access?.purchasesAvailable == true &&
          tier == SubscriptionTier.free;
      final message = switch (state.phase) {
        SubscriptionPhase.signedOut => 'Sign in to view your subscription.',
        SubscriptionPhase.loading => 'Loading subscription…',
        SubscriptionPhase.purchasing =>
          'Complete the subscription action in the store.',
        SubscriptionPhase.verifying =>
          'Checking your subscription. Refresh in a moment.',
        SubscriptionPhase.pending => 'Payment is pending approval.',
        SubscriptionPhase.unavailable =>
          'Subscription status is unavailable. Please try again.',
        SubscriptionPhase.ready => switch (tier) {
          SubscriptionTier.premium => 'Your Premium subscription is active.',
          SubscriptionTier.plus => 'Your Plus subscription is active.',
          _ =>
            state.access?.purchasesAvailable == true
                ? 'You are on the Free plan.'
                : 'Subscriptions are not available to purchase yet.',
        },
      };
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(liveRegion: true, child: Text(message)),
            if (canBuy)
              ...state.offerings.map(
                (offering) => ListTile(
                  title: Text(
                    offering.tier == SubscriptionTier.premium
                        ? 'Premium'
                        : 'Plus',
                  ),
                  subtitle: Text('${offering.localizedPrice} / month'),
                ),
              ),
            if (busy) const LinearProgressIndicator(),
            if (canBuy)
              FilledButton(
                onPressed: cubit.showPaywall,
                child: const Text('View subscription plans'),
              ),
            if (state.uid != null)
              Wrap(
                spacing: AppSpacing.sm,
                children: [
                  TextButton(
                    onPressed: busy ? null : cubit.refresh,
                    child: const Text('Refresh status'),
                  ),
                  TextButton(
                    onPressed: busy || state.phase == SubscriptionPhase.pending
                        ? null
                        : cubit.restore,
                    child: Text(
                      kIsWeb
                          ? 'Recover subscription status'
                          : 'Restore purchases',
                    ),
                  ),
                  if (native)
                    TextButton(
                      onPressed: busy ? null : cubit.manageSubscription,
                      child: const Text('Manage subscription'),
                    ),
                ],
              ),
          ],
        ),
      );
    },
  );
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
      // [DialogPageFrame] adds the safe area (but on the tablet layout).
      useSafeArea: false,
      builder: (context) => DialogPageFrame(
        builder: (context, host) => PremiumDialog(host: host),
      ),
    );
  }
}

/// The headline, the two static plan cards and the footer. Nothing here is
/// tappable and no price comes from anywhere but [kPremiumPlans].
class _PremiumBody extends StatelessWidget {
  const _PremiumBody();

  static const heroSubtitle =
      'Paid plans are not available yet. Planned monthly prices are '
      'inclusive of GST.';
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
          // Premium.html: the accent eyebrow, the display headline, the line.
          Text(
            'Coming soon'.toUpperCase(),
            style: AppTextStyles.eyebrow(theme)
                .copyWith(color: context.appColors.accentText),
          ),
          const SizedBox(height: AppSpacing.sm),
          const AppAccentHeadline(
            lead: 'A little ',
            accent: 'extra',
            size: AppAccountLayout.dialogHeadline,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            heroSubtitle,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
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
