import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// A user avatar: the network image when [url] is set, else a person icon.
///
/// The one avatar for post cards, list rows and profile headers (reuse-first:
/// no per-feature copies). Images come through the `cached_network_image`
/// disk cache and are decoded at display size (`radius * 2` device pixels,
/// never more than [maxDecodePx]) instead of full size, which keeps long
/// lists cheap on memory. Lists should pass the 96 px author-snapshot
/// thumbnail; only the profile header has a larger source.
class AppAvatar extends StatelessWidget {
  const AppAvatar({
    super.key,
    required this.url,
    this.radius = 20,
    this.maxDecodePx = 400,
  });

  /// Avatar image URL; empty shows the fallback icon.
  final String url;
  final double radius;

  /// Upper bound for the decoded width/height in pixels.
  final int maxDecodePx;

  @override
  Widget build(BuildContext context) {
    final pixels = (radius * 2 * MediaQuery.devicePixelRatioOf(context))
        .ceil()
        .clamp(1, maxDecodePx);
    return CircleAvatar(
      radius: radius,
      backgroundImage: url.isEmpty
          ? null
          : CachedNetworkImageProvider(
              url,
              maxWidth: pixels,
              maxHeight: pixels,
            ),
      child: url.isEmpty ? Icon(Icons.person_outline, size: radius) : null,
    );
  }
}
