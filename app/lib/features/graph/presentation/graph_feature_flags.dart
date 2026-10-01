import 'package:flutter/widgets.dart';

import '../../../core/feature_flags/feature_flags.dart';
import '../domain/graph_feature_flag.dart';

/// Whether the graph feature flag is enabled for the signed-in caller
/// (ADR-0008 D6: server-driven, via `GetMe.enabled_features`; a missing name
/// means off). This is the single gating check every graph UI element
/// (follow buttons, the block/mute menu, followers/following lists, the
/// Settings "Blocked accounts"/"Muted accounts" entries) and the router must
/// use — never infer it from anything else. Delegates to the shared
/// [isFeatureEnabled].
bool isGraphEnabled(BuildContext context) =>
    isFeatureEnabled(context, kFeatureGraph);

/// Non-reactive read of the same flag (e.g. inside a `create:` callback,
/// before the widget has a `BuildContext` subscribed to rebuilds).
bool graphEnabledSnapshot(BuildContext context) =>
    featureEnabledSnapshot(context, kFeatureGraph);
