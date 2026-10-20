import 'package:flutter/widgets.dart';

import '../../features/posts/domain/posts_feature_flag.dart';
import '../feature_flags/feature_flags.dart';
import 'app_router.dart';

/// Whether a way to start a new post is offered at [location] (ADR-0010 D1):
/// only with the posts flag on, and not on Settings. The one rule behind both
/// the shell's "New post" button and the Home composer entry row.
///
/// Rebuilds the caller when the flag changes (see [isFeatureEnabled]).
bool canComposeAt(BuildContext context, String location) =>
    isFeatureEnabled(context, kFeaturePosts) &&
    !location.startsWith(AppRouter.settingsPath);
