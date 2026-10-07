import 'package:flutter/widgets.dart';

import '../../../core/feature_flags/feature_flags.dart';

/// Name of the account-lifecycle flag (delete account + data export) as
/// exposed through `GetMeResponse.enabled_features`. A missing name means
/// off. Never hardcode `'account_lifecycle'` anywhere else.
const kFeatureAccountLifecycle = 'account_lifecycle';

/// Reactive check for widgets (rebuilds when the flag changes).
bool isAccountLifecycleEnabled(BuildContext context) =>
    isFeatureEnabled(context, kFeatureAccountLifecycle);

/// Non-reactive check (e.g. inside a `create:` callback).
bool accountLifecycleEnabledSnapshot(BuildContext context) =>
    featureEnabledSnapshot(context, kFeatureAccountLifecycle);
