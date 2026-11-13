import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/common/v1/common.pb.dart' show MediaRef;
import '../../../media/domain/processed_image.dart' show kGifContentType;
import '../../domain/article.dart';

/// An article's inline image in the reader: the server-resolved [media]
/// (thumb here, the full image in the viewer) with its caption under it.
///
/// No [media] (the image was deleted, withheld or is not usable) or [enabled]
/// false (`article_images` off for this reader) shows a quiet placeholder: an
/// unavailable image never fails the article.
class ArticleImageBlock extends StatelessWidget {
  const ArticleImageBlock({
    super.key,
    required this.block,
    required this.media,
    this.enabled = true,
  });

  final ArticleBlock block;
  final MediaRef? media;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final ref = enabled ? media : null;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final thumb = ref == null
        ? ''
        : (ref.thumbUrl.isNotEmpty ? ref.thumbUrl : ref.url);
    final Widget picture;
    if (ref == null || thumb.isEmpty) {
      picture = ArticleImagePlaceholder(label: block.altText);
    } else {
      final ratio = ref.width > 0 && ref.height > 0
          ? (ref.width / ref.height).clamp(.4, 2.5).toDouble()
          : 4 / 3;
      picture = Semantics(
        image: true,
        button: true,
        label: block.altText.isEmpty ? 'Image' : block.altText,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.card),
          child: AspectRatio(
            aspectRatio: ratio,
            child: Material(
              color: colors.surfaceContainerHigh,
              child: InkWell(
                onTap: () => showArticleImageViewer(
                  context,
                  media: ref,
                  alt: block.altText,
                ),
                child: CachedNetworkImage(
                  imageUrl: thumb,
                  fit: BoxFit.cover,
                  placeholder: (_, _) =>
                      ColoredBox(color: colors.surfaceContainerHigh),
                  errorWidget: (_, _, _) => Center(
                    child: Icon(
                      Icons.broken_image_outlined,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        picture,
        if (block.caption.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs),
            child: Text(
              block.caption,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}

/// What stands in for an image the reader cannot show.
class ArticleImagePlaceholder extends StatelessWidget {
  const ArticleImagePlaceholder({super.key, this.label = ''});

  /// The author's alt text, kept for screen readers.
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label: label.isEmpty ? 'Image unavailable' : 'Image unavailable. $label',
      excludeSemantics: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 96),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(AppRadius.card),
          ),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.image_not_supported_outlined,
                    color: colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Flexible(
                    child: Text(
                      'Image unavailable',
                      style: Theme.of(context).textTheme.bodyMedium
                          ?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens [media] full size over a black stage: pinch to zoom, Close or Escape
/// to leave. The post photo viewer (`/post/:id/photo/:index`) loads a post's
/// own media, which an article's inline images are not, so this reuses its
/// stage look (tokens and controls) without that route.
Future<void> showArticleImageViewer(
  BuildContext context, {
  required MediaRef media,
  String alt = '',
}) => Navigator.of(context, rootNavigator: true).push<void>(
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => _ArticleImageViewer(media: media, alt: alt),
  ),
);

class _ArticleImageViewer extends StatelessWidget {
  const _ArticleImageViewer({required this.media, required this.alt});

  final MediaRef media;
  final String alt;

  @override
  Widget build(BuildContext context) {
    // Opening a viewer must not silently start an animated GIF.
    final url = media.contentType == kGifContentType || media.url.isEmpty
        ? media.thumbUrl
        : media.url;
    const onPhoto = AppColors.onPhotoBackground;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: AppColors.photoBackground,
          body: SafeArea(
            child: Stack(
              children: [
                Positioned.fill(
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.xxl),
                    child: InteractiveViewer(
                      minScale: 1,
                      maxScale: 4,
                      child: Center(
                        child: Semantics(
                          image: true,
                          label: alt.isEmpty ? 'Image' : alt,
                          child: url.isEmpty
                              ? const Icon(
                                  Icons.broken_image_outlined,
                                  color: onPhoto,
                                )
                              : CachedNetworkImage(
                                  imageUrl: url,
                                  fit: BoxFit.contain,
                                  placeholder: (_, _) =>
                                      const CircularProgressIndicator(),
                                  errorWidget: (_, _, _) => const Icon(
                                    Icons.broken_image_outlined,
                                    color: onPhoto,
                                  ),
                                ),
                        ),
                      ),
                    ),
                  ),
                ),
                PositionedDirectional(
                  top: AppSpacing.sm,
                  start: AppSpacing.sm,
                  child: IconButton(
                    tooltip: 'Close image',
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.close),
                    style: IconButton.styleFrom(
                      minimumSize: const Size.square(
                        AppPostsLayout.photoButton,
                      ),
                      backgroundColor: onPhoto.withValues(
                        alpha: AppPostsLayout.photoButtonTint,
                      ),
                      foregroundColor: onPhoto,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
