import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// The 3:1 band behind the avatar: the profile's banner when there is
/// one, else a flat theme surface like X's empty banner (no gradient anywhere
/// in the app). The flat surface is also the placeholder and the error state,
/// and the band is sized by its parent (3:1), so a banner arriving later moves
/// nothing. It is decoration: hidden from assistive technology (a banner has
/// no alt text).
///
/// - [url] is a saved banner (disk-cached, decoded at display width).
/// - [bytes] is an unsaved, on-device one (the Edit profile preview: the 600
///   px thumb it just made, never downloaded) and wins over [url].
///
/// Used by `ProfileHeader` and the Edit profile `BannerEditor`.
class ProfileCoverBand extends StatelessWidget {
  const ProfileCoverBand({super.key, this.url = '', this.bytes});

  final String url;
  final Uint8List? bytes;

  /// The widest source image (the 1500 px full banner): nothing is decoded
  /// larger.
  static const _maxDecodePx = 1500;

  @override
  Widget build(BuildContext context) {
    final flat = ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
    );
    final local = bytes;
    if (url.isEmpty && local == null) return ExcludeSemantics(child: flat);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    return ExcludeSemantics(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final px = (constraints.maxWidth * pixelRatio).ceil();
          final decodePx = px > 0 ? math.min(px, _maxDecodePx) : null;
          if (local != null) {
            return Image.memory(
              local,
              fit: BoxFit.cover,
              width: double.infinity,
              height: double.infinity,
              cacheWidth: decodePx,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => flat,
            );
          }
          return CachedNetworkImage(
            key: ValueKey(url),
            imageUrl: url,
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            memCacheWidth: decodePx,
            fadeInDuration: reduceMotion
                ? Duration.zero
                : const Duration(milliseconds: 150),
            fadeOutDuration: reduceMotion
                ? Duration.zero
                : const Duration(milliseconds: 150),
            placeholder: (_, _) => flat,
            errorWidget: (_, _, _) => flat,
          );
        },
      ),
    );
  }
}
