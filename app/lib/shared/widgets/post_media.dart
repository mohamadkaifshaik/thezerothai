import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../features/media/domain/processed_image.dart' show kGifContentType;
import '../../gen/dzeroth/common/v1/common.pb.dart' as common;
import 'alt_text_chip.dart';
import 'gif_badge.dart';

/// A post's attached images (0-4), rounded and bordered. One image keeps its
/// own aspect ratio (clamped to 4:5 .. 16:9 so a tall image cannot take over
/// the feed); two or more fill a fixed 16:9 grid.
///
/// Lists use `thumbUrl` only and decode it at display size. A ref with no
/// `thumbUrl` shows a placeholder and never falls back to the full image:
/// that would pull 1600 px originals into a feed (GCS egress and Class B
/// operations, review #110 M2). The detail view passes [useFullImage] to show
/// `url` instead.
///
/// A GIF (`MediaRef.content_type == image/gif`, ADR-0029 F10) is different in
/// both views: it shows its still `thumbUrl` with a "GIF" badge and a play
/// control, and the full file is fetched only after a tap (a tap again stops
/// it). Nothing autoplays, so reduced motion and a data saver are respected
/// by construction.
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
    if (media.contentType == kGifContentType) return _GifTile(media: media);
    final colors = Theme.of(context).colorScheme;
    // Lists never fall back to the full image (M2); the detail view prefers it
    // and may use the thumbnail while `url` is missing.
    final url = useFullImage
        ? (media.url.isNotEmpty ? media.url : media.thumbUrl)
        : media.thumbUrl;
    final placeholder = ColoredBox(color: colors.surfaceContainerHigh);
    final image = Semantics(
      image: true,
      label: media.altText.isEmpty ? 'Image' : media.altText,
      excludeSemantics: true,
      child: url.isEmpty ? placeholder : _networkImage(url, colors),
    );
    return _withAltChip(image, media.altText);
  }
}

/// The ALT chip is a sibling of the image's semantics node (which excludes
/// its subtree), so a screen reader reaches both.
Widget _withAltChip(Widget image, String alt) {
  if (alt.isEmpty) return image;
  return Stack(
    fit: StackFit.expand,
    children: [
      image,
      PositionedDirectional(bottom: 0, start: 0, child: AltTextChip(text: alt)),
    ],
  );
}

/// A cached network image decoded at its display size; [placeholder] shows
/// while it loads.
Widget _networkImage(String url, ColorScheme colors, {Widget? placeholder}) {
  final blank = ColoredBox(color: colors.surfaceContainerHigh);
  return LayoutBuilder(
    builder: (context, constraints) {
      final px = (constraints.maxWidth * MediaQuery.devicePixelRatioOf(context))
          .ceil();
      return CachedNetworkImage(
        imageUrl: url,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        memCacheWidth: px > 0 ? px : null,
        placeholder: (_, _) => placeholder ?? blank,
        errorWidget: (_, _, _) => ColoredBox(
          color: colors.surfaceContainerHigh,
          child: Icon(
            Icons.broken_image_outlined,
            color: colors.onSurfaceVariant,
          ),
        ),
      );
    },
  );
}

/// A GIF in a post: the still with a badge and a play control; the full file
/// is requested only once the user taps play. A tap on the playing GIF
/// returns to the still (the user's pause). The whole tile is the target
/// (far over 48dp); the ALT chip stays a separate control.
class _GifTile extends StatefulWidget {
  const _GifTile({required this.media});

  final common.MediaRef media;

  @override
  State<_GifTile> createState() => _GifTileState();
}

class _GifTileState extends State<_GifTile> {
  bool _playing = false;

  common.MediaRef get media => widget.media;

  void _toggle() {
    // Nothing to play without the full file (the still stays).
    if (media.url.isEmpty) return;
    setState(() => _playing = !_playing);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final blank = ColoredBox(color: colors.surfaceContainerHigh);
    final still = media.thumbUrl.isEmpty
        ? blank
        : _networkImage(media.thumbUrl, colors);
    final alt = media.altText;
    final canPlay = media.url.isNotEmpty;
    final label = [
      if (alt.isNotEmpty) alt,
      if (_playing) 'GIF, playing' else if (canPlay) 'GIF, play' else 'GIF',
    ].join(', ');
    final control = Semantics(
      button: canPlay,
      image: true,
      label: label,
      hint: canPlay
          ? (_playing ? 'Double tap to stop' : 'Double tap to play')
          : null,
      excludeSemantics: true,
      onTap: canPlay ? _toggle : null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: canPlay ? _toggle : null,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Only now is the full URL requested; the still shows meanwhile.
            if (_playing)
              _networkImage(media.url, colors, placeholder: still)
            else
              still,
            if (!_playing && canPlay)
              Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.surface.withValues(alpha: 0.8),
                    shape: BoxShape.circle,
                    border: Border.all(color: colors.outlineVariant),
                  ),
                  child: SizedBox.square(
                    dimension: AppSpacing.minTapTarget,
                    child: Icon(
                      Icons.play_arrow_rounded,
                      size: AppIconSize.lg,
                      color: colors.onSurface,
                    ),
                  ),
                ),
              ),
            const PositionedDirectional(
              bottom: AppSpacing.sm,
              end: AppSpacing.sm,
              child: GifBadge(),
            ),
          ],
        ),
      ),
    );
    return _withAltChip(control, alt);
  }
}
