import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'article_cover_tint.dart';

/// A bounded feed snapshot; full content is fetched only in the reader.
///
/// The Substack look: the cover fills the whole card (4:5, capped in height on
/// wide layouts, center-cropped) and the lower part carries a gradient from
/// transparent to a dark tint of the cover's own average colour, with the
/// "ARTICLE" label, the title and the excerpt in white on it. The card looks
/// the same in light and dark mode (it is a picture). Without a cover the same
/// layout sits on the dark brand gradient. Until the tint is known, or when
/// it cannot be computed, the overlay is a near-black scrim.
class ArticlePreviewCard extends StatefulWidget {
  const ArticlePreviewCard({
    super.key,
    required this.article,
    this.tintLoader = loadArticleCoverTint,
  });

  final pb.ArticlePreview article;

  /// How the overlay tint is found; tests pass a fake (the default decodes
  /// the cover through the image cache).
  final ArticleTintLoader tintLoader;

  @override
  State<ArticlePreviewCard> createState() => _ArticlePreviewCardState();
}

class _ArticlePreviewCardState extends State<ArticlePreviewCard> {
  Color? _tint;
  String? _tintFor;

  @override
  void initState() {
    super.initState();
    _loadTint();
  }

  @override
  void didUpdateWidget(ArticlePreviewCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.article.coverUrl != widget.article.coverUrl) _loadTint();
  }

  void _loadTint() {
    final url = widget.article.coverUrl;
    _tintFor = url;
    _tint = null;
    if (url.isEmpty) return;
    widget.tintLoader(url).then((tint) {
      // A late answer for a cover the card no longer shows is dropped.
      if (!mounted || _tintFor != url || tint == null) return;
      setState(() => _tint = tint);
    }, onError: (_) {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final article = widget.article;
    final hasCover = article.coverUrl.isNotEmpty;
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
          child: hasCover
              ? LayoutBuilder(
                  builder: (context, constraints) {
                    // 4:5 of the card's width, never taller than a single
                    // post image may grow (tablet and desktop).
                    final height = math.min(
                      constraints.maxWidth / AppSize.postMediaPortraitAspect,
                      AppSize.postMediaMaxSingleHeight,
                    );
                    return SizedBox(
                      height: height,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          CachedNetworkImage(
                            imageUrl: article.coverUrl,
                            fit: BoxFit.cover,
                            alignment: Alignment.center,
                            placeholder: (_, _) =>
                                const ColoredBox(color: AppPalette.navy2),
                            errorWidget: (_, _, _) => const ColoredBox(
                              color: AppPalette.navy2,
                              child: Center(
                                child: Icon(
                                  Icons.article_outlined,
                                  color: AppPalette.white,
                                ),
                              ),
                            ),
                          ),
                          Align(
                            alignment: Alignment.bottomCenter,
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                minHeight:
                                    height * AppSize.articleCardOverlayFraction,
                                maxHeight: height,
                              ),
                              child: _Overlay(
                                key: const ValueKey('article-card-overlay'),
                                article: article,
                                tint: _tint ?? AppPalette.navyDeep,
                                fadeHeight: AppSize.articleCardFadeHeight,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                )
              : ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: AppSize.articleCardMinHeight,
                  ),
                  child: DecoratedBox(
                    key: const ValueKey('article-card-surface'),
                    decoration: const BoxDecoration(
                      gradient: AppGradients.communityCover,
                    ),
                    child: _Overlay(
                      article: article,
                      tint: null,
                      fadeHeight: 0,
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

/// The text block: label, title, excerpt, bottom-left in white, on a gradient
/// from transparent to [tint] (null: no gradient, the surface is behind it).
class _Overlay extends StatelessWidget {
  const _Overlay({
    super.key,
    required this.article,
    required this.tint,
    required this.fadeHeight,
  });

  final pb.ArticlePreview article;
  final Color? tint;
  final double fadeHeight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint = this.tint;
    final text = Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.md,
        fadeHeight == 0 ? AppSpacing.md : fadeHeight,
        AppSpacing.md,
        AppSpacing.md,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'ARTICLE',
            style: theme.textTheme.labelSmall?.copyWith(
              color: AppPalette.white.withValues(alpha: 0.7),
              fontWeight: FontWeight.w700,
              letterSpacing: 1.4,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            article.title,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleLarge?.copyWith(
              color: AppPalette.white,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (article.excerpt.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              article.excerpt,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: AppPalette.white.withValues(alpha: 0.8),
              ),
            ),
          ],
        ],
      ),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: tint == null ? null : AppGradients.articleOverlay(tint),
      ),
      child: Align(
        alignment: Alignment.bottomLeft,
        heightFactor: 1,
        child: text,
      ),
    );
  }
}
