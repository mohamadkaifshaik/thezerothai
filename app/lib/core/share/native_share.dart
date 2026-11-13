import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:share_plus/share_plus.dart';

import 'native_share_capability.dart';

/// How a share sheet ended, as far as the platform can tell.
///
/// Only [completed] means the link went somewhere (the share counts); a
/// sheet the user closed is [dismissed], and a platform that cannot report
/// the outcome (some browsers, Windows, Linux) is [unavailable]. The caller
/// records a share on [completed] only, so a share that may not have happened
/// is never counted.
enum NativeShareStatus { completed, dismissed, unavailable }

/// The platform's own share sheet, behind one small seam so the share menu
/// can be tested without touching a plugin.
abstract interface class NativeShare {
  /// Whether this device or browser has a native share sheet. Decided at
  /// runtime (the menu hides "Share via..." when false).
  bool get isAvailable;

  /// Opens the sheet for [url] only (no text, title or author). [anchor] is
  /// the global rectangle of the control that was tapped; iPad and macOS need
  /// it to place the popover. Completes with how the sheet ended
  /// ([NativeShareStatus]).
  Future<NativeShareStatus> shareUrl(String url, {Rect? anchor});
}

/// [NativeShare] over `share_plus` (BSD-3-Clause).
///
/// share_plus has no "is supported" call, so availability is our own check:
/// - Android, iOS, macOS and Windows: always (they have a system share UI).
/// - Linux: no (share_plus only opens a mailto: link there).
/// - Web: `navigator.share` and `navigator.canShare` must exist (they do only
///   in secure contexts, and not in e.g. Firefox desktop); see
///   `native_share_capability_web.dart`.
///
/// The mailto and download fallbacks are off so the call never opens a mail
/// client behind the user's back.
class SharePlusNativeShare implements NativeShare {
  const SharePlusNativeShare();

  @override
  bool get isAvailable => kIsWeb
      ? webHasNativeShare()
      : switch (defaultTargetPlatform) {
          TargetPlatform.android ||
          TargetPlatform.iOS ||
          TargetPlatform.macOS ||
          TargetPlatform.windows => true,
          TargetPlatform.linux || TargetPlatform.fuchsia => false,
        };

  @override
  Future<NativeShareStatus> shareUrl(String url, {Rect? anchor}) async {
    final result = await SharePlus.instance.share(
      ShareParams(
        uri: Uri.parse(url),
        sharePositionOrigin: anchor,
        downloadFallbackEnabled: false,
        mailToFallbackEnabled: false,
      ),
    );
    return switch (result.status) {
      ShareResultStatus.success => NativeShareStatus.completed,
      ShareResultStatus.dismissed => NativeShareStatus.dismissed,
      ShareResultStatus.unavailable => NativeShareStatus.unavailable,
    };
  }
}
