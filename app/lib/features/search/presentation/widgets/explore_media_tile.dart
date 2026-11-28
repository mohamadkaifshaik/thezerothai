import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/post/gif_badge.dart';
import '../../../media/domain/processed_image.dart' show kGifContentType;
import '../../../media/domain/video_edit.dart';
import '../../domain/explore_media.dart';

/// One thumbnail of Explore's Media section and page (cropped to fill, only
/// the thumbnail is fetched): a button named for its image that calls
/// [onOpen]. GIFs show their still and badge. Videos show a play icon.
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
    final sensitive = VideoLabel.warnings(media.videoLabels).isNotEmpty;
    final image = sensitive
        ? const Center(child: Icon(Icons.visibility_off_outlined))
        : LayoutBuilder(
            builder: (context, constraints) {
              final px =
                  (constraints.maxWidth *
                          MediaQuery.devicePixelRatioOf(context))
                      .ceil();
              return CachedNetworkImage(
                imageUrl: media.thumbUrl,
                fit: BoxFit.cover,
                width: double.infinity,
                height: double.infinity,
                memCacheWidth: px > 0 ? px : null,
                placeholder: (_, _) =>
                    ColoredBox(color: colors.surfaceContainerHigh),
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
      label: sensitive
          ? 'Open sensitive video'
          : [
              tile.kind == ExploreMediaKind.video ? 'Open video' : 'Open image',
              if (alt.isNotEmpty) alt,
              if (gif) 'GIF',
            ].join(', '),
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
                ExploreMediaKind.video => const Center(
                  child: CircleAvatar(
                    radius: 18,
                    backgroundColor: AppPalette.photoScrim,
                    child: Icon(
                      Icons.play_arrow,
                      color: AppColors.onPhotoBackground,
                    ),
                  ),
                ),
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
