import 'package:cached_network_image/cached_network_image.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/theme/app_theme.dart';
import '../../../features/media/domain/image_processor.dart'
    show kPostThumbEdge;
import '../../../features/media/domain/processed_image.dart'
    show kGifContentType;
import '../../../features/settings/presentation/bloc/data_usage_cubit.dart';
import '../../../gen/dzeroth/common/v1/common.pb.dart' as common;
import 'alt_text_chip.dart';
import 'gif_badge.dart';

/// A post's attached images (0-4), X style, at the full body width (the card
/// does not indent them to the text column).
///
/// - One image: full column width at its own aspect ratio, uncropped. Only the
///   extremes are clamped: 9:16 is the tallest and 3:1 the widest frame, and
///   a picture beyond them is center-cropped. With no stored size the frame is
///   4:5 ([AppSize.postMediaDefaultAspect]). On tablet and desktop the frame is
///   at most [AppSize.postMediaMaxSingleHeight] tall; its width shrinks to keep
///   the ratio.
/// - Several: a horizontal row of tiles that all share one height
///   ([rowHeight]); each tile keeps its own aspect (width = height x aspect),
///   so widths differ. The row scrolls; a caller that lays this widget out
///   across the whole card passes [insetStart] and [insetEnd] (the card's
///   padding) so the scroll viewport reaches the card's edges while the first
///   tile lines up with the body text.
///
/// Pictures use `BoxFit.cover`, centered (a plain fit except at the clamped
/// extremes): no letterbox, no blurred background. The frame comes from the
/// stored `width`/`height` alone (4:5 when unknown), so it has its final size before any image loads. A tap
/// opens the full-screen viewer through [onOpenImage], which shows the image
/// whole.
///
/// Lists show `thumbUrl` (1080 px on its longest side for posts made since
/// the clarity change, 400 px before) and decode it at the size it is drawn
/// at, never smaller than the physical pixels the frame needs. A ref with no
/// `thumbUrl` shows a placeholder and never falls back to the full image:
/// that would pull originals into a feed (GCS egress and Class B operations,
/// review #110 M2). The one exception is [thumbSuffices] saying the thumbnail
/// is too small for the frame (a 400 px legacy thumb stretched over a
/// high-density column, or a frame wider than the 1080 px thumb): then the
/// full `url` loads with the thumbnail as its placeholder. The detail view
/// passes [useFullImage] to show `url` instead. Data saver, or High-quality
/// images set to Never (or Wi-Fi only on mobile data), turns that exception
/// off in the feed: the thumbnail only (Settings > Data usage); the detail
/// view and the photo viewer still load the full image.
///
/// A GIF (`MediaRef.content_type == image/gif`) fills the same frame: its
/// still `thumbUrl` with a "GIF" badge and a play control, and the full file
/// is fetched only after a tap (a tap again stops it). Nothing autoplays, so
/// reduced motion and a data saver are respected by construction.
class PostMedia extends StatelessWidget {
  const PostMedia({
    super.key,
    required this.media,
    this.useFullImage = false,
    this.onOpenImage,
    this.showPageIndicator = false,
    this.insetStart = 0,
    this.insetEnd = 0,
  });

  /// The padding the caller leaves at each side of the body column inside the
  /// width this widget is given: the body column is the given width minus
  /// these. The several-images row scrolls through them (edge to edge, as on
  /// X) with its first tile on the column; a single image sits in the column.
  /// Zero (the default) means the given width is the column.
  final double insetStart;
  final double insetEnd;

  final List<common.MediaRef> media;
  final ValueChanged<int>? onOpenImage;

  /// Dots under the row with "Image 2 of 4" for screen readers. Callers
  /// turn it on only for a post with no text, where nothing else tells the
  /// reader there are more images to swipe to. Ignored for a single image.
  final bool showPageIndicator;

  /// True when [text] is empty after trimming, so a whitespace-only post is
  /// treated like an image-only one.
  static bool hasNoText(String text) => text.trim().isEmpty;

  /// Show the full-size `url` (detail view). Lists leave this false.
  final bool useFullImage;

  /// The aspect ratio of one item's frame: its stored size clamped to 9:16
  /// .. 3:1, or 4:5 when the size is unknown (refs stored before sizes were
  /// recorded).
  static double frameAspect(common.MediaRef ref) =>
      ref.width > 0 && ref.height > 0
      ? (ref.width / ref.height)
            .clamp(
              AppSize.postMediaPortraitAspect,
              AppSize.postMediaLandscapeAspect,
            )
            .toDouble()
      : AppSize.postMediaDefaultAspect;

  /// The thumbnail's longest edge for a ref whose stored (full) longest edge
  /// is [longest]. The ref does not carry the thumb's size, so it is inferred
  /// from the full one: uploads made since the clarity change are capped at
  /// 2048 px (thumb 1080), earlier ones at 1600 px (thumb 400). A longest edge
  /// of 1600 or less is therefore treated as a legacy 400 px thumb (a new
  /// small photo then loads its full file, which is no larger than 1600 px);
  /// a photo of 400 px or less has a thumb the same size as the full image.
  static int thumbEdgeFor(int longest) {
    if (longest <= 400) return longest;
    return longest > 1600 ? kPostThumbEdge : 400;
  }

  /// Physical pixels needed across the image's width to fill a [frame] with
  /// `BoxFit.cover` at [dpr]: a panorama cropped at the sides is drawn wider
  /// than the frame, so the frame's width alone would under-size the decode.
  static int neededPixels(Size frame, double imageAspect, double dpr) =>
      (math.max(frame.width, frame.height * imageAspect) * dpr).ceil();

  /// Whether `thumbUrl` has enough pixels for a frame that needs [needed]
  /// across the image's width, else the feed loads `url`. Unknown stored sizes
  /// are not trusted (treated as legacy).
  static bool thumbSuffices(common.MediaRef ref, int needed) {
    if (ref.width <= 0 || ref.height <= 0) return false;
    final longest = math.max(ref.width, ref.height);
    final edge = thumbEdgeFor(longest);
    if (edge >= longest) return true; // thumb is the full image
    return needed <= ref.width * edge / longest;
  }

  /// A single frame's size in a [column] wide body, for a [wide] (tablet or
  /// desktop) or phone window. The width is the column's; wide windows cap
  /// the height and shrink the width with it.
  static Size singleSize(
    common.MediaRef ref, {
    required double column,
    required bool wide,
  }) {
    final aspect = frameAspect(ref);
    final height = column / aspect;
    if (wide && height > AppSize.postMediaMaxSingleHeight) {
      return Size(
        AppSize.postMediaMaxSingleHeight * aspect,
        AppSize.postMediaMaxSingleHeight,
      );
    }
    return Size(column, height);
  }

  /// The shared height of the several-images row in a [column] wide body:
  /// `min(1.25 x column, 0.59 x column / meanAspect)`, where `meanAspect` is
  /// the mean of the tiles' [frameAspect]s (each already clamped to 9:16 ..
  /// 3:1), then at least `0.5 x column` (so a row of landscape pictures is not
  /// tiny) and, on a [wide] window, at most
  /// [AppSize.postMediaMaxSingleHeight]. Measured on X at column 259: three
  /// 9:16 tiles give 272.
  static double rowHeight(
    List<common.MediaRef> items, {
    required double column,
    required bool wide,
  }) {
    final mean = items.map(frameAspect).reduce((a, b) => a + b) / items.length;
    var height = math.min(
      column * AppSize.postMediaRowMaxHeightFraction,
      column * AppSize.postMediaRowAreaFraction / mean,
    );
    height = math.max(height, column * AppSize.postMediaRowMinHeightFraction);
    if (wide) height = math.min(height, AppSize.postMediaMaxSingleHeight);
    return height;
  }

  /// One tile's size in a row of [height]: width = height x its own aspect.
  static Size tileSize(common.MediaRef ref, {required double height}) =>
      Size(height * frameAspect(ref), height);

  @override
  Widget build(BuildContext context) {
    final items = media.take(4).toList();
    if (items.isEmpty) return const SizedBox.shrink();
    final wide = MediaQuery.sizeOf(context).width >= AppBreakpoints.mobile;
    final colors = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final column = constraints.maxWidth - insetStart - insetEnd;
        Widget tile(int index, Size size, double radius) => SizedBox.fromSize(
          size: size,
          // The hairline is drawn over the picture so it adds nothing to the
          // frame's size.
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(color: colors.outlineVariant),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(radius),
              child: _MediaTile(
                media: items[index],
                useFullImage: useFullImage,
                onOpen: onOpenImage == null ? null : () => onOpenImage!(index),
              ),
            ),
          ),
        );
        if (items.length == 1) {
          return Padding(
            padding: EdgeInsetsDirectional.only(
              start: insetStart,
              end: insetEnd,
            ),
            child: Align(
              alignment: AlignmentDirectional.topStart,
              heightFactor: 1,
              child: tile(
                0,
                singleSize(items.first, column: column, wide: wide),
                AppRadius.postMedia,
              ),
            ),
          );
        }
        final height = rowHeight(items, column: column, wide: wide);
        return _MediaStrip(
          sizes: [for (final m in items) tileSize(m, height: height)],
          showIndicator: showPageIndicator,
          insetStart: insetStart,
          insetEnd: insetEnd,
          tile: (index, size) => tile(index, size, AppRadius.postMediaTile),
        );
      },
    );
  }
}

/// Several images: tiles of one height in a lazy horizontal list spanning the
/// whole given width; [insetStart] / [insetEnd] are its padding, so the first
/// tile sits on the body column and the tiles scroll out through the card's
/// edges. Optionally the dots below (on the column).
class _MediaStrip extends StatefulWidget {
  const _MediaStrip({
    required this.sizes,
    required this.showIndicator,
    required this.insetStart,
    required this.insetEnd,
    required this.tile,
  });

  final List<Size> sizes;
  final bool showIndicator;
  final double insetStart;
  final double insetEnd;
  final Widget Function(int index, Size size) tile;

  @override
  State<_MediaStrip> createState() => _MediaStripState();
}

class _MediaStripState extends State<_MediaStrip> {
  int _page = 0;

  /// The tile whose start is nearest the scroll offset (offset 0 is tile 0:
  /// the inset is the list's start padding).
  bool _onScroll(ScrollNotification note) {
    if (note.metrics.axis != Axis.horizontal) return false;
    var best = 0;
    var bestDistance = double.infinity;
    var start = 0.0;
    for (var i = 0; i < widget.sizes.length; i++) {
      final distance = (note.metrics.pixels - start).abs();
      if (distance < bestDistance) {
        best = i;
        bestDistance = distance;
      }
      start += widget.sizes[i].width + AppSize.postMediaRowGap;
    }
    if (best != _page) setState(() => _page = best);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.sizes.length;
    final height = widget.sizes.first.height;
    final list = ListView.builder(
      scrollDirection: Axis.horizontal,
      primary: false,
      itemCount: count,
      padding: EdgeInsetsDirectional.only(
        start: widget.insetStart,
        end: widget.insetEnd,
      ),
      itemBuilder: (context, index) => Padding(
        padding: EdgeInsetsDirectional.only(
          end: index == count - 1 ? 0 : AppSize.postMediaRowGap,
        ),
        child: widget.tile(index, widget.sizes[index]),
      ),
    );
    final strip = SizedBox(height: height, child: list);
    if (!widget.showIndicator) return strip;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: strip,
        ),
        Padding(
          padding: EdgeInsetsDirectional.only(
            start: widget.insetStart,
            end: widget.insetEnd,
          ),
          child: _PageDots(count: count, page: _page),
        ),
      ],
    );
  }
}

/// One semantics node ("Image 2 of 4") announced as it changes; the dots are
/// decoration for sighted users and stay out of the tree.
class _PageDots extends StatelessWidget {
  const _PageDots({required this.count, required this.page});

  final int count;
  final int page;

  static const _dot = 6.0;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      liveRegion: true,
      label: 'Image ${page + 1} of $count',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.only(top: AppSpacing.sm),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < count; i++)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.xs / 2,
                ),
                child: DecoratedBox(
                  key: ValueKey(i == page ? 'media-dot-current' : 'media-dot'),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i == page
                        ? colors.onSurface
                        : colors.onSurfaceVariant.withValues(alpha: 0.4),
                  ),
                  child: const SizedBox.square(dimension: _dot),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MediaTile extends StatelessWidget {
  const _MediaTile({
    required this.media,
    required this.useFullImage,
    this.onOpen,
  });

  final common.MediaRef media;
  final bool useFullImage;

  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    if (media.contentType == kGifContentType) {
      return _GifTile(media: media);
    }
    final colors = Theme.of(context).colorScheme;
    // Lists use the thumbnail and load `url` only when it is too small for
    // the frame (see [PostMedia.thumbSuffices]); a ref with no thumbnail
    // never falls back to the full image (M2). The detail view prefers `url`
    // and may use the thumbnail while it is missing.
    final placeholder = ColoredBox(color: colors.surfaceContainerHigh);
    final Widget picture;
    if (useFullImage) {
      final url = media.url.isNotEmpty ? media.url : media.thumbUrl;
      picture = url.isEmpty
          ? placeholder
          : _networkImage(url, colors, media: media);
    } else if (media.thumbUrl.isEmpty) {
      picture = placeholder;
    } else {
      picture = _feedImage(media, colors);
    }
    // Its own node: inside a PageView the image and its ALT chip would merge
    // into one, and a screen reader would lose the description.
    final image = Semantics(
      container: true,
      image: true,
      label: media.altText.isEmpty ? 'Image' : media.altText,
      excludeSemantics: true,
      child: picture,
    );
    final open = onOpen;
    return _withAltChip(
      open == null
          ? image
          // The ink (ripple, hover, keyboard focus) paints on the nearest
          // Material below the InkWell: under the image it was hidden by the
          // picture, so the InkWell sits on its own transparent Material over
          // it. The button is its own node beside the image's (which keeps
          // the alt text), and the ALT chip stays above both.
          : Stack(
              fit: StackFit.expand,
              children: [
                image,
                Positioned.fill(
                  child: Material(
                    type: MaterialType.transparency,
                    child: Semantics(
                      button: true,
                      label: 'Open image',
                      child: InkWell(onTap: open),
                    ),
                  ),
                ),
              ],
            ),
      media.altText,
    );
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

/// Width / height of the stored picture; 4:5 (the frame's default) when the
/// size is unknown.
double _aspectOf(common.MediaRef media) => media.width > 0 && media.height > 0
    ? media.width / media.height
    : AppSize.postMediaDefaultAspect;

/// The feed picture: the thumbnail, or the full file when the thumbnail has
/// too few pixels for the frame ([PostMedia.thumbSuffices]), the thumbnail
/// showing while it loads.
Widget _feedImage(common.MediaRef media, ColorScheme colors) {
  return LayoutBuilder(
    builder: (context, constraints) {
      final dpr = MediaQuery.devicePixelRatioOf(context);
      final needed = PostMedia.neededPixels(
        constraints.biggest,
        _aspectOf(media),
        dpr,
      );
      // Settings > Data usage: Data saver, "Never", or "Wi-Fi only" on mobile
      // data keep the feed on the thumbnail (true without the cubit).
      final allowFull = context.select<DataUsageCubit?, bool>(
        (cubit) => cubit?.state.feedMayLoadFull ?? true,
      );
      final useFull =
          allowFull &&
          media.url.isNotEmpty &&
          !PostMedia.thumbSuffices(media, needed);
      if (!useFull) {
        return _cached(media.thumbUrl, colors, needed);
      }
      return _cached(
        media.url,
        colors,
        needed,
        placeholder: _cached(media.thumbUrl, colors, needed),
      );
    },
  );
}

/// A cached network image decoded at [width] physical pixels across (never
/// upscaled); [placeholder] shows while it loads.
Widget _cached(
  String url,
  ColorScheme colors,
  int width, {
  Widget? placeholder,
}) {
  final blank = ColoredBox(color: colors.surfaceContainerHigh);
  return ColoredBox(
    color: colors.surfaceContainerHigh,
    child: CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      alignment: Alignment.center,
      width: double.infinity,
      height: double.infinity,
      memCacheWidth: width > 0 ? width : null,
      placeholder: (_, _) => placeholder ?? blank,
      errorWidget: (_, _, _) => ColoredBox(
        color: colors.surfaceContainerHigh,
        child: Icon(
          Icons.broken_image_outlined,
          color: colors.onSurfaceVariant,
        ),
      ),
    ),
  );
}

/// A cached network image decoded at the width it is drawn at (a GIF still
/// or the detail view's full image); [placeholder] shows while it loads.
Widget _networkImage(
  String url,
  ColorScheme colors, {
  required common.MediaRef media,
  Widget? placeholder,
}) {
  return LayoutBuilder(
    builder: (context, constraints) {
      // A picture cropped at the sides (a panorama in a 3:1 frame) is drawn
      // wider than the frame; decoding at the frame's width would upscale it.
      final px = PostMedia.neededPixels(
        constraints.biggest,
        _aspectOf(media),
        MediaQuery.devicePixelRatioOf(context),
      );
      return _cached(url, colors, px, placeholder: placeholder);
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
        : _networkImage(media.thumbUrl, colors, media: media);
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
            _playing
                ? _networkImage(
                    media.url,
                    colors,
                    media: media,
                    placeholder: still,
                  )
                : still,
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
