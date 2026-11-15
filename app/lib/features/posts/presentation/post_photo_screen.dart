import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
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

/// The full-screen viewer. The photo fills the screen edge to edge (no
/// SafeArea around it); one tap on it hides every control (buttons, counter,
/// dots, caption, action bar) and the system bars, and the next brings them
/// back. [PostPhotoScreen.chromeVisible] is the one flag all of them follow.
class PostPhotoScreen extends StatefulWidget {
  const PostPhotoScreen({super.key, required this.postId, required this.index});
  final String postId;

  /// One-based index in the original post's media list.
  final int index;

  @override
  State<PostPhotoScreen> createState() => _PostPhotoScreenState();
}

class _PostPhotoScreenState extends State<PostPhotoScreen> {
  final _chrome = ValueNotifier<bool>(true);
  bool _changedSystemUi = false;

  @override
  void initState() {
    super.initState();
    _chrome.addListener(_syncSystemUi);
  }

  /// Hidden controls take the status and navigation bars with them (they
  /// reappear on a swipe from the edge); shown controls bring them back.
  void _syncSystemUi() {
    _changedSystemUi = true;
    unawaited(
      SystemChrome.setEnabledSystemUIMode(
        _chrome.value ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky,
      ),
    );
  }

  @override
  void dispose() {
    _chrome
      ..removeListener(_syncSystemUi)
      ..dispose();
    // Leaving the viewer always restores the bars.
    if (_changedSystemUi) {
      // The app never sets a system UI mode itself, so this is Flutter's
      // default: manual with every overlay shown.
      unawaited(
        SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.manual,
          overlays: SystemUiOverlay.values,
        ),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppColors.photoBackground,
    body: Stack(
      children: [
        Positioned.fill(
          child: LoadedPost(
            postId: widget.postId,
            builder: (context, view) =>
                _PhotoViewer(view: view, index: widget.index, chrome: _chrome),
          ),
        ),
        Positioned.fill(
          child: _ChromeFade(
            chrome: _chrome,
            child: SafeArea(
              child: Align(
                alignment: AlignmentDirectional.topStart,
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  child: _PhotoButton(
                    tooltip: 'Close image',
                    onPressed: () => closePostPhoto(context, widget.postId),
                    icon: Icons.close,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

/// Fades [child] with [chrome]; while hidden it takes no touches, no focus
/// and is out of the semantics tree (the picture itself carries the "show
/// controls" action then).
class _ChromeFade extends StatelessWidget {
  const _ChromeFade({required this.chrome, required this.child});

  final ValueListenable<bool> chrome;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : AppMotion.chromeFade;
    return ValueListenableBuilder<bool>(
      valueListenable: chrome,
      child: child,
      builder: (context, visible, child) => IgnorePointer(
        ignoring: !visible,
        child: ExcludeFocus(
          excluding: !visible,
          child: ExcludeSemantics(
            excluding: !visible,
            child: AnimatedOpacity(
              opacity: visible ? 1 : 0,
              duration: duration,
              curve: Curves.easeOut,
              child: child,
            ),
          ),
        ),
      ),
    );
  }
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
  const _PhotoViewer({
    required this.view,
    required this.index,
    required this.chrome,
  });
  final pb.PostView view;
  final int index;
  final ValueNotifier<bool> chrome;
  @override
  State<_PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<_PhotoViewer> {
  bool _showDetails = true;
  bool _zoomed = false;
  late final PageController _pages;

  @override
  void initState() {
    super.initState();
    final last = math.max(0, widget.view.post.media.length - 1);
    _pages = PageController(initialPage: (widget.index - 1).clamp(0, last));
  }

  /// Paging is allowed only while the picture is not zoomed in past its
  /// opening fit, so a pan on a zoomed picture never turns the page.
  void _onZoomed(bool zoomed) {
    if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
  }

  void _toggleChrome() => widget.chrome.value = !widget.chrome.value;

  @override
  void didUpdateWidget(covariant _PhotoViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) {
      _zoomed = false;
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

  /// Everything that sits over the picture and hides on a tap: the legibility
  /// scrims, previous/next, the post button, the counter, the caption, the
  /// action bar and the dots.
  Widget _chromeLayer(
    BuildContext context, {
    required List<common.MediaRef> media,
    required bool wide,
    required bool sheet,
    required double window,
    required bool engagement,
  }) {
    final captionShown = !(wide && _showDetails);
    return Stack(
      fit: StackFit.expand,
      children: [
        // Light scrims so white controls read over any photo.
        const PositionedDirectional(
          top: 0,
          start: 0,
          end: 0,
          height: AppPostsLayout.photoScrimTopHeight,
          child: IgnorePointer(
            child: _Scrim(gradient: AppGradients.photoScrimTop),
          ),
        ),
        if (captionShown)
          const PositionedDirectional(
            bottom: 0,
            start: 0,
            end: 0,
            height: AppPostsLayout.photoScrimBottomHeight,
            child: IgnorePointer(
              child: _Scrim(gradient: AppGradients.photoScrimBottom),
            ),
          ),
        SafeArea(
          child: Stack(
            fit: StackFit.expand,
            children: [
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
              if (captionShown)
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
      ],
    );
  }

  Widget _page(BuildContext context, int i, List<common.MediaRef> media) {
    final item = media[i];
    // Opening a viewer must not silently start an animated GIF.
    final url = item.contentType == kGifContentType ? item.thumbUrl : item.url;
    final picture = url.isEmpty
        ? const Center(
            child: Icon(
              Icons.broken_image_outlined,
              color: AppColors.onPhotoBackground,
            ),
          )
        : CachedNetworkImage(
            imageUrl: url,
            fit: BoxFit.contain,
            placeholder: (_, _) =>
                const Center(child: CircularProgressIndicator()),
            errorWidget: (_, _, _) => const Center(
              child: Icon(
                Icons.broken_image_outlined,
                color: AppColors.onPhotoBackground,
              ),
            ),
          );
    return Semantics(
      image: true,
      label: item.altText.isEmpty
          ? 'Image ${i + 1} of ${media.length}'
          : item.altText,
      // The one way for a screen reader to bring the controls back once they
      // are hidden (and to hide them again).
      hint: 'Double tap to show or hide the controls',
      onTap: _toggleChrome,
      child: _ZoomablePhoto(
        key: ValueKey('photo-$i'),
        aspect: item.width > 0 && item.height > 0
            ? item.width / item.height
            : 0,
        onTap: _toggleChrome,
        onZoomed: _onZoomed,
        child: picture,
      ),
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
            return Row(
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      // The picture fills the whole area, edge to edge.
                      Positioned.fill(
                        // A mouse drag is turned into a page drag here: the
                        // zoom area's gesture claims it first otherwise.
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
                      Positioned.fill(
                        child: _ChromeFade(
                          chrome: widget.chrome,
                          child: _chromeLayer(
                            context,
                            media: media,
                            wide: wide,
                            sheet: sheet,
                            window: window,
                            engagement: engagement,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (wide && _showDetails)
                  _SlidingPane(
                    chrome: widget.chrome,
                    width: paneWidth,
                    child: SafeArea(
                      left: false,
                      child: PostDetailScreen(postId: widget.view.post.postId),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// A dark gradient behind the top or bottom controls.
class _Scrim extends StatelessWidget {
  const _Scrim({required this.gradient});

  final Gradient gradient;

  @override
  Widget build(BuildContext context) =>
      DecoratedBox(decoration: BoxDecoration(gradient: gradient));
}

/// How a photo of [aspect] (width / height) sits in a [viewport]: the whole
/// photo (contain, the zoom floor) as [fitted]; [cover] is the scale that
/// makes it fill the viewport with no bars (1 when the aspects match or the
/// aspect is unknown, where the photo is simply contained).
@visibleForTesting
({Size fitted, double cover}) photoFit(Size viewport, double aspect) {
  if (aspect <= 0 || viewport.isEmpty) return (fitted: viewport, cover: 1);
  final viewportAspect = viewport.width / viewport.height;
  final fitted = aspect >= viewportAspect
      ? Size(viewport.width, viewport.width / aspect)
      : Size(viewport.height * aspect, viewport.height);
  final cover = math.max(
    viewport.width / fitted.width,
    viewport.height / fitted.height,
  );
  return (fitted: fitted, cover: cover);
}

/// [offset] (from the viewport centre) kept so the [fitted] photo at [scale]
/// never shows a gap inside the [viewport]: on an axis where it overflows it
/// may move up to the overflow, otherwise it stays centred.
@visibleForTesting
Offset clampPhotoOffset(
  Offset offset,
  Size fitted,
  double scale,
  Size viewport,
) {
  double axis(double value, double photo, double view) {
    final limit = math.max(0.0, (photo * scale - view) / 2);
    return value.clamp(-limit, limit);
  }

  return Offset(
    axis(offset.dx, fitted.width, viewport.width),
    axis(offset.dy, fitted.height, viewport.height),
  );
}

/// One photo with its own pan and zoom. It opens filling the viewport (cover:
/// no black on any side); pinch out or double-tap shows the whole photo
/// (contain), double-tap again goes back; pinch in zooms up to 4x the opening
/// fit and a drag then pans (a drag at the opening fit is the page swipe).
/// One tap calls [onTap].
class _ZoomablePhoto extends StatefulWidget {
  const _ZoomablePhoto({
    super.key,
    required this.aspect,
    required this.child,
    required this.onTap,
    required this.onZoomed,
  });

  /// Width / height of the photo, 0 when unknown (then it stays contained).
  final double aspect;
  final Widget child;
  final VoidCallback onTap;

  /// Whether the photo is zoomed in past its opening fit.
  final ValueChanged<bool> onZoomed;

  @override
  State<_ZoomablePhoto> createState() => _ZoomablePhotoState();
}

enum _Fit { cover, contain, free }

class _ZoomablePhotoState extends State<_ZoomablePhoto>
    with SingleTickerProviderStateMixin {
  static const _maxZoom = 4.0;
  static const _noZoomJump = 2.5;

  _Fit _fit = _Fit.cover;
  double _freeScale = 1;
  Offset _offset = Offset.zero;
  Size _viewport = Size.zero;
  Offset _doubleTapAt = Offset.zero;

  late final AnimationController _anim = AnimationController(vsync: this)
    ..addListener(_tick)
    ..addStatusListener(_onAnimStatus);
  double _fromScale = 1;
  double _toScale = 1;
  Offset _fromOffset = Offset.zero;
  Offset _toOffset = Offset.zero;
  _Fit? _rest;
  double _startScale = 1;
  Offset _startOffset = Offset.zero;
  Offset _startFocal = Offset.zero;
  bool _reportedZoomed = false;

  ({Size fitted, double cover}) get _geometry =>
      photoFit(_viewport, widget.aspect);

  double get _scale => switch (_fit) {
    _Fit.cover => _geometry.cover,
    _Fit.contain => 1,
    _Fit.free => _freeScale,
  };

  bool get _zoomedIn => _scale > _geometry.cover * 1.01;

  void _report() {
    final zoomed = _zoomedIn;
    if (zoomed != _reportedZoomed) {
      _reportedZoomed = zoomed;
      widget.onZoomed(zoomed);
    }
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  void _setFree(double scale, Offset offset) {
    final s = scale.clamp(1.0, _maxZoom * _geometry.cover);
    setState(() {
      _fit = _Fit.free;
      _freeScale = s;
      _offset = clampPhotoOffset(offset, _geometry.fitted, s, _viewport);
    });
    _report();
  }

  /// Moves to [scale] and [offset], animated unless reduced motion; ends in
  /// the named fit when it is one of the two resting states. A new move
  /// replaces one in flight (the controller's one listener reads the target).
  void _goTo(double scale, Offset offset, {_Fit? rest}) {
    _anim.stop();
    _fromScale = _scale;
    _fromOffset = _offset;
    _toScale = scale;
    _toOffset = clampPhotoOffset(offset, _geometry.fitted, scale, _viewport);
    _rest = rest;
    if (MediaQuery.disableAnimationsOf(context)) {
      _finishMove();
      return;
    }
    _anim
      ..duration = AppMotion.expoOutShort
      ..forward(from: 0);
  }

  void _tick() {
    final t = AppMotion.expoOut.transform(_anim.value);
    setState(() {
      _fit = _Fit.free;
      _freeScale = _fromScale + (_toScale - _fromScale) * t;
      _offset = Offset.lerp(_fromOffset, _toOffset, t)!;
    });
    _report();
  }

  void _onAnimStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) _finishMove();
  }

  void _finishMove() {
    if (!mounted) return;
    setState(() {
      final rest = _rest;
      if (rest != null) {
        _fit = rest;
        _offset = Offset.zero;
      } else {
        _fit = _Fit.free;
        _freeScale = _toScale;
        _offset = _toOffset;
      }
    });
    _report();
  }

  void _onScaleStart(ScaleStartDetails d) {
    _anim.stop();
    _startScale = _scale;
    _startOffset = _offset;
    _startFocal = d.localFocalPoint - _viewport.center(Offset.zero);
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    // One finger pans only a photo zoomed in; at the opening fit it is the
    // page swipe's.
    if (d.pointerCount < 2 && !_zoomedIn) return;
    final scale = d.pointerCount < 2 ? _startScale : _startScale * d.scale;
    final focal = d.localFocalPoint - _viewport.center(Offset.zero);
    final ratio = scale / _startScale;
    _setFree(scale, focal - (_startFocal - _startOffset) * ratio);
  }

  void _onScaleEnd(ScaleEndDetails d) {
    final cover = _geometry.cover;
    if (_fit != _Fit.free) return;
    if (_freeScale < cover) {
      // Between the whole photo and the opening fit: settle on the nearer.
      if (_freeScale < (1 + cover) / 2) {
        _goTo(1, Offset.zero, rest: _Fit.contain);
      } else {
        _goTo(cover, Offset.zero, rest: _Fit.cover);
      }
    } else if (_freeScale <= cover * 1.01) {
      _goTo(cover, Offset.zero, rest: _Fit.cover);
    }
  }

  void _onDoubleTap() {
    final cover = _geometry.cover;
    if (_zoomedIn) {
      _goTo(cover, Offset.zero, rest: _Fit.cover);
    } else if (cover > 1.02) {
      // Cover <-> the whole photo.
      if (_scale >= cover * 0.99) {
        _goTo(1, Offset.zero, rest: _Fit.contain);
      } else {
        _goTo(cover, Offset.zero, rest: _Fit.cover);
      }
    } else if (_scale < 1.5) {
      // Nothing to show of the whole photo: zoom in at the tap.
      final focal = _doubleTapAt - _viewport.center(Offset.zero);
      final target = _noZoomJump * cover;
      _goTo(target, focal - (focal - _offset) * (target / _scale));
    } else {
      _goTo(cover, Offset.zero, rest: _Fit.cover);
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      _viewport = constraints.biggest;
      final geometry = _geometry;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onDoubleTapDown: (d) => _doubleTapAt = d.localPosition,
        onDoubleTap: _onDoubleTap,
        onScaleStart: _onScaleStart,
        onScaleUpdate: _onScaleUpdate,
        onScaleEnd: _onScaleEnd,
        child: ClipRect(
          child: SizedBox.expand(
            child: Center(
              child: Transform.translate(
                offset: _offset,
                child: Transform.scale(
                  scale: _scale,
                  child: SizedBox.fromSize(
                    size: geometry.fitted,
                    child: widget.child,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// The details pane beside the photo. It is part of the controls: while they
/// are hidden its width closes to nothing (the photo takes it) with a fade,
/// the pane sliding out to the right behind the shrinking edge, and it opens
/// again with them. Reduced motion skips the animation. It stays mounted, so
/// its scroll position survives, but takes no touches, focus or semantics
/// while closed.
class _SlidingPane extends StatelessWidget {
  const _SlidingPane({
    required this.chrome,
    required this.width,
    required this.child,
  });

  final ValueListenable<bool> chrome;
  final double width;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : AppMotion.chromeFade;
    return ValueListenableBuilder<bool>(
      valueListenable: chrome,
      child: child,
      builder: (context, visible, child) => AnimatedContainer(
        duration: duration,
        curve: Curves.easeOut,
        width: visible ? width : 0,
        clipBehavior: Clip.hardEdge,
        decoration: const BoxDecoration(),
        child: OverflowBox(
          alignment: AlignmentDirectional.centerEnd,
          minWidth: width,
          maxWidth: width,
          child: IgnorePointer(
            ignoring: !visible,
            child: ExcludeFocus(
              excluding: !visible,
              child: ExcludeSemantics(
                excluding: !visible,
                child: AnimatedOpacity(
                  opacity: visible ? 1 : 0,
                  duration: duration,
                  curve: Curves.easeOut,
                  child: child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
