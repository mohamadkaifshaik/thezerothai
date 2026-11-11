import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/context_pane.dart';
import '../../../../gen/dzeroth/common/v1/common.pb.dart' as common;
import '../../../../gen/dzeroth/posts/v1/posts.pbenum.dart' show PostKind;
import '../../../../shared/widgets/post/gif_badge.dart';
import '../../../media/domain/processed_image.dart' show kGifContentType;
import '../../../timeline/data/timeline_store.dart';
import '../../../timeline/presentation/bloc/timeline_state.dart';

/// The title of the media strip: the name of the Media tab it opens.
const kProfileMediaTitle = 'Media';

/// The most images the strip shows (two rows of three).
const kProfileMediaStripMax = 6;

/// Images per row of the strip.
const _columns = 3;

/// Gap between two tiles.
const _gap = AppSpacing.xs;

/// One image of the strip: the post it belongs to and its 0-based place in
/// that post's images.
@immutable
class ProfileMediaTile {
  const ProfileMediaTile({
    required this.postId,
    required this.index,
    required this.media,
  });

  final String postId;
  final int index;
  final common.MediaRef media;
}

/// The first [max] images of a profile's Media feed, newest post first and in
/// each post's own order. Gaps, reposts (never in that feed) and images with
/// no thumbnail (a list never falls back to the full image) are skipped.
List<ProfileMediaTile> profileMediaTiles(
  List<TimelineEntry> entries, {
  int max = kProfileMediaStripMax,
}) {
  final tiles = <ProfileMediaTile>[];
  for (final entry in entries) {
    final post = entry.postView?.post;
    if (post == null || post.kind == PostKind.POST_KIND_REPOST) continue;
    for (var i = 0; i < post.media.length && i < 4; i++) {
      final media = post.media[i];
      if (media.thumbUrl.isEmpty) continue;
      tiles.add(ProfileMediaTile(postId: post.postId, index: i, media: media));
      if (tiles.length >= max) return tiles;
    }
  }
  return tiles;
}

/// Band B's media strip on a profile (tablet plan section 4.1, Profile: "P:
/// profile | Media strip + You might like"): the profile's latest images
/// from its own Media tab feed, under a "Media" heading, with "See all" to
/// open that tab. Built over the page's Media feed ([state]), so it sends no
/// call of its own.
///
/// Draws nothing when there is nothing to show: no images, a failed or
/// refused feed, a protected or unavailable author. While the first page
/// loads it is [ProfileMediaStripPlaceholder].
class ProfileMediaStrip extends StatelessWidget {
  const ProfileMediaStrip({
    super.key,
    required this.state,
    required this.onOpen,
    required this.onSeeAll,
  });

  final TimelineState state;

  /// Opens one image (the post's photo viewer).
  final void Function(ProfileMediaTile tile) onOpen;

  /// Opens the Media tab.
  final VoidCallback onSeeAll;

  @override
  Widget build(BuildContext context) {
    if (state.authorProtected || state.unavailable) {
      return const SizedBox.shrink();
    }
    if (state.status == TimelineStatus.loading) {
      return const ProfileMediaStripPlaceholder();
    }
    if (state.status == TimelineStatus.error) return const SizedBox.shrink();
    final tiles = profileMediaTiles(state.entries);
    if (tiles.isEmpty) return const SizedBox.shrink();
    return ContextPaneCard(
      title: kProfileMediaTitle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.xs,
          AppSpacing.md,
          AppSpacing.xs,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _TileGrid(
              count: tiles.length,
              tile: (i) => _MediaTile(
                key: ValueKey(
                  'profile-media-${tiles[i].postId}-${tiles[i].index}',
                ),
                media: tiles[i].media,
                onOpen: () => onOpen(tiles[i]),
              ),
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                style: TextButton.styleFrom(
                  minimumSize: const Size(
                    AppSpacing.minTapTarget,
                    AppSpacing.minTapTarget,
                  ),
                ),
                onPressed: onSeeAll,
                child: Semantics(
                  label: 'See all media',
                  excludeSemantics: true,
                  child: const Text('See all'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The strip while the profile or its Media feed loads: the same card and
/// grid, with blank tiles.
class ProfileMediaStripPlaceholder extends StatelessWidget {
  const ProfileMediaStripPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ContextPaneCard(
      title: kProfileMediaTitle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.xs,
          AppSpacing.md,
          AppSpacing.md,
        ),
        child: Semantics(
          label: 'Loading media',
          container: true,
          excludeSemantics: true,
          child: _TileGrid(
            count: kProfileMediaStripMax,
            tile: (_) => DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// [count] square tiles, [_columns] to a row, filling the width (reading
/// order follows the text direction).
class _TileGrid extends StatelessWidget {
  const _TileGrid({required this.count, required this.tile});

  final int count;
  final Widget Function(int index) tile;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = math.max(
          0.0,
          (constraints.maxWidth - _gap * (_columns - 1)) / _columns,
        );
        return Wrap(
          spacing: _gap,
          runSpacing: _gap,
          children: [
            for (var i = 0; i < count; i++)
              SizedBox.square(dimension: side, child: tile(i)),
          ],
        );
      },
    );
  }
}

/// One square thumbnail (cropped to fill), a button that opens the image.
/// Only the thumbnail is fetched; a GIF shows its still with the badge.
class _MediaTile extends StatelessWidget {
  const _MediaTile({super.key, required this.media, required this.onOpen});

  final common.MediaRef media;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final alt = media.altText.trim();
    final gif = media.contentType == kGifContentType;
    final blank = ColoredBox(color: colors.surfaceContainerHigh);
    final image = LayoutBuilder(
      builder: (context, constraints) {
        final px =
            (constraints.maxWidth * MediaQuery.devicePixelRatioOf(context))
                .ceil();
        return CachedNetworkImage(
          imageUrl: media.thumbUrl,
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          memCacheWidth: px > 0 ? px : null,
          placeholder: (_, _) => blank,
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
    return Semantics(
      container: true,
      button: true,
      image: true,
      label: ['Open image', if (alt.isNotEmpty) alt, if (gif) 'GIF'].join(', '),
      excludeSemantics: true,
      onTap: onOpen,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Material(
          color: colors.surfaceContainerHigh,
          child: InkWell(
            onTap: onOpen,
            child: Stack(
              fit: StackFit.expand,
              children: [
                image,
                if (gif)
                  const PositionedDirectional(
                    bottom: AppSpacing.xs,
                    end: AppSpacing.xs,
                    child: GifBadge(),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
