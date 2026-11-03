import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/feature_flags/feature_flags.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/primitives/app_pill_button.dart';
import '../../../../shared/widgets/primitives/app_surface.dart';
import '../../data/push_messaging.dart';
import '../../domain/notifications_feature_flag.dart';
import '../../domain/push_opt_in.dart';
import '../bloc/push_cubit.dart';
import '../bloc/push_opt_in_cubit.dart';

/// Where the card is placed. The "off in your device settings" hint after a
/// denial shows on [notifications] only.
enum PushOptInPlacement { home, notifications }

/// Whether the "Turn on notifications" card is on screen on Home right now
/// (the same conditions as [PushOptInCard] for [PushPermission.notDetermined]).
/// The telemetry consent card waits on it: one card at a time, push first.
/// False when the cubits are not in scope.
bool isPushOptInOffered(BuildContext context) {
  if (!PushOptIn.supportedOnThisPlatform ||
      !isFeatureEnabled(context, kFeatureNotifications)) {
    return false;
  }
  final pushOffered = context.select<PushCubit?, bool>(
    (push) =>
        push != null &&
        push.state.supported &&
        push.state.permissionKnown &&
        push.state.permission == PushPermission.notDetermined,
  );
  if (!pushOffered) return false;
  return context.select<PushOptInCubit?, bool>(
    (optIn) => optIn != null && optIn.state.canOffer,
  );
}

/// The "Turn on notifications" card: an [AppSurface] with the title,
/// one line of copy, a "Turn on" pill and a "Not now" text action. Not a
/// sliver: wrap it in a `SliverToBoxAdapter`.
///
/// Renders nothing unless the `notifications` flag is on, the platform offers
/// it ([PushOptIn.supportedOnThisPlatform]: not web, not iOS yet), the OS has
/// not been asked, and the account has not tapped "Not now" in the last 30
/// days. The OS dialog opens on the "Turn on" tap only. After a denial the
/// card gives way to a one-line hint on [PushOptInPlacement.notifications].
/// Needs [PushCubit] and [PushOptInCubit] above it (only once the flag and
/// platform checks pass).
class PushOptInCard extends StatelessWidget {
  const PushOptInCard({super.key, required this.placement});

  final PushOptInPlacement placement;

  @override
  Widget build(BuildContext context) {
    if (!PushOptIn.supportedOnThisPlatform ||
        !isFeatureEnabled(context, kFeatureNotifications)) {
      return const SizedBox.shrink();
    }
    return BlocBuilder<PushCubit, PushState>(
      buildWhen: (a, b) =>
          a.supported != b.supported ||
          a.permission != b.permission ||
          a.permissionKnown != b.permissionKnown ||
          a.requesting != b.requesting,
      builder: (context, push) {
        return BlocBuilder<PushOptInCubit, PushOptInState>(
          builder: (context, optIn) {
            if (!push.supported || !push.permissionKnown) {
              return const SizedBox.shrink();
            }
            if (push.permission == PushPermission.notDetermined) {
              if (!optIn.canOffer) return const SizedBox.shrink();
              return _Card(requesting: push.requesting);
            }
            if (placement == PushOptInPlacement.notifications &&
                optIn.denied &&
                push.permission == PushPermission.denied) {
              return const _DeniedHint();
            }
            return const SizedBox.shrink();
          },
        );
      },
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.requesting});

  final bool requesting;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return AppSurface(
      margin: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              'Turn on notifications',
              style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Get a heads-up when someone follows or mentions you.',
            style: text.bodyMedium?.copyWith(
              color: context.appColors.secondaryOnRaised,
            ),
          ),
          const SizedBox(height: AppSpacing.smd),
          // A Wrap, so the two actions stack at large text on a narrow phone.
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              AppPillButton(
                label: 'Turn on',
                compact: true,
                busy: requesting,
                onPressed: () => context.read<PushOptInCubit>().turnOn(),
              ),
              TextButton(
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, AppSpacing.minTapTarget),
                ),
                onPressed: requesting
                    ? null
                    : () => context.read<PushOptInCubit>().notNow(),
                child: const Text('Not now'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DeniedHint extends StatelessWidget {
  const _DeniedHint();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Text(
        'Notifications are off in your device settings',
        style: text.bodyMedium?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
