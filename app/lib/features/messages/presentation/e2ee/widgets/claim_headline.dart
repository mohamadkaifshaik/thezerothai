import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../../app/session_wiring.dart'
    show
        ResumeFlagsRefresh,
        kClaimFlagsCheckEvery,
        kClaimFlagsMaxAge,
        kResumeFlagsMaxAge;
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
    // The keeper is always mounted (one tree shape, so a page under it keeps
    // its state and scroll position when the claim comes or goes); its
    // `visible` switches the timer, and it hides a claim whose last
    // successful GetMe is too old.
    Widget decide(BuildContext context, VaultStatus vault, bool blocked) =>
        ClaimFlagsKeeper(
          visible: claimVisible(
            featuresKnown: flags.known,
            features: flags.features,
            platform: word,
            vault: vault,
            messagingBlocked: blocked,
          ),
          builder: builder,
        );

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

/// Keeps the flag set fresh while the claim may show, and hides it when the
/// flag set is too old (Plan 6 PR 6-6, security M1 and L2). Always mounted
/// by [ClaimVisibilityBuilder]; [visible] is [claimVisible]'s answer.
///
/// - The server withdraws `claim_live` at once, but a client only sees that
///   at its next `GetMe`. When [visible] becomes true (or this mounts with
///   it true: the Messages inbox, Settings or the About page opening) it
///   calls [ResumeFlagsRefresh.refreshIfStale] once. Then, every
///   [kClaimFlagsCheckEvery] while the app is in the foreground, it calls
///   it again. That asks `GetMe` only when the last answer is
///   [kResumeFlagsMaxAge] old, through the existing refresh path; there is
///   no new RPC. The timer runs only while [visible] is true.
/// - [builder] gets [visible] AND a last successful `GetMe` no older than
///   [kClaimFlagsMaxAge], so a device that stays offline stops showing the
///   claim. Each tick re-checks, so the claim shows again within a minute of
///   a fresh answer.
///
/// With no [ResumeFlagsRefresh] in the tree (screen tests) there is no
/// timer and no age check. The app always provides one (bootstrap).
class ClaimFlagsKeeper extends StatefulWidget {
  const ClaimFlagsKeeper({
    super.key,
    required this.visible,
    required this.builder,
  });

  final bool visible;
  final Widget Function(BuildContext context, bool visible) builder;

  @override
  State<ClaimFlagsKeeper> createState() => _ClaimFlagsKeeperState();
}

class _ClaimFlagsKeeperState extends State<ClaimFlagsKeeper> {
  Timer? _timer;
  ResumeFlagsRefresh? _refresh;

  @override
  void initState() {
    super.initState();
    _refresh = context.read<ResumeFlagsRefresh?>();
    if (widget.visible) _start();
  }

  @override
  void didUpdateWidget(ClaimFlagsKeeper old) {
    super.didUpdateWidget(old);
    if (widget.visible && !old.visible) _start();
    if (!widget.visible && old.visible) _stop();
  }

  void _start() {
    final refresh = _refresh;
    if (refresh == null || _timer != null) return;
    refresh.refreshIfStale();
    _timer = Timer.periodic(kClaimFlagsCheckEvery, (_) {
      // Foreground only: a resume asks again through `onResume` anyway.
      final state = WidgetsBinding.instance.lifecycleState;
      if (state != null && state != AppLifecycleState.resumed) return;
      refresh.refreshIfStale();
      // Re-check the age of the last answer (shown or hidden).
      if (mounted) setState(() {});
    });
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final stale = _refresh?.answerOlderThan(kClaimFlagsMaxAge) ?? false;
    return widget.builder(context, widget.visible && !stale);
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
