import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../domain/graph_feature_flag.dart';

/// Whether the graph feature flag is enabled for the signed-in caller
/// (ADR-0008 D6: server-driven, via `GetMe.enabled_features`; a missing name
/// means off). This is the single gating check every graph UI element
/// (follow buttons, the block/mute menu, followers/following lists, the
/// Settings "Blocked accounts"/"Muted accounts" entries) and the router must
/// use — never infer it from anything else.
///
/// Rebuilds the caller whenever the flag value changes (e.g. after a fresh
/// `GetMe` following a `FEATURE_DISABLED` error), via [OnboardingBloc]'s
/// state, which already fetches `GetMe` at 0 extra reads for this field.
bool isGraphEnabled(BuildContext context) {
  return context.select(
    (OnboardingBloc bloc) => bloc.state.enabledFeatures.contains(kFeatureGraph),
  );
}

/// Non-reactive read of the same flag (e.g. inside a `create:` callback,
/// before the widget has a `BuildContext` subscribed to rebuilds).
bool graphEnabledSnapshot(BuildContext context) {
  return context.read<OnboardingBloc>().state.enabledFeatures.contains(
    kFeatureGraph,
  );
}
