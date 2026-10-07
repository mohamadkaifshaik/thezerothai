import 'package:flutter/widgets.dart';

import '../../../core/feature_flags/feature_flags.dart';
import '../domain/account_feature_flag.dart';

/// Reactive check for widgets (rebuilds when the flag changes).
bool isAccountLifecycleEnabled(BuildContext context) =>
    isFeatureEnabled(context, kFeatureAccountLifecycle);

/// Non-reactive check (e.g. inside a `create:` callback).
bool accountLifecycleEnabledSnapshot(BuildContext context) =>
    featureEnabledSnapshot(context, kFeatureAccountLifecycle);
