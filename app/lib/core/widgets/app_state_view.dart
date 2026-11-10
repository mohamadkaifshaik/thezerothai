import 'package:flutter/material.dart';

import '../../shared/widgets/primitives/app_empty_view.dart';
import '../network/app_exception.dart';

/// A full-area state that has no Retry: permission denied, feature off, or any
/// other "this is the answer" notice (an icon, a title, optional body and
/// action). One widget so every such state looks the same; the named
/// constructors carry the app's existing copy.
///
/// Announced as a live region; the icon is decorative.
class AppStateView extends StatelessWidget {
  const AppStateView({
    super.key,
    required this.title,
    this.icon,
    this.body,
    this.action,
    this.error = false,
  });

  /// Direct link to a feature the server has switched off (the entry point is
  /// hidden when its flag is off; this is what a deep link shows).
  const AppStateView.featureOff({super.key, this.action})
    : title = featureOffMessage,
      icon = Icons.hourglass_empty_outlined,
      body = null,
      error = false;

  /// The server refused an action for this account. Never says why.
  AppStateView.permissionDenied({super.key, this.action})
    : title = CommunityForbiddenReason.unknown.userMessage,
      icon = Icons.block_outlined,
      body = null,
      error = true;

  static const featureOffMessage = "This feature isn't available yet.";

  final String title;
  final IconData? icon;
  final String? body;
  final Widget? action;

  /// Paint the icon with the theme's error colour (danger text on dark).
  final bool error;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Center(
        child: AppEmptyView(
          centered: true,
          icon: icon,
          iconColor: error ? colors.error : null,
          title: title,
          subtitle: body,
          action: action,
        ),
      ),
    );
  }
}
