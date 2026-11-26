import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../../app/session_wiring.dart'
    show ResumeFlagsRefresh, kClaimFlagsCheckEvery, kResumeFlagsMaxAge;
import '../../../../../core/app_build.dart';
import '../../../../../core/feature_flags/device_sign_out_feature_flag.dart';
import '../../../../../core/router/app_router.dart';
import '../../../../../core/theme/app_theme.dart';
import '../../../../../core/vault/vault_status.dart';
import '../../../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../../domain/e2ee/encryption_claim.dart';
import '../../../domain/e2ee/encryption_device.dart';
import '../../../domain/messaging_feature_flag.dart';
import '../encryption_copy.dart';
import '../encryption_status.dart';

/// The flags the claim reads, from the caller's `enabled_features`:
/// [known] is false while the flag set is not known (`featuresPending`), while
/// no user is signed in, and while the state belongs to another user than the
/// one signed in (the `e2eeRequiredFor` check; fix round 1, code review m2).
/// [features] holds only the claim's flags that are on.
typedef ClaimFlags = ({bool known, Set<String> features});

/// [ClaimFlags] for the signed-in caller, rebuilding when one of them
/// changes. Not known without an [OnboardingBloc] in the tree (a screen
/// test), which hides the claim.
ClaimFlags claimFlagsOf(BuildContext context) {
  try {
    // Bools only: the state's `enabledFeatures` is a new set on every read,
    // so selecting it would rebuild on every onboarding state.
    final r = context.select((OnboardingBloc bloc) {
      final state = bloc.state;
      final uid = bloc.currentUid;
      final f = state.enabledFeatures;
      return (
        known:
            !state.featuresPending && uid != null && bloc.uidOf(state) == uid,
        live: f.contains(kFeatureClaimLive),
        required: f.contains(kFeatureE2eeRequired),
        signOut: f.contains(kFeatureDeviceSignOut),
      );
    });
    return (
      known: r.known,
      features: {
        if (r.live) kFeatureClaimLive,
        if (r.required) kFeatureE2eeRequired,
        if (r.signOut) kFeatureDeviceSignOut,
      },
    );
  } on ProviderNotFoundException {
    return (known: false, features: const {});
  }
}

/// Builds with [claimVisible] for this device: the flags ([claimFlagsOf]),
/// this build's platform, the [EncryptionDevice]'s vault status (the device
/// is watched) and, when an [EncryptionStatusCubit] is in the tree, whether
/// its status blocks messaging. Each one rebuilds on change. With no
/// [EncryptionDevice] in the tree the claim is not visible.
///
/// While the claim is visible, [ClaimFlagsKeeper] keeps `GetMe` fresh
/// (security M1).
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
    final flags = claimFlagsOf(context);
    final device = context.watch<EncryptionDevice?>();
    if (device == null) return builder(context, false);
    // Read, not watched: watching a cubit rebuilds on each of its states;
    // the BlocSelector below follows only `blocksMessaging`.
    final statusCubit = context.read<EncryptionStatusCubit?>();
    final word = platform ?? clientPlatformName();
    Widget decide(BuildContext context, VaultStatus vault, bool blocked) {
      final visible = claimVisible(
        featuresKnown: flags.known,
        features: flags.features,
        platform: word,
        vault: vault,
        messagingBlocked: blocked,
      );
      final child = builder(context, visible);
      return visible ? ClaimFlagsKeeper(child: child) : child;
    }

    return ValueListenableBuilder<VaultStatus>(
      valueListenable: device.vaultStatus,
      builder: (context, vault, _) => statusCubit == null
          ? decide(context, vault, false)
          : BlocSelector<EncryptionStatusCubit, EncryptionStatus, bool>(
              bloc: statusCubit,
              selector: (status) => status.blocksMessaging,
              builder: (context, blocked) => decide(context, vault, blocked),
            ),
    );
  }
}

/// Keeps the flag set fresh while a claim is shown (Plan 6 PR 6-6 fix round
/// 1, security M1). The server withdraws `claim_live` at once, but a client
/// only sees that at its next `GetMe`. When this is mounted (the Messages
/// inbox, Settings or the About page opening with the claim visible) it
/// calls [ResumeFlagsRefresh.refreshIfStale] once. Then, every
/// [kClaimFlagsCheckEvery] while the app is in the foreground, it calls it
/// again. That asks `GetMe` again only when the last answer is
/// [kResumeFlagsMaxAge] old, through the existing refresh path; there is no
/// new RPC. With no [ResumeFlagsRefresh] in the tree (tests) it does nothing.
class ClaimFlagsKeeper extends StatefulWidget {
  const ClaimFlagsKeeper({super.key, required this.child});

  final Widget child;

  @override
  State<ClaimFlagsKeeper> createState() => _ClaimFlagsKeeperState();
}

class _ClaimFlagsKeeperState extends State<ClaimFlagsKeeper> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    final refresh = context.read<ResumeFlagsRefresh?>();
    if (refresh == null) return;
    refresh.refreshIfStale();
    _timer = Timer.periodic(kClaimFlagsCheckEvery, (_) {
      // Foreground only: a resume asks again through `onResume` anyway.
      final state = WidgetsBinding.instance.lifecycleState;
      if (state != null && state != AppLifecycleState.resumed) return;
      refresh.refreshIfStale();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
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
