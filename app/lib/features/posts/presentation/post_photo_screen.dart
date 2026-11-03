import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
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
    backgroundColor: Colors.black,
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
            top: 8,
            start: 8,
            child: IconButton.filledTonal(
              tooltip: 'Close image',
              onPressed: () => closePostPhoto(context, postId),
              icon: const Icon(Icons.close),
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

class _PhotoViewer extends StatefulWidget {
  const _PhotoViewer({required this.view, required this.index});
  final pb.PostView view;
  final int index;
  @override
  State<_PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<_PhotoViewer> {
  bool _showDetails = true;
  final _transform = TransformationController();

  @override
  void didUpdateWidget(covariant _PhotoViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) _transform.value = Matrix4.identity();
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  void _move(int offset) {
    final next = widget.index + offset;
    if (next < 1 || next > widget.view.post.media.length) return;
    // Replace the selected-image location so Close still returns to the post.
    context.replace(AppRouter.postPhotoPath(widget.view.post.postId, next));
  }

  @override
  Widget build(BuildContext context) {
    final media = widget.view.post.media;
    if (widget.index < 1 || widget.index > media.length) {
      return const Center(
        child: Text(
          'This image is not available.',
          style: TextStyle(color: Colors.white),
        ),
      );
    }
    final item = media[widget.index - 1];
    // Opening a viewer must not silently start an animated GIF.
    final url = item.contentType == kGifContentType ? item.thumbUrl : item.url;
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
            final wide = constraints.maxWidth >= 1000;
            return Row(
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: 64,
                            horizontal: 48,
                          ),
                          child: InteractiveViewer(
                            transformationController: _transform,
                            minScale: 1,
                            maxScale: 4,
                            child: Center(
                              child: Semantics(
                                image: true,
                                label: item.altText.isEmpty
                                    ? 'Image ${widget.index} of ${media.length}'
                                    : item.altText,
                                child: url.isEmpty
                                    ? const Icon(
                                        Icons.broken_image_outlined,
                                        color: Colors.white,
                                      )
                                    : CachedNetworkImage(
                                        imageUrl: url,
                                        fit: BoxFit.contain,
                                        placeholder: (_, _) =>
                                            const CircularProgressIndicator(),
                                        errorWidget: (_, _, _) => const Icon(
                                          Icons.broken_image_outlined,
                                          color: Colors.white,
                                        ),
                                      ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (widget.index > 1)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: IconButton.filledTonal(
                            tooltip: 'Previous image',
                            onPressed: () => _move(-1),
                            icon: const Icon(Icons.chevron_left),
                          ),
                        ),
                      if (widget.index < media.length)
                        Align(
                          alignment: Alignment.centerRight,
                          child: IconButton.filledTonal(
                            tooltip: 'Next image',
                            onPressed: () => _move(1),
                            icon: const Icon(Icons.chevron_right),
                          ),
                        ),
                      PositionedDirectional(
                        top: 8,
                        end: 8,
                        child: IconButton.filledTonal(
                          tooltip: wide
                              ? (_showDetails ? 'Hide post' : 'Show post')
                              : 'View post',
                          onPressed: () => wide
                              ? setState(() => _showDetails = !_showDetails)
                              : context.push(
                                  AppRouter.postPath(widget.view.post.postId),
                                ),
                          icon: Icon(
                            wide && _showDetails
                                ? Icons.chevron_right
                                : Icons.chat_bubble_outline,
                          ),
                        ),
                      ),
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            '${widget.index} / ${media.length}',
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (wide && _showDetails)
                  SizedBox(
                    width: 380,
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
