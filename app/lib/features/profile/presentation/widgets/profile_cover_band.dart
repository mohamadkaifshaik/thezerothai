import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// The band behind the avatar: the profile's banner when there is one, else a
/// flat theme surface like X's empty banner (no gradient anywhere in the
/// app). The flat surface is also the placeholder and the error state, and
/// the band is sized by its parent, so a banner arriving later moves nothing.
/// It is decoration: hidden from assistive technology (a banner has no alt
/// text).
///
/// The banner covers the band (`BoxFit.cover`). A band taller than the 3:1
/// image (the profile hero) scales the image by height, so it is decoded for
/// the width the cover needs ([decodeWidthFor]), not the band's width alone.
///
/// - [url] is the 1500 px full banner, [thumbUrl] the 600 px one. The band
///   asks for the thumb only when 600 px covers it, and for whichever exists
///   when only one does.
/// - [bytes] is an unsaved, on-device one (the Edit profile preview: the 600
///   px thumb it just made, never downloaded) and wins over both.
///
/// Used by `ProfileHeader`, the profile hero and the Edit profile
/// `BannerEditor`.
class ProfileCoverBand extends StatelessWidget {
  const ProfileCoverBand({
    super.key,
    this.url = '',
    this.thumbUrl = '',
    this.bytes,
    this.placeholder,
  });

  final String url;
  final String thumbUrl;
  final Uint8List? bytes;

  /// The colour behind a banner that is still loading or failed; null is the
  /// flat theme surface. The profile hero (navy) passes transparent.
  final Color? placeholder;

  /// The banner's shape (1500 x 500 and 600 x 200, `identity.Profile`).
  static const double sourceAspect = 3;

  /// The widths of the full and the thumb banner: nothing is decoded larger.
  static const int fullPx = 1500;
  static const int thumbPx = 600;

  /// The physical width a 3:1 image needs to cover a [width] x [height] band
  /// at [pixelRatio]: the band's width, or more when the band is taller than
  /// 3:1 and the cover scales the image by height. 0 for an unbounded or
  /// empty band.
  static int decodeWidthFor(double width, double height, double pixelRatio) {
    if (!width.isFinite || width <= 0) return 0;
    final cover = height.isFinite
        ? math.max(width, height * sourceAspect)
        : width;
    return (cover * pixelRatio).ceil();
  }

  @override
  Widget build(BuildContext context) {
    final flat = ColoredBox(
      color: placeholder ?? Theme.of(context).colorScheme.surfaceContainerHigh,
    );
    final local = bytes;
    if (url.isEmpty && thumbUrl.isEmpty && local == null) {
      return ExcludeSemantics(child: flat);
    }
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    return ExcludeSemantics(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final needed = decodeWidthFor(
            constraints.maxWidth,
            constraints.maxHeight,
            pixelRatio,
          );
          if (local != null) {
            return Image.memory(
              local,
              fit: BoxFit.cover,
              width: double.infinity,
              height: double.infinity,
              cacheWidth: needed > 0 ? math.min(needed, fullPx) : null,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => flat,
            );
          }
          final thumb =
              url.isEmpty || (thumbUrl.isNotEmpty && needed <= thumbPx);
          final source = thumb ? thumbUrl : url;
          final sourcePx = thumb ? thumbPx : fullPx;
          return CachedNetworkImage(
            key: ValueKey(source),
            imageUrl: source,
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            memCacheWidth: needed > 0 ? math.min(needed, sourcePx) : null,
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
