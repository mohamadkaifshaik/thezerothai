import 'package:material_ui/material_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'bloc/subscription_cubit.dart';
import '../domain/subscription_models.dart';

import '../../../core/router/page_below.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/tablet_modal.dart';
import '../../../core/widgets/privacy_policy_link.dart';
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

  static const title = 'Subscriptions';
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
                  const _PlanOverview(preview: true),
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
      final hasStoreUi = native && cubit.hasStoreUi;
      final canBuy =
          hasStoreUi &&
          state.phase == SubscriptionPhase.ready &&
          state.offerings.length == 1 &&
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
          SubscriptionTier.premium ||
          SubscriptionTier.plus => 'Your Plus subscription is active.',
          _ =>
            state.access?.purchasesAvailable == true
                ? (hasStoreUi && state.offerings.length != 1
                      ? 'You are on Free. A monthly Plus offer is currently unavailable.'
                      : 'You are on the Free plan.')
                : 'New subscriptions are currently unavailable.',
        },
      };
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _PlanOverview(
              price: canBuy ? state.offerings.single.localizedPrice : null,
            ),
            const Divider(height: AppSpacing.lg),
            Text(
              'Your subscription',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: AppSpacing.sm),
            Semantics(liveRegion: true, child: Text(message)),
            if (busy) const LinearProgressIndicator(),
            if (canBuy) ...[
              const SizedBox(height: AppSpacing.md),
              FilledButton(
                onPressed: () => cubit.purchase(state.offerings.single),
                child: Text(
                  'Get Plus · ${state.offerings.single.localizedPrice}/month',
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              const Text(
                'Renews monthly until canceled in your store account.',
              ),
              Wrap(
                children: [
                  TextButton(
                    onPressed: () => launchTerms(context),
                    child: const Text('Terms of Service'),
                  ),
                  TextButton(
                    onPressed: () => launchPrivacyPolicy(context),
                    child: const Text('Privacy Policy'),
                  ),
                ],
              ),
            ],
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
                      hasStoreUi
                          ? 'Restore purchases'
                          : 'Recover subscription status',
                    ),
                  ),
                  if (hasStoreUi && tier != SubscriptionTier.free)
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

/// Both the launch preview and signed-in billing sheet use this comparison.
class _PlanOverview extends StatelessWidget {
  const _PlanOverview({this.price, this.preview = false});

  final String? price;
  final bool preview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final localPrice = price;
    final plusPrice = localPrice != null
        ? '$localPrice/month'
        : preview
        ? kPremiumPlans.single.priceLabel
        : 'Monthly subscription';
    final plans = [
      _PlanCard(
        name: 'Free',
        price: 'No subscription needed',
        details: 'Read and follow conversations, reply, message, and write posts up to 280 characters.',
        icon: Icons.chat_bubble_outline,
      ),
      _PlanCard(
        name: 'Plus',
        price: plusPrice,
        details: 'Everything in Free, plus posts up to 15,000 characters and article publishing.',
        icon: Icons.edit_outlined,
        featured: true,
      ),
    ];
    return Padding(
      padding: preview ? const EdgeInsets.all(AppSpacing.md) : EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Compare plans', style: theme.textTheme.headlineSmall),
          const SizedBox(height: AppSpacing.md),
          LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth >= 480 &&
                  MediaQuery.textScalerOf(context).scale(1) < 1.5) {
                return IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: plans.first),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(child: plans.last),
                    ],
                  ),
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  plans.first,
                  const SizedBox(height: AppSpacing.sm),
                  plans.last,
                ],
              );
            },
          ),
          if (preview) ...[
            const SizedBox(height: AppSpacing.md),
            Text(
              'India launch price includes GST. Checkout is currently unavailable.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.name,
    required this.price,
    required this.details,
    required this.icon,
    this.featured = false,
  });

  final String name;
  final String price;
  final String details;
  final IconData icon;
  final bool featured;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MergeSemantics(
      child: AppSurface(
        elevated: featured,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              icon,
              color: featured
                  ? context.appColors.accentText
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(name, style: theme.textTheme.titleMedium),
            Text(price, style: theme.textTheme.headlineSmall),
            const SizedBox(height: AppSpacing.sm),
            Text(details, style: theme.textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}
