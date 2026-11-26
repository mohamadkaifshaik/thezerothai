import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../../core/app_build.dart';
import '../../../../../core/router/app_router.dart';
import '../../../../../core/theme/app_theme.dart';
import '../../../../../core/vault/vault_status.dart';
import '../../../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../../domain/e2ee/encryption_claim.dart';
import '../../../domain/e2ee/encryption_device.dart';
import '../encryption_copy.dart';

/// The caller's `enabled_features`, rebuilding on change; empty without an
/// [OnboardingBloc] in the tree (a screen test), which hides every gate.
Set<String> claimFeaturesOf(BuildContext context) {
  try {
    return context.select((OnboardingBloc bloc) => bloc.state.enabledFeatures);
  } on ProviderNotFoundException {
    return const {};
  }
}

/// Builds with [claimVisible] for this device: the flag set (OnboardingBloc),
/// this build's platform and the [EncryptionDevice]'s vault status, each
/// rebuilding on change. No [EncryptionDevice] in the tree: not visible.
class ClaimVisibilityBuilder extends StatelessWidget {
  const ClaimVisibilityBuilder({
    super.key,
    required this.builder,
    this.platform,
  });

  final Widget Function(BuildContext context, bool visible) builder;

  /// The platform word; null reads [clientPlatformName] (tests set
  /// `debugDefaultTargetPlatformOverride` instead, or pass it here).
  final String? platform;

  @override
  Widget build(BuildContext context) {
    final features = claimFeaturesOf(context);
    final device = context.read<EncryptionDevice?>();
    if (device == null) return builder(context, false);
    final word = platform ?? clientPlatformName();
    return ValueListenableBuilder<VaultStatus>(
      valueListenable: device.vaultStatus,
      builder: (context, status, _) => builder(
        context,
        claimVisible(features: features, platform: word, vault: status),
      ),
    );
  }
}

/// The claim headline with its "What this covers" link, drawn only while
/// [claimVisible] holds (zero size otherwise). The two are one widget so the
/// headline never appears without its link (Plan 6 §4.2).
class ClaimHeadline extends StatelessWidget {
  const ClaimHeadline({super.key, this.onOpenCovers, this.padding});

  /// Opens the About page; default `push(AppRouter.encryptionAboutPath)`.
  final VoidCallback? onOpenCovers;

  /// Space around the headline when it is shown.
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return ClaimVisibilityBuilder(
      builder: (context, visible) {
        if (!visible) return const SizedBox.shrink();
        final body = ClaimHeadlineBody(onOpenCovers: onOpenCovers);
        final padding = this.padding;
        return padding == null ? body : Padding(padding: padding, child: body);
      },
    );
  }
}

/// [kClaimHeadline] and its [kClaimCoversLink], ungated: only for a caller
/// that has already checked [claimVisible] ([ClaimHeadline], the Settings
/// About group). Wraps at any text scale and keeps the link beside the text.
class ClaimHeadlineBody extends StatelessWidget {
  const ClaimHeadlineBody({super.key, this.onOpenCovers});

  final VoidCallback? onOpenCovers;

  /// Key of the "What this covers" link.
  static const coversKey = ValueKey('claim-covers-link');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final open =
        onOpenCovers ??
        () => unawaited(context.push<void>(AppRouter.encryptionAboutPath));
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: AppSpacing.xs,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ExcludeSemantics(
              child: Icon(
                Icons.lock_outline,
                size: AppIconSize.sm,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: AppSpacing.xs),
            Flexible(
              child: Text(kClaimHeadline, style: theme.textTheme.titleSmall),
            ),
          ],
        ),
        TextButton(
          key: coversKey,
          style: TextButton.styleFrom(
            minimumSize: const Size(0, AppSpacing.minTapTarget),
            textStyle: theme.textTheme.bodyMedium,
          ),
          onPressed: open,
          child: const Text(kClaimCoversLink),
        ),
      ],
    );
  }
}
