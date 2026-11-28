import 'package:cached_network_image/cached_network_image.dart';

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/theme/app_theme.dart';
import '../../../features/posts/data/posts_repository.dart';
import '../../../features/media/domain/media_feature_flag.dart'
    show kMaxPostImages;
import '../../../features/media/domain/image_processor.dart'
    show kPostThumbEdge;
import '../../../features/media/domain/unusual_aspect.dart';
import '../../../features/media/domain/processed_image.dart'
    show kGifContentType, kVideoContentType;
import '../../../features/settings/presentation/bloc/data_usage_cubit.dart';
import '../../../gen/dzeroth/common/v1/common.pb.dart' as common;
import 'alt_text_chip.dart';
import 'gif_badge.dart';
import 'post_video.dart';
import 'post_media_navigation.dart';

/// A post's attached images (0-20), X style, at the full body width (the card
/// does not indent them to the text column).
///
/// - One image: full column width at its own aspect ratio, uncropped. Only the
///   extremes are clamped: 9:16 is the tallest and 3:1 the widest frame, and
///   a picture beyond them is center-cropped. With no stored size the frame is
///   4:5 ([AppSize.postMediaDefaultAspect]). On tablet and desktop the frame is
///   at most [AppSize.postMediaMaxSingleHeight] tall; its width shrinks to keep
///   the ratio.
/// - Several: a horizontal row of tiles that all share one height
///   ([rowHeight]); each tile keeps its own aspect (width = height x aspect,
///   uncropped, even for a very narrow strip),
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
/// full `url` loads. Most tiles show the thumbnail while waiting. Thin strips
/// request it only if the original fails, to avoid competing downloads. The detail view
/// passes [useFullImage] to show `url` instead. Data saver, or High-quality
/// images set to Never (or Wi-Fi only on mobile data), turns that exception
/// off in the feed: the thumbnail only (Settings > Data usage); the detail
/// view and the photo viewer still load the full image.
///
/// A GIF (`MediaRef.content_type == image/gif`) fills the same frame: its
/// still `thumbUrl` with a "GIF" badge and a play control, and the full file
/// is fetched only after a tap (a tap again stops it). Nothing autoplays, so
/// reduced motion and a data saver are respected by construction.
/// The narrowest stored aspect (width / height) a tile trusts: 1:200. A real
/// strip (X shows 38 x 2048 art uncropped, aspect 0.0186) keeps its own aspect
/// in a row; a missing size or anything narrower reads as unknown (4:5). The
/// wide end is unchanged (50:1 is unknown).
const double kMinTrustedAspect = 1 / 200;

class PostMedia extends StatelessWidget {
  const PostMedia({
    super.key,
    required this.media,
    this.postId,
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
  final String? postId;
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

  /// A tile's aspect in a row (width / height). Narrow tiles keep their own
  /// aspect, uncropped, down to [kMinTrustedAspect] (1:200); a tile wider than
  /// 3:1 is held at 3:1 (and center-cropped), so a panorama cannot collapse
  /// the row's height. A ref whose aspect is narrower than 1:200 or wider
  /// than 50:1 is treated as unknown (4:5), as is one with no stored size.
  static double rowAspect(common.MediaRef ref) {
    if (ref.width <= 0 || ref.height <= 0) {
      return AppSize.postMediaDefaultAspect;
    }
    final aspect = ref.width / ref.height;
    if (aspect < kMinTrustedAspect || aspect > 50) {
      return AppSize.postMediaDefaultAspect;
    }
    return math.min(aspect, AppSize.postMediaLandscapeAspect);
  }

  /// The shared height of the several-images row in a [column] wide body
  /// (measured on X):
  /// - two tiles fill the column exactly: `(column - gap) / (a0 + a1)`;
  /// - three or more: `0.591 x column / mean(a0, a1)`, the mean of the FIRST
  ///   TWO tiles' aspects;
  /// - never above `1.243 x column` at any window width (X's rows are not
  ///   held to the single-image 520 dp cap: 644 dp at a 518 dp column), and
  ///   never below [AppSpacing.minTapTarget] so a row of panoramas stays
  ///   tappable.
  /// Aspects are the tiles' [rowAspect]s.
  static double rowHeight(
    List<common.MediaRef> items, {
    required double column,
  }) {
    final a0 = rowAspect(items[0]);
    final a1 = items.length > 1 ? rowAspect(items[1]) : a0;
    var height = items.length == 2
        ? (column - AppSize.postMediaRowGap) / (a0 + a1)
        : column * AppSize.postMediaRowAreaFraction / ((a0 + a1) / 2);
    height = math.min(height, column * AppSize.postMediaRowMaxHeightFraction);
    return math.max(height, AppSpacing.minTapTarget);
  }

  /// One tile's size in a row of [height]: width = height x its own aspect,
  /// so the picture is never cropped.
  static Size tileSize(common.MediaRef ref, {required double height}) =>
      Size(height * rowAspect(ref), height);

  @override
  Widget build(BuildContext context) {
    final id = postId;
    if (id != null &&
        media.any(
          (ref) => _needsFreshLink(ref.url) || _needsFreshLink(ref.thumbUrl),
        )) {
      return _RefreshPostMedia(
        key: ValueKey(id),
        load: () async =>
            (await context.read<PostsRepository>().getPost(id)).post.media,
        placeholder: _buildMedia(context, media, reserveOnly: true),
        render: (refs) => _buildMedia(context, refs),
      );
    }
    return _buildMedia(context, media);
  }

  Widget _buildMedia(
    BuildContext context,
    List<common.MediaRef> refs, {
    bool reserveOnly = false,
  }) {
    final items = refs.take(kMaxPostImages).toList();
    if (items.isEmpty) return const SizedBox.shrink();
    VoidCallback? open(int index) {
      final id = postId;
      if (items[index].contentType == kVideoContentType &&
          id != null &&
          id.isNotEmpty) {
        return () => openPostVideo(context, id, index);
      }
      return onOpenImage == null ? null : () => onOpenImage!(index);
    }

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
              child: reserveOnly
                  ? ColoredBox(color: colors.surfaceContainerHigh)
                  : _MediaTile(
                      media: items[index],
                      useFullImage: useFullImage,
                      onOpen: open(index),
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
        final height = rowHeight(items, column: column);
        return _MediaStrip(
          column: column,
          sizes: [for (final m in items) tileSize(m, height: height)],
          showIndicator: showPageIndicator,
          insetStart: insetStart,
          insetEnd: insetEnd,
          onOpen: reserveOnly || onOpenImage == null
              ? null
              : (i) => open(i)?.call(),
          tile: (index, size) => tile(index, size, AppRadius.postMediaTile),
        );
      },
    );
  }
}

// Offline feed rows can outlive a signed URL or predate private storage.
bool _needsFreshLink(String raw) {
  final uri = Uri.tryParse(raw);
  if (uri == null || uri.host != 'storage.googleapis.com') return false;
  final stamp = uri.queryParameters['X-Goog-Date'];
  if (stamp == null) {
    return uri.pathSegments.length == 3 &&
        uri.pathSegments.first.endsWith('-media') &&
        uri.pathSegments[1] == 'm';
  }
  final issued = DateTime.tryParse(stamp);
  final seconds = int.tryParse(uri.queryParameters['X-Goog-Expires'] ?? '');
  return issued != null &&
      seconds != null &&
      !DateTime.now().isBefore(issued.add(Duration(seconds: seconds)));
}

class _RefreshPostMedia extends StatefulWidget {
  const _RefreshPostMedia({
    super.key,
    required this.load,
    required this.placeholder,
    required this.render,
  });
  final Widget placeholder;
  final Future<List<common.MediaRef>> Function() load;
  final Widget Function(List<common.MediaRef>) render;

  @override
  State<_RefreshPostMedia> createState() => _RefreshPostMediaState();
}

class _RefreshPostMediaState extends State<_RefreshPostMedia> {
  late Future<List<common.MediaRef>> request;
  @override
  void initState() {
    super.initState();
    request = widget.load();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<common.MediaRef>>(
    future: request,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return Stack(
          alignment: Alignment.center,
          children: [
            widget.placeholder,
            TextButton(
              onPressed: () {
                final next = widget.load();
                setState(() {
                  request = next;
                });
              },
              child: const Text('Reload media'),
            ),
          ],
        );
      }
      return snapshot.hasData
          ? widget.render(snapshot.requireData)
          : widget.placeholder;
    },
  );
}

/// Several images: tiles of one height in a lazy horizontal list spanning the
/// whole given width; [insetStart] / [insetEnd] are its padding, so the first
/// tile sits on the body column and the tiles scroll out through the card's
/// edges. Optionally the dots below (on the column).
class _MediaStrip extends StatefulWidget {
  const _MediaStrip({
    required this.column,
    required this.sizes,
    required this.showIndicator,
    required this.insetStart,
    required this.insetEnd,
    required this.tile,
    this.onOpen,
  });

  /// Opens the viewer at an index; with it, a tile narrower than the 48 dp
  /// target gets a padded hit area (see [_MediaStripState]).
  final ValueChanged<int>? onOpen;
  final double column;
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
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Hit areas for tiles narrower than the 48 dp target, over the picture:
  /// each runs from the middle of the gap before it to the middle of the gap
  /// after it (so neighbours never overlap), and the first and last extend
  /// half a target outward. A tap in the gaps or just beside a strip opens the
  /// nearest tile. The tiles themselves keep their own semantics nodes.
  List<Widget> _hitAreas(double offset, double height) {
    final open = widget.onOpen;
    if (open == null) return const [];
    const gap = AppSize.postMediaRowGap;
    const reach = AppSpacing.minTapTarget / 2;
    final count = widget.sizes.length;
    final out = <Widget>[];
    var left = widget.insetStart - offset;
    for (var i = 0; i < count; i++) {
      final width = widget.sizes[i].width;
      if (width < AppSpacing.minTapTarget) {
        final start = i == 0 ? left - reach : left - gap / 2;
        final end = i == count - 1
            ? left + width + reach
            : left + width + gap / 2;
        out.add(
          PositionedDirectional(
            start: start,
            width: end - start,
            top: 0,
            height: height,
            child: ExcludeSemantics(
              child: GestureDetector(
                // Translucent: the drag still reaches the row below, so a
                // thin tile scrolls it; only a tap is taken here.
                behavior: HitTestBehavior.translucent,
                onTap: () => open(i),
              ),
            ),
          ),
        );
      }
      left += width + gap;
    }
    return out;
  }

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
    // Scrolled to the end, the last tile is the current one even when the
    // row cannot bring its start to the viewport's start.
    if (note.metrics.pixels >= note.metrics.maxScrollExtent - 0.5 &&
        note.metrics.maxScrollExtent > 0) {
      best = widget.sizes.length - 1;
    }
    if (best != _page) setState(() => _page = best);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.sizes.length;
    final height = widget.sizes.first.height;
    final narrow = widget.sizes.any((s) => s.width < AppSpacing.minTapTarget);
    final contentWidth = widget.sizes.fold<double>(
      (count - 1) * AppSize.postMediaRowGap,
      (sum, size) => sum + size.width,
    );
    final fits = narrow && contentWidth <= widget.column;
    Widget tile(int index) => Padding(
      padding: EdgeInsetsDirectional.only(
        end: index == count - 1 ? 0 : AppSize.postMediaRowGap,
      ),
      child: widget.tile(index, widget.sizes[index]),
    );
    final insets = EdgeInsetsDirectional.only(
      start: widget.insetStart,
      end: widget.insetEnd,
    );
    // A group of thin slices often fits with room to spare. Paint those
    // pictures directly, without a composited scrolling viewport across the
    // empty part of the card. Keep the lazy list for rows that can scroll.
    final pictures = fits
        ? Padding(
            padding: insets,
            child: Row(children: [for (var i = 0; i < count; i++) tile(i)]),
          )
        : ListView.builder(
            controller: _scroll,
            scrollDirection: Axis.horizontal,
            primary: false,
            itemCount: count,
            padding: insets,
            itemBuilder: (context, index) => tile(index),
          );
    final strip = SizedBox(
      height: height,
      child: !narrow || widget.onOpen == null
          ? pictures
          : Stack(
              fit: StackFit.expand,
              children: [
                pictures,
                if (fits)
                  ..._hitAreas(0, height)
                else
                  ListenableBuilder(
                    listenable: _scroll,
                    builder: (context, _) => Stack(
                      clipBehavior: Clip.none,
                      children: _hitAreas(
                        _scroll.hasClients ? _scroll.offset : 0,
                        height,
                      ),
                    ),
                  ),
              ],
            ),
    );
    if (!widget.showIndicator) return strip;
    final page = fits ? 0 : _page.clamp(0, count - 1);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: Stack(
            children: [
              strip,
              PositionedDirectional(
                top: AppSpacing.sm,
                end: widget.insetEnd + AppSpacing.sm,
                child: IgnorePointer(
                  child: ExcludeSemantics(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: AppPalette.photoScrim,
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.sm,
                          vertical: AppSpacing.xs,
                        ),
                        child: Text(
                          '${page + 1}/$count',
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(color: AppPalette.white),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: EdgeInsetsDirectional.only(
            start: widget.insetStart,
            end: widget.insetEnd,
          ),
          child: _PageDots(count: count, page: page),
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
  static const _maxVisible = 5;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final visible = math.min(count, _maxVisible);
    final first = (page - visible ~/ 2).clamp(0, count - visible);
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
            for (var i = first; i < first + visible; i++)
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
    if (media.contentType == kVideoContentType) {
      final colors = Theme.of(context).colorScheme;
      return _withAltChip(
        PostVideo(
          key: ValueKey(media.url),
          url: media.url,
          onOpen: onOpen,
          labels: media.videoLabels,
          poster: media.thumbUrl.isEmpty
              ? ColoredBox(color: colors.surfaceContainerHigh)
              : _networkImage(media.thumbUrl, colors, media: media),
        ),
        media.altText,
      );
    }
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
/// size is unknown or absurd.
double _aspectOf(common.MediaRef media) {
  if (media.width <= 0 || media.height <= 0) {
    return AppSize.postMediaDefaultAspect;
  }
  final aspect = media.width / media.height;
  // An absurd stored size is not trusted (it would ask for a huge decode).
  return aspect < kMinTrustedAspect || aspect > 50
      ? AppSize.postMediaDefaultAspect
      : aspect;
}

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
      // A row of narrow originals is already small. Fetching a second image
      // per strip competes with the pictures the feed is trying to display.
      final thumbnail = _cached(media.thumbUrl, colors, needed);
      if (constraints.maxWidth < AppSpacing.minTapTarget &&
          unusualShapeOf(width: media.width, height: media.height) ==
              UnusualShape.narrow) {
        return _cached(media.url, colors, needed, fallback: thumbnail);
      }
      return _cached(media.url, colors, needed, placeholder: thumbnail);
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
  Widget? fallback,
}) {
  final blank = ColoredBox(color: colors.surfaceContainerHigh);
  return ColoredBox(
    color: colors.surfaceContainerHigh,
    child: CachedNetworkImage(
      imageUrl: url,
      fadeInDuration: Duration.zero,
      fadeOutDuration: Duration.zero,
      fit: BoxFit.cover,
      alignment: Alignment.center,
      width: double.infinity,
      height: double.infinity,
      memCacheWidth: width > 0 ? width : null,
      placeholder: (_, _) => placeholder ?? blank,
      errorWidget: (_, _, _) =>
          fallback ??
          ColoredBox(
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
