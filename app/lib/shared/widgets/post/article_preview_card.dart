import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;

/// A bounded feed snapshot; full content is fetched only in the reader.
///
/// An outlined card on the theme surface (light and dark follow the theme):
/// the cover, then the "ARTICLE · n MIN READ" meta line, the title (at most
/// 2 lines) and the excerpt (at most 3). The author and the date are in the
/// post header above the card, so they are not repeated here.
///
/// Phone (narrower than [AppSize.articleCardWideWidth]): a 16:9 cover over the
/// text. Tablet and desktop columns: the cover (4:3) beside the text. A
/// missing or failed cover is a brand placeholder (with a cover URL) or no
/// image at all (no URL: a text card, so a feed of cover-less articles stays
/// compact). Every text is bounded, so long titles, long unbroken words and a
/// missing excerpt never overflow.
class ArticlePreviewCard extends StatelessWidget {
  const ArticlePreviewCard({super.key, required this.article});

  final pb.ArticlePreview article;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = article.title.trim();
    return Semantics(
      button: true,
      label: 'Read article: ${title.isEmpty ? articleCardUntitled : title}',
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        elevation: 0,
        color: theme.colorScheme.surface,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: theme.colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
        child: InkWell(
          onTap: () => context.push(AppRouter.articlePath(article.articleId)),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= AppSize.articleCardWideWidth;
              final hasCover = article.coverUrl.isNotEmpty;
              final text = _ArticleText(article: article);
              if (!hasCover) return text;
              if (!wide) {
                final height = math.min(
                  constraints.maxWidth / AppSize.articleCardCoverAspect,
                  AppSize.articleCardMaxCoverHeight,
                );
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      height: height,
                      child: _Cover(url: article.coverUrl),
                    ),
                    text,
                  ],
                );
              }
              return ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: AppSize.articleCardWideMinHeight,
                ),
                child: IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width:
                            constraints.maxWidth *
                            AppSize.articleCardWideCoverFraction,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [_Cover(url: article.coverUrl)],
                        ),
                      ),
                      Expanded(child: Center(child: text)),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Shown instead of a title that is empty.
const articleCardUntitled = 'Untitled article';

/// The card's small caps label: "ARTICLE", or with the read time when the
/// preview carries one ("ARTICLE · 5 MIN READ"). Older posts have 0
/// (unknown) and show the bare label.
String articleCardLabel(int readMinutes) =>
    readMinutes > 0 ? 'ARTICLE · $readMinutes MIN READ' : 'ARTICLE';

/// The cover, center-cropped to its box; the placeholder while it loads and
/// when it fails.
class _Cover extends StatelessWidget {
  const _Cover({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) => CachedNetworkImage(
    imageUrl: url,
    fit: BoxFit.cover,
    alignment: Alignment.center,
    placeholder: (_, _) => const ArticleCoverFallback(),
    errorWidget: (_, _, _) => const ArticleCoverFallback(showIcon: true),
  );
}

/// The brand placeholder for a cover that is loading or failed.
class ArticleCoverFallback extends StatelessWidget {
  const ArticleCoverFallback({super.key, this.showIcon = false});

  final bool showIcon;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(gradient: AppGradients.communityCover),
    child: showIcon
        ? const Center(
            child: Icon(Icons.article_outlined, color: AppPalette.white),
          )
        : null,
  );
}

class _ArticleText extends StatelessWidget {
  const _ArticleText({required this.article});

  final pb.ArticlePreview article;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = article.title.trim();
    final excerpt = article.excerpt.trim();
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            articleCardLabel(article.readMinutes),
            semanticsLabel: article.readMinutes > 0
                ? 'Article, ${article.readMinutes} minute read'
                : 'Article',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.4,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            title.isEmpty ? articleCardUntitled : title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onSurface,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (excerpt.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              excerpt,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
