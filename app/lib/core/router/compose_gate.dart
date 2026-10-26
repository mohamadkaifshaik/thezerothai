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

/// Whether the narrow layout shows the floating compose button at [location]
/// (decision D2 of `docs/plans/ui-w0-foundations.md`): wherever a way to post
/// is offered ([canComposeAt]) except where the screen has its own entry or
/// no use for one: Home (the inline composer row), Notifications and
/// Bookmarks (the button would sit over the Undo snackbar and the last row).
///
/// Wide layouts always show the rail's Post control instead of the button.
bool showComposeFabAt(BuildContext context, String location) =>
    canComposeAt(context, location) &&
    !location.startsWith(AppRouter.homePath) &&
    !location.startsWith(AppRouter.notificationsPath) &&
    !location.startsWith(AppRouter.bookmarksPath);
