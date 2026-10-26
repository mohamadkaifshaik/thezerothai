import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:share_plus/share_plus.dart';

import 'native_share_capability.dart';

/// The platform's own share sheet, behind one small seam so the share menu
/// can be tested without touching a plugin.
abstract interface class NativeShare {
  /// Whether this device or browser has a native share sheet. Decided at
  /// runtime (the menu hides "Share via..." when false).
  bool get isAvailable;

  /// Opens the sheet for [url] only (no text, title or author). [anchor] is
  /// the global rectangle of the control that was tapped; iPad and macOS need
  /// it to place the popover.
  Future<void> shareUrl(String url, {Rect? anchor});
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
  Future<void> shareUrl(String url, {Rect? anchor}) async {
    await SharePlus.instance.share(
      ShareParams(
        uri: Uri.parse(url),
        sharePositionOrigin: anchor,
        downloadFallbackEnabled: false,
        mailToFallbackEnabled: false,
      ),
    );
  }
}
