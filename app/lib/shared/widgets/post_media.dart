import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../gen/dzeroth/common/v1/common.pb.dart' as common;

/// A post's attached images (0-4), rounded and bordered. One image keeps its
/// own aspect ratio (clamped to 4:5 .. 16:9 so a tall image cannot take over
/// the feed); two or more fill a fixed 16:9 grid.
///
/// Lists use `thumbUrl` only and decode it at display size. A ref with no
/// `thumbUrl` shows a placeholder and never falls back to the full image:
/// that would pull 1600 px originals into a feed (GCS egress and Class B
/// operations, review #110 M2). The detail view passes [useFullImage] to show
/// `url` instead.
class PostMedia extends StatelessWidget {
  const PostMedia({super.key, required this.media, this.useFullImage = false});

  final List<common.MediaRef> media;

  /// Show the full-size `url` (detail view). Lists leave this false.
  final bool useFullImage;

  static const _minAspect = 4 / 5;
  static const _maxAspect = 16 / 9;
  static const _gap = 2.0;

  @override
  Widget build(BuildContext context) {
    final items = media.take(4).toList();
    if (items.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    final single = items.length == 1;
    final first = items.first;
    final aspect = single && first.width > 0 && first.height > 0
        ? (first.width / first.height).clamp(_minAspect, _maxAspect)
        : _maxAspect;

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: AspectRatio(
          aspectRatio: aspect.toDouble(),
          child: _layout(items),
        ),
      ),
    );
  }

  Widget _layout(List<common.MediaRef> items) {
    Widget tile(common.MediaRef m) =>
        _MediaTile(media: m, useFullImage: useFullImage);
    switch (items.length) {
      case 1:
        return tile(items[0]);
      case 2:
        return Row(
          children: [
            Expanded(child: tile(items[0])),
            const SizedBox(width: _gap),
            Expanded(child: tile(items[1])),
          ],
        );
      case 3:
        return Row(
          children: [
            Expanded(child: tile(items[0])),
            const SizedBox(width: _gap),
            Expanded(
              child: Column(
                children: [
                  Expanded(child: tile(items[1])),
                  const SizedBox(height: _gap),
                  Expanded(child: tile(items[2])),
                ],
              ),
            ),
          ],
        );
      default:
        return Column(
          children: [
            Expanded(
              child: Row(
                children: [
                  Expanded(child: tile(items[0])),
                  const SizedBox(width: _gap),
                  Expanded(child: tile(items[1])),
                ],
              ),
            ),
            const SizedBox(height: _gap),
            Expanded(
              child: Row(
                children: [
                  Expanded(child: tile(items[2])),
                  const SizedBox(width: _gap),
                  Expanded(child: tile(items[3])),
                ],
              ),
            ),
          ],
        );
    }
  }
}

class _MediaTile extends StatelessWidget {
  const _MediaTile({required this.media, required this.useFullImage});

  final common.MediaRef media;
  final bool useFullImage;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // Lists never fall back to the full image (M2); the detail view prefers it
    // and may use the thumbnail while `url` is missing.
    final url = useFullImage
        ? (media.url.isNotEmpty ? media.url : media.thumbUrl)
        : media.thumbUrl;
    final placeholder = ColoredBox(color: colors.surfaceContainerHigh);
    return Semantics(
      image: true,
      label: media.altText.isEmpty ? 'Image' : media.altText,
      excludeSemantics: true,
      child: url.isEmpty
          ? placeholder
          : LayoutBuilder(
              builder: (context, constraints) {
                final px =
                    (constraints.maxWidth *
                            MediaQuery.devicePixelRatioOf(context))
                        .ceil();
                return CachedNetworkImage(
                  imageUrl: url,
                  fit: BoxFit.cover,
                  width: double.infinity,
                  height: double.infinity,
                  memCacheWidth: px > 0 ? px : null,
                  placeholder: (_, _) => placeholder,
                  errorWidget: (_, _, _) => ColoredBox(
                    color: colors.surfaceContainerHigh,
                    child: Icon(
                      Icons.broken_image_outlined,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                );
              },
            ),
    );
  }
}
