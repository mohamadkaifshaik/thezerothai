import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/tablet_layout.dart';
import '../../../gen/dzeroth/common/v1/common.pb.dart' as common;
import '../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../engagement/domain/engagement_feature_flag.dart';
import '../../engagement/presentation/widgets/post_engagement_bar.dart';
import '../../../shared/widgets/primitives/app_side_sheet.dart';
import '../../media/domain/processed_image.dart' show kGifContentType;
import 'post_detail_screen.dart';
import 'widgets/loaded_post.dart';

class PostPhotoScreen extends StatelessWidget {
  const PostPhotoScreen({super.key, required this.postId, required this.index});
  final String postId;

  /// One-based index in the original post's media list.
  final int index;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppColors.photoBackground,
    body: SafeArea(
      child: Stack(
        children: [
          Positioned.fill(
            child: LoadedPost(
              postId: postId,
              builder: (context, view) =>
                  _PhotoViewer(view: view, index: index),
            ),
          ),
          PositionedDirectional(
            top: AppSpacing.sm,
            start: AppSpacing.sm,
            child: _PhotoButton(
              tooltip: 'Close image',
              onPressed: () => closePostPhoto(context, postId),
              icon: Icons.close,
            ),
          ),
        ],
      ),
    ),
  );
}

void closePostPhoto(BuildContext context, String postId) {
  if (context.canPop()) {
    context.pop();
  } else {
    context.go(AppRouter.postPath(postId));
  }
}

/// A round control over the black stage: a pearl wash and a white glyph (the
/// PostPhoto designs).
class _PhotoButton extends StatelessWidget {
  const _PhotoButton({
    required this.tooltip,
    required this.onPressed,
    required this.icon,
  });

  final String tooltip;
  final VoidCallback onPressed;
  final IconData icon;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    icon: Icon(icon),
    style: IconButton.styleFrom(
      minimumSize: const Size.square(AppPostsLayout.photoButton),
      backgroundColor: AppColors.onPhotoBackground.withValues(
        alpha: AppPostsLayout.photoButtonTint,
      ),
      foregroundColor: AppColors.onPhotoBackground,
    ),
  );
}

/// "2 / 3" in a pill at the top centre of the stage.
class _PhotoCounter extends StatelessWidget {
  const _PhotoCounter({required this.index, required this.count});

  final int index;
  final int count;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: AppColors.onPhotoBackground.withValues(
        alpha: AppPostsLayout.photoButtonTint,
      ),
      borderRadius: BorderRadius.circular(AppRadius.pill),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs + 2,
      ),
      child: Text(
        '$index / $count',
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: AppColors.onPhotoBackground,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
  );
}

/// The phone's page dots: the selected page is the long teal one.
class _PhotoDots extends StatelessWidget {
  const _PhotoDots({required this.index, required this.count});

  final int index;
  final int count;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ExcludeSemantics(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 1; i <= count; i++)
            Container(
              width: i == index
                  ? AppPostsLayout.photoDotSelected
                  : AppPostsLayout.photoDot,
              height: AppPostsLayout.photoDot,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              decoration: BoxDecoration(
                color: i == index
                    ? colors.primary
                    : AppColors.onPhotoBackground.withValues(alpha: .3),
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
            ),
        ],
      ),
    );
  }
}

/// Who posted the photo and what they said, under the stage when the post
/// pane is not beside it.
class _PhotoCaption extends StatelessWidget {
  const _PhotoCaption({required this.post});

  final pb.Post post;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyLarge
        ?.copyWith(color: AppColors.onPhotoBackground);
    final name = post.author.displayName.isEmpty
        ? '@${post.author.handle}'
        : post.author.displayName;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: name,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          if (post.text.isNotEmpty) TextSpan(text: '  ${post.text}'),
        ],
      ),
      style: style,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
    );
  }
}

class _PhotoViewer extends StatefulWidget {
  const _PhotoViewer({required this.view, required this.index});
  final pb.PostView view;
  final int index;
  @override
  State<_PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<_PhotoViewer> {
  bool _showDetails = true;
  bool _zoomed = false;
  final _transform = TransformationController();
  late final PageController _pages;

  @override
  void initState() {
    super.initState();
    final last = math.max(0, widget.view.post.media.length - 1);
    _pages = PageController(initialPage: (widget.index - 1).clamp(0, last));
    _transform.addListener(_onTransform);
  }

  /// Paging is allowed only while the picture is not zoomed, so a pan on a
  /// zoomed picture never turns the page.
  void _onTransform() {
    final zoomed = _transform.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
  }

  @override
  void didUpdateWidget(covariant _PhotoViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) {
      _transform.value = Matrix4.identity();
      final target = widget.index - 1;
      if (_pages.hasClients &&
          target >= 0 &&
          target < widget.view.post.media.length &&
          _pages.page?.round() != target) {
        _pages.jumpToPage(target);
      }
    }
  }

  @override
  void dispose() {
    _transform
      ..removeListener(_onTransform)
      ..dispose();
    _pages.dispose();
    super.dispose();
  }

  /// The details pane's width outside the tablet layout (and its cap on
  /// it).
  static const double _paneWidth = 380;

  /// The viewer width the pane needs outside the tablet layout.
  static const double _legacyPaneFrom = 1000;

  /// Band A of the tablet layout: the post and its replies in a side sheet
  /// (code SS) over the photo, instead of a page pushed over it.
  void _showPostSheet(BuildContext context) => showAppSideSheet<void>(
    context: context,
    semanticLabel: 'Post',
    builder: (_) => PostDetailScreen(postId: widget.view.post.postId),
  );

  /// Arrows and keys: turn the page; [_onPage] then updates the location.
  void _move(int offset) {
    final next = widget.index + offset;
    if (next < 1 || next > widget.view.post.media.length) return;
    if (!_pages.hasClients) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _pages.jumpToPage(next - 1);
    } else {
      unawaited(
        _pages.animateToPage(
          next - 1,
          duration: AppMotion.expoOutShort,
          curve: AppMotion.expoOut,
        ),
      );
    }
  }

  int? _mouseStartPage;

  void _mouseDown(PointerDownEvent e) {
    _mouseStartPage =
        e.kind == PointerDeviceKind.mouse &&
            e.buttons == kPrimaryButton &&
            !_zoomed &&
            _pages.hasClients
        ? _pages.page?.round()
        : null;
  }

  void _mouseMove(PointerMoveEvent e) {
    if (_mouseStartPage == null || !_pages.hasClients) return;
    final position = _pages.position;
    position.jumpTo(
      (position.pixels - e.delta.dx).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
    );
  }

  void _mouseEnd(PointerEvent e) {
    final start = _mouseStartPage;
    _mouseStartPage = null;
    if (start == null || !_pages.hasClients) return;
    final moved = (_pages.page ?? start.toDouble()) - start;
    // A fifth of a page is enough to turn it, as a fling would.
    final target = moved > .2
        ? start + 1
        : moved < -.2
        ? start - 1
        : start;
    final last = widget.view.post.media.length - 1;
    unawaited(
      _pages.animateToPage(
        target.clamp(0, last),
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : AppMotion.expoOutShort,
        curve: AppMotion.expoOut,
      ),
    );
  }

  /// A page turn (swipe, drag, arrow or key). Replaces the selected-image
  /// location so Close still returns to the post.
  void _onPage(int page) {
    if (page + 1 == widget.index) return;
    context.replace(AppRouter.postPhotoPath(widget.view.post.postId, page + 1));
  }

  Widget _page(BuildContext context, int i, List<common.MediaRef> media) {
    final item = media[i];
    // Opening a viewer must not silently start an animated GIF.
    final url = item.contentType == kGifContentType ? item.thumbUrl : item.url;
    final image = Center(
      child: Semantics(
        image: true,
        label: item.altText.isEmpty
            ? 'Image ${i + 1} of ${media.length}'
            : item.altText,
        child: url.isEmpty
            ? const Icon(
                Icons.broken_image_outlined,
                color: AppColors.onPhotoBackground,
              )
            : CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.contain,
                placeholder: (_, _) => const CircularProgressIndicator(),
                errorWidget: (_, _, _) => const Icon(
                  Icons.broken_image_outlined,
                  color: AppColors.onPhotoBackground,
                ),
              ),
      ),
    );
    if (i + 1 != widget.index) return image;
    return InteractiveViewer(
      transformationController: _transform,
      minScale: 1,
      maxScale: 4,
      child: image,
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = widget.view.post.media;
    if (widget.index < 1 || widget.index > media.length) {
      return const Center(
        child: Text(
          'This image is not available.',
          style: TextStyle(color: AppColors.onPhotoBackground),
        ),
      );
    }
    // The tablet layout (both flags, 600-1199dp; tablet plan section 4.1,
    // PostPhoto row) decides on the window width: the details pane from
    // 840dp (band B), `min(380, 0.4 * W)` wide; below it (band A) "Show
    // post" opens the details in a side sheet. Elsewhere today's rule: the
    // pane from 1000dp of the viewer's width, 380 wide, and "View post"
    // pushes the post (phones, desktop: ruling R-1).
    final tablet = tabletLayoutAt(context);
    final window = MediaQuery.sizeOf(context).width;
    final engagement = isFeatureEnabled(context, kFeatureEngagement);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            closePostPhoto(context, widget.view.post.postId),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _move(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _move(1),
      },
      child: Focus(
        autofocus: true,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = tablet
                ? window >= AppBreakpoints.expanded
                : constraints.maxWidth >= _legacyPaneFrom;
            final paneWidth = tablet
                ? math.min(_paneWidth, window * .4)
                : _paneWidth;
            final sheet = tablet && !wide;
            // With the details pane beside the photo the post's own action
            // row is there; otherwise it sits under the photo.
            final showActions = engagement && !(wide && _showDetails);
            return Row(
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(
                            48,
                            64,
                            48,
                            showActions ? AppPostsLayout.photoActionsInset : 64,
                          ),
                          // A mouse drag is turned into a page drag here: the
                          // zoom viewer's gesture claims it first otherwise.
                          child: Listener(
                            onPointerDown: _mouseDown,
                            onPointerMove: _mouseMove,
                            onPointerUp: _mouseEnd,
                            onPointerCancel: _mouseEnd,
                            child: PageView.builder(
                              controller: _pages,
                              physics: _zoomed
                                  ? const NeverScrollableScrollPhysics()
                                  : const PageScrollPhysics(),
                              itemCount: media.length,
                              onPageChanged: _onPage,
                              itemBuilder: (context, i) =>
                                  _page(context, i, media),
                            ),
                          ),
                        ),
                      ),
                      if (widget.index > 1)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Padding(
                            padding: const EdgeInsets.all(AppSpacing.smd),
                            child: _PhotoButton(
                              tooltip: 'Previous image',
                              onPressed: () => _move(-1),
                              icon: Icons.chevron_left,
                            ),
                          ),
                        ),
                      if (widget.index < media.length)
                        Align(
                          alignment: Alignment.centerRight,
                          child: Padding(
                            padding: const EdgeInsets.all(AppSpacing.smd),
                            child: _PhotoButton(
                              tooltip: 'Next image',
                              onPressed: () => _move(1),
                              icon: Icons.chevron_right,
                            ),
                          ),
                        ),
                      PositionedDirectional(
                        top: AppSpacing.sm,
                        end: AppSpacing.sm,
                        child: _PhotoButton(
                          tooltip: wide
                              ? (_showDetails ? 'Hide post' : 'Show post')
                              : sheet
                              ? 'Show post'
                              : 'View post',
                          onPressed: () => wide
                              ? setState(() => _showDetails = !_showDetails)
                              : sheet
                              ? _showPostSheet(context)
                              : context.push(
                                  AppRouter.postPath(widget.view.post.postId),
                                ),
                          icon: wide && _showDetails
                              ? Icons.chevron_right
                              : Icons.chat_bubble_outline,
                        ),
                      ),
                      Align(
                        alignment: Alignment.topCenter,
                        child: Padding(
                          padding: const EdgeInsets.only(top: AppSpacing.md),
                          child: _PhotoCounter(
                            index: widget.index,
                            count: media.length,
                          ),
                        ),
                      ),
                      if (!(wide && _showDetails))
                        Align(
                          alignment: Alignment.bottomCenter,
                          child: Padding(
                            padding: const EdgeInsets.all(AppSpacing.md),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _PhotoCaption(post: widget.view.post),
                                if (engagement)
                                  Theme(
                                    data: appDarkTheme,
                                    child: PostEngagementBar(view: widget.view),
                                  ),
                                if (window < AppBreakpoints.mobile &&
                                    media.length > 1) ...[
                                  const SizedBox(height: AppSpacing.smd),
                                  Center(
                                    child: _PhotoDots(
                                      index: widget.index,
                                      count: media.length,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (wide && _showDetails)
                  SizedBox(
                    width: paneWidth,
                    child: PostDetailScreen(postId: widget.view.post.postId),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
