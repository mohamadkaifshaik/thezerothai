import 'package:flutter/widgets.dart';

import '../../features/posts/domain/posts_feature_flag.dart';
import '../feature_flags/feature_flags.dart';
import 'app_router.dart';

/// Whether [location] is one community's own page (`/communities/:id`, not
/// `/communities/new` nor a sub-page). The page has its own "Post" entry
/// that composes into the community, so the shell's floating "New post" is
/// hidden there (R10b), and its cover band draws under the status bar
/// (`ResponsiveScaffold.extendBodyUnderStatusBar`).
bool isCommunityPageAt(String location) {
  final path = Uri.tryParse(location)?.path ?? location;
  return RegExp(r'^/communities/(?!new/?$)[^/]+/?$').hasMatch(path);
}

/// Whether [location] is one profile page (`/profile/:handle`, `/u/:id`, not
/// Followers, Following or Lists). Its navy hero draws under the status bar
/// (`ResponsiveScaffold.extendBodyUnderStatusBar`).
bool isProfilePageAt(String location) {
  final path = Uri.tryParse(location)?.path ?? location;
  return RegExp(r'^/(profile|u)/[^/]+/?$').hasMatch(path);
}

/// Whether a way to start a new post is offered at [location]: only with the
/// posts flag on, and not on Settings or Messages. Messages has its own header
/// action; Settings owns Edit profile and related controls. The one rule
/// behind the shell's "New post" button and the Home composer entry row.
///
/// Rebuilds the caller when the flag changes (see [isFeatureEnabled]).
bool canComposeAt(BuildContext context, String location) =>
    isFeatureEnabled(context, kFeaturePosts) &&
    !location.startsWith(AppRouter.settingsPath) &&
    !location.startsWith(AppRouter.editProfilePath) &&
    !location.startsWith(AppRouter.messagesPath);

/// Whether the narrow layout shows the floating compose button at [location]
/// (decision D2 of the W0 plan): wherever a way to post
/// is offered ([canComposeAt]) except on Notifications and Bookmarks (the
/// button would sit over the Undo snackbar and the last row). Home also shows
/// the floating button; its inline composer remains an alternate entry.
///
/// Wide layouts always show the rail's Post control instead of the button.
bool showComposeFabAt(BuildContext context, String location) =>
    canComposeAt(context, location) &&
    !isCommunityPageAt(location) &&
    !location.startsWith(AppRouter.notificationsPath) &&
    !location.startsWith(AppRouter.bookmarksPath);
