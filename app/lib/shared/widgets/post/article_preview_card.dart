import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;

/// A bounded feed snapshot; full content is fetched only in the reader.
class ArticlePreviewCard extends StatelessWidget {
  const ArticlePreviewCard({super.key, required this.article});
  final pb.ArticlePreview article;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label: 'Read article: ${article.title}',
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: theme.colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(16),
        ),
        child: InkWell(
          onTap: () => context.push(AppRouter.articlePath(article.articleId)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (article.coverUrl.isNotEmpty)
                // The cover is the card's full width; the preview carries no
                // cover size, so it gets the widest frame (2:1, inside the
                // 2:1 .. 4:5 range of post media), center-cropped.
                AspectRatio(
                  aspectRatio: AppSize.postMediaLandscapeAspect,
                  child: CachedNetworkImage(
                    imageUrl: article.coverUrl,
                    fit: BoxFit.cover,
                    alignment: Alignment.center,
                    placeholder: (_, _) => ColoredBox(
                      color: theme.colorScheme.surfaceContainerHigh,
                    ),
                    errorWidget: (_, _, _) =>
                        const Center(child: Icon(Icons.article_outlined)),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            article.title,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Text('Article'),
                      ],
                    ),
                    if (article.excerpt.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        article.excerpt,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyLarge,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
