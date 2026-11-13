import 'package:flutter/widgets.dart';

import '../../features/posts/domain/posts_feature_flag.dart';
import '../feature_flags/feature_flags.dart';
import 'app_router.dart';

/// Whether [location] is one community's own page (`/communities/:id`, not
/// `/communities/new` nor a sub-page). Its cover band draws under the status
/// bar (`ResponsiveScaffold.extendBodyUnderStatusBar`).
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
