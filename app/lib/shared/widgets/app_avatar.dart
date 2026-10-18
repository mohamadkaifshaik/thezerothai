import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// A user avatar: the network image when [url] is set, else a person icon.
///
/// The one avatar for post cards, list rows and profile headers (reuse-first:
/// no per-feature copies). Images come through the `cached_network_image`
/// disk cache and are resized at decode time to display size (`radius * 2`
/// device pixels, never more than [maxDecodePx]) instead of full size, which keeps long
/// lists cheap on memory. Lists should pass the 96 px author-snapshot
/// thumbnail; only the profile header has a larger source.
class AppAvatar extends StatelessWidget {
  const AppAvatar({
    super.key,
    required this.url,
    this.radius = 20,
    this.maxDecodePx = 400,
    this.bytes,
  });

  /// Avatar image URL; empty shows the fallback icon.
  final String url;
  final double radius;

  /// Upper bound for the decoded width/height in pixels.
  final int maxDecodePx;

  /// A local image (for example a just-picked, unsaved avatar). When set it
  /// is shown instead of [url], decoded at display size.
  final Uint8List? bytes;

  @override
  Widget build(BuildContext context) {
    final pixels = (radius * 2 * MediaQuery.devicePixelRatioOf(context))
        .ceil()
        .clamp(1, maxDecodePx);
    final local = bytes;
    return CircleAvatar(
      radius: radius,
      backgroundImage: local != null
          ? ResizeImage(
              MemoryImage(local),
              width: pixels,
              height: pixels,
              policy: ResizeImagePolicy.fit,
            )
          : url.isEmpty
          ? null
          : ResizeImage(
              CachedNetworkImageProvider(url),
              width: pixels,
              height: pixels,
              policy: ResizeImagePolicy.fit,
            ),
      child: local == null && url.isEmpty
          ? Icon(Icons.person_outline, size: radius)
          : null,
    );
  }
}
