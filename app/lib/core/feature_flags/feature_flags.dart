import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../features/onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../features/onboarding/presentation/bloc/onboarding_state.dart';

/// Whether the server feature flag [name] is enabled for the signed-in caller
/// (server-driven, via `GetMe.enabled_features`; a missing name means off).
/// Generalised from the graph-only check so every
/// flagged feature (`kFeatureGraph`, `kFeaturePosts`, ...) shares one rule.
///
/// Rebuilds the caller whenever the flag changes, via [OnboardingBloc]'s
/// state, which already fetches `GetMe` at 0 extra reads for this field.
bool isFeatureEnabled(BuildContext context, String name) {
  return context.select(
    (OnboardingBloc bloc) => bloc.state.enabledFeatures.contains(name),
  );
}

/// Whether [name] is off for the caller only because this app build is older
/// than the server's floor (`GetMe.features_needing_update`): the feature's
/// place shows an update prompt instead of vanishing. False whenever [name] is
/// enabled, so floors at 0 change nothing.
bool needsUpdateFor(OnboardingState state, String name) =>
    !state.enabledFeatures.contains(name) &&
    state.featuresNeedingUpdate.contains(name);

/// Reactive [needsUpdateFor] for widgets.
bool featureNeedsUpdate(BuildContext context, String name) {
  return context.select(
    (OnboardingBloc bloc) => needsUpdateFor(bloc.state, name),
  );
}

/// Non-reactive read of the same flag (e.g. inside a `create:` callback).
bool featureEnabledSnapshot(BuildContext context, String name) {
  return context.read<OnboardingBloc>().state.enabledFeatures.contains(name);
}
