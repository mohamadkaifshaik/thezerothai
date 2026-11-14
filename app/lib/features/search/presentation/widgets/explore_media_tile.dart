import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/post/gif_badge.dart';
import '../../../media/domain/processed_image.dart' show kGifContentType;
import '../../domain/explore_media.dart';

/// One thumbnail of Explore's Media section and page (cropped to fill, only
/// the thumbnail is fetched): a button named for its image that calls
/// [onOpen]. A GIF shows its still with the badge. [ExploreMediaKind] picks
/// the overlay, so a reel's play icon is one more case later.
class ExploreMediaTileView extends StatelessWidget {
  const ExploreMediaTileView({
    super.key,
    required this.tile,
    required this.onOpen,
  });

  final ExploreMediaTile tile;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final media = tile.media;
    final alt = media.altText.trim();
    final gif = media.contentType == kGifContentType;
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
          placeholder: (_, _) => ColoredBox(color: colors.surfaceContainerHigh),
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
      label: ['Open image', if (alt.isNotEmpty) alt, if (gif) 'GIF'].join(', '),
      excludeSemantics: true,
      onTap: onOpen,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: ColoredBox(
          color: colors.surfaceContainerHigh,
          child: Stack(
            fit: StackFit.expand,
            children: [
              image,
              switch (tile.kind) {
                ExploreMediaKind.photo =>
                  gif
                      ? const PositionedDirectional(
                          bottom: AppSpacing.xs,
                          end: AppSpacing.xs,
                          child: GifBadge(),
                        )
                      : const SizedBox.shrink(),
              },
              Positioned.fill(
                child: Material(
                  type: MaterialType.transparency,
                  child: InkWell(onTap: onOpen),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
