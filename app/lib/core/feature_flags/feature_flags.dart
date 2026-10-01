import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../features/onboarding/presentation/bloc/onboarding_bloc.dart';

/// Whether the server feature flag [name] is enabled for the signed-in caller
/// (ADR-0008 D6 / ADR-0010 D1: server-driven, via `GetMe.enabled_features`; a
/// missing name means off). Generalised from the graph-only check so every
/// flagged feature (`kFeatureGraph`, `kFeaturePosts`, ...) shares one rule.
///
/// Rebuilds the caller whenever the flag changes, via [OnboardingBloc]'s
/// state, which already fetches `GetMe` at 0 extra reads for this field.
bool isFeatureEnabled(BuildContext context, String name) {
  return context.select(
    (OnboardingBloc bloc) => bloc.state.enabledFeatures.contains(name),
  );
}

/// Non-reactive read of the same flag (e.g. inside a `create:` callback).
bool featureEnabledSnapshot(BuildContext context, String name) {
  return context.read<OnboardingBloc>().state.enabledFeatures.contains(name);
}
