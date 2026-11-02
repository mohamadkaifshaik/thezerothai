import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/telemetry/telemetry_consent_copy.dart';
import '../../../../core/telemetry/telemetry_consent_cubit.dart';
import '../../../../core/telemetry/telemetry_consent_store.dart';
import '../../../../shared/widgets/primitives/settings_group.dart';

/// A "Send crash reports" or "Share usage statistics" switch of Settings >
/// Privacy & safety (TEL-7). The caller decides visibility with
/// `telemetryRowVisible` (Android, the kind's flag on). Turning it off stops
/// collection at once through the shared consent store. Needs a
/// [TelemetryConsentCubit] above it.
class TelemetryConsentRow extends StatelessWidget {
  const TelemetryConsentRow({super.key, required this.kind});

  final TelemetryKind kind;

  @override
  Widget build(BuildContext context) {
    final on = context.select(
      (TelemetryConsentCubit cubit) => cubit.state.of(kind) == ConsentChoice.on,
    );
    final loaded = context.select(
      (TelemetryConsentCubit cubit) => cubit.state.loaded,
    );
    return SettingsRow(
      icon: switch (kind) {
        TelemetryKind.crash => Icons.bug_report_outlined,
        TelemetryKind.usage => Icons.insights_outlined,
      },
      title: TelemetryConsentCopy.label(kind),
      subtitle: TelemetryConsentCopy.settingsSubtitle,
      toggled: on,
      onTap: loaded
          ? () => context.read<TelemetryConsentCubit>().setSwitch(kind, on: !on)
          : null,
    );
  }
}
