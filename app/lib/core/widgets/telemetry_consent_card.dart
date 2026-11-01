import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../features/notifications/presentation/widgets/push_opt_in_card.dart';
import '../../shared/widgets/primitives/app_pill_button.dart';
import '../../shared/widgets/primitives/app_surface.dart';
import '../feature_flags/feature_flags.dart';
import '../telemetry/telemetry_consent_copy.dart';
import '../telemetry/telemetry_consent_cubit.dart';
import '../telemetry/telemetry_consent_store.dart';
import '../telemetry/telemetry_inputs.dart';
import '../telemetry/telemetry_platforms.dart';
import '../theme/app_theme.dart';
import 'privacy_policy_link.dart';

/// The server flag that offers [kind] on this account.
String telemetryFlagOf(TelemetryKind kind) => switch (kind) {
  TelemetryKind.crash => kFeatureCrashReporting,
  TelemetryKind.usage => kFeatureAnalytics,
};

/// Whether the Settings row of [kind] shows: Android, the matching flag on and
/// the consent cubit in scope (TEL-7). Reactive to the flags.
bool telemetryRowVisible(
  BuildContext context,
  TelemetryKind kind, {
  bool? supported,
}) {
  final enabled = isFeatureEnabled(context, telemetryFlagOf(kind));
  final hasCubit = context.select<TelemetryConsentCubit?, bool>(
    (cubit) => cubit != null,
  );
  return (supported ?? TelemetryPlatforms.current) && enabled && hasCubit;
}

/// The "Help us fix and improve" card at the top of Home (TEL-7, ADR-0032 F1
/// option A): two switches, both off, "Save" and "Not now", one sentence each
/// on what is sent, and the Privacy Policy link. Not a sliver: wrap it in a
/// `SliverToBoxAdapter`.
///
/// Renders nothing unless the platform collects ([supported], Android), the
/// account's answers are read, at least one kind has its flag on AND is still
/// unasked (only those kinds get a switch), and the push opt-in card is not
/// showing (one card at a time, push first). "Save" stores what was switched
/// on (the rest off); "Not now" stores off for every unasked kind. Either way
/// the card never returns. Needs [TelemetryConsentCubit] above it. 0 RPCs.
class TelemetryConsentCard extends StatefulWidget {
  const TelemetryConsentCard({super.key, this.supported});

  /// Overrides [TelemetryPlatforms.current] (tests; web cannot be faked).
  final bool? supported;

  @override
  State<TelemetryConsentCard> createState() => _TelemetryConsentCardState();
}

class _TelemetryConsentCardState extends State<TelemetryConsentCard> {
  // Ephemeral: what is switched on before "Save". Everything starts off.
  final Set<TelemetryKind> _on = {};

  @override
  Widget build(BuildContext context) {
    if (!(widget.supported ?? TelemetryPlatforms.current)) {
      return const SizedBox.shrink();
    }
    final crashFlag = isFeatureEnabled(context, kFeatureCrashReporting);
    final usageFlag = isFeatureEnabled(context, kFeatureAnalytics);
    if (!crashFlag && !usageFlag) return const SizedBox.shrink();
    if (isPushOptInOffered(context)) return const SizedBox.shrink();
    return BlocBuilder<TelemetryConsentCubit, TelemetryConsentState>(
      builder: (context, state) {
        if (state.uid == null || !state.loaded) return const SizedBox.shrink();
        final asked = <TelemetryKind>[
          if (crashFlag && state.crash == ConsentChoice.unasked)
            TelemetryKind.crash,
          if (usageFlag && state.usage == ConsentChoice.unasked)
            TelemetryKind.usage,
        ];
        if (asked.isEmpty) return const SizedBox.shrink();
        return _card(context, asked);
      },
    );
  }

  Widget _card(BuildContext context, List<TelemetryKind> asked) {
    final text = Theme.of(context).textTheme;
    final cubit = context.read<TelemetryConsentCubit>();
    return AppSurface(
      margin: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              TelemetryConsentCopy.cardTitle,
              style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            TelemetryConsentCopy.cardIntro,
            style: text.bodyMedium?.copyWith(
              color: context.appColors.secondaryOnRaised,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          for (final kind in asked)
            _SwitchRow(
              key: ValueKey(kind),
              kind: kind,
              value: _on.contains(kind),
              onChanged: (on) =>
                  setState(() => on ? _on.add(kind) : _on.remove(kind)),
            ),
          const SizedBox(height: AppSpacing.xs),
          // A Wrap, so the two actions stack at large text on a narrow phone.
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              AppPillButton(
                label: TelemetryConsentCopy.save,
                compact: true,
                onPressed: () => cubit.save(asked.toSet(), _on.toSet()),
              ),
              TextButton(
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, AppSpacing.minTapTarget),
                ),
                onPressed: cubit.notNow,
                child: const Text(TelemetryConsentCopy.notNow),
              ),
            ],
          ),
          const Align(
            alignment: AlignmentDirectional.centerStart,
            child: PrivacyPolicyLink(),
          ),
        ],
      ),
    );
  }
}

/// One switch of the card: the label, its sentence and a [Switch], spoken as
/// one node (label, then sentence) with the on / off state announced once.
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    super.key,
    required this.kind,
    required this.value,
    required this.onChanged,
  });

  final TelemetryKind kind;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final label = TelemetryConsentCopy.label(kind);
    final sentence = TelemetryConsentCopy.sentence(kind);
    return Semantics(
      container: true,
      toggled: value,
      label: '$label\n$sentence',
      onTap: () => onChanged(!value),
      excludeSemantics: true,
      child: InkWell(
        onTap: () => onChanged(!value),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppSpacing.minTapTarget),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: text.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        sentence,
                        style: text.bodyMedium?.copyWith(
                          color: context.appColors.secondaryOnRaised,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Switch(value: value, onChanged: onChanged),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
