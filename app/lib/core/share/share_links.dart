import 'package:flutter/widgets.dart';

import '../router/app_router.dart';
import 'native_share.dart';

/// The link people send to others for one post: [origin] plus the in-app post
/// route (`AppRouter.postPath`), nothing else. No query, fragment, token or
/// user id; the recipient's open costs the existing GetPost / GetThread rows.
///
/// Pass the id of the post to open: the original's id for a REPOST row
/// (`engagementTargetId`). [origin] is `AppConfig.shareOrigin` (no trailing
/// slash).
String postShareUrl(String postId, {required String origin}) =>
    '$origin${AppRouter.postPath(postId)}';

/// What the share menu needs from the app: the public [origin] for links and
/// the [nativeShare] sheet. Built once in bootstrap from `AppConfig`, handed
/// down with [ShareLinksScope].
class ShareLinks {
  const ShareLinks({
    required this.origin,
    this.nativeShare = const SharePlusNativeShare(),
  });

  final String origin;
  final NativeShare nativeShare;

  /// The shareable link of [postId] (see [postShareUrl]).
  String postUrl(String postId) => postShareUrl(postId, origin: origin);
}

/// Hands [ShareLinks] to the post action row. A tree without a scope offers
/// no Share action at all (a card shown by itself, an isolated widget test),
/// never a broken one.
class ShareLinksScope extends InheritedWidget {
  const ShareLinksScope({super.key, this.links, required super.child});

  /// Null (tests, an unconfigured host) means no Share action anywhere below.
  final ShareLinks? links;

  /// The nearest [ShareLinks], or null without a scope.
  static ShareLinks? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShareLinksScope>()?.links;

  @override
  bool updateShouldNotify(ShareLinksScope oldWidget) =>
      links != oldWidget.links;
}
