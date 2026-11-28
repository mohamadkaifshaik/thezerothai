import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/theme/app_theme.dart';
import '../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../../shared/widgets/post/post_video.dart';
import '../../engagement/domain/engagement_feature_flag.dart';
import '../../media/domain/processed_image.dart';
import '../../media/domain/video_edit.dart';
import '../../search/data/search_repository.dart';
import '../../search/presentation/bloc/trending_paged_cubit.dart';
import 'widgets/loaded_post.dart';
import 'widgets/photo_bottom_panel.dart';

typedef _Clip = ({String postId, int index});

Iterable<_Clip> _clips(pb.PostView view) sync* {
  for (var i = 0; i < view.post.media.length; i++) {
    final media = view.post.media[i];
    if (media.contentType == kVideoContentType && media.url.isNotEmpty) {
      yield (postId: view.post.postId, index: i);
    }
  }
}

class _VideoFeed extends PagedTrendingCubit<List<_Clip>> {
  _VideoFeed(this.repository, this.seed)
    : super(seed, maxCalls: 3, wantedPerMore: 3);

  final SearchRepository? repository;
  final List<_Clip> seed;

  @override
  Future<SearchPostsPage> fetchPage(String? token) =>
      repository!.exploreMedia(pageToken: token);

  @override
  List<_Clip> buildState(
    PagedSnapshot snapshot,
    List<List<pb.PostView>> pages,
  ) => {
    ...seed,
    if (snapshot.status != PagedStatus.unavailable)
      for (final page in pages)
        for (final view in page) ..._clips(view),
  }.toList();

  @override
  int visibleCount(List<List<pb.PostView>> pages) =>
      buildState(const PagedSnapshot(), pages).length - seed.length;
}

/// Opens at the tapped clip, then pages vertically through available videos.
class PostVideoViewer extends StatefulWidget {
  const PostVideoViewer({
    super.key,
    required this.view,
    required this.index,
    required this.nearbyVideos,
    required this.discoveryEnabled,
    required this.onClose,
  });
  final pb.PostView view;
  final int index;
  final VoidCallback onClose;
  final bool discoveryEnabled;
  final Map<String, List<int>> nearbyVideos;

  @override
  State<PostVideoViewer> createState() => _PostVideoViewerState();
}

class _PostVideoViewerState extends State<PostVideoViewer> {
  late final _VideoFeed _feed;
  final _pages = PageController();
  var _current = 0;

  @override
  void initState() {
    super.initState();
    final seed = {
      (postId: widget.view.post.postId, index: widget.index),
      ..._clips(widget.view),
      for (final entry in widget.nearbyVideos.entries)
        for (final index in entry.value) (postId: entry.key, index: index),
    }.toList();
    _feed = _VideoFeed(
      widget.discoveryEnabled ? context.read<SearchRepository>() : null,
      seed,
    );
    if (widget.discoveryEnabled) _feed.start();
  }

  @override
  void dispose() {
    _pages.dispose();
    _feed.close();
    super.dispose();
  }

  Widget _clip(pb.PostView view, int index, bool active, bool engagement) {
    final media = view.post.media.elementAtOrNull(index);
    if (media == null ||
        media.contentType != kVideoContentType ||
        media.url.isEmpty) {
      return const Center(child: Text('Video unavailable'));
    }
    final sensitive = VideoLabel.warnings(media.videoLabels).isNotEmpty;
    final poster = media.thumbUrl.isEmpty
        ? const ColoredBox(color: AppColors.photoBackground)
        : CachedNetworkImage(imageUrl: media.thumbUrl, fit: BoxFit.contain);
    return Column(
      children: [
        Expanded(
          child: active
              ? Semantics(
                  label: media.altText.isEmpty ? 'Video' : media.altText,
                  child: PostVideo(
                    key: ValueKey(media.url),
                    url: media.url,
                    startOnOpen: true,
                    loop: true,
                    poster: poster,
                    labels: media.videoLabels,
                  ),
                )
              : sensitive
              ? const ColoredBox(color: AppColors.photoBackground)
              : poster,
        ),
        PhotoBottomPanel(view: view, engagement: engagement),
      ],
    );
  }

  void _move(int delta) {
    final page = _current + delta;
    if (MediaQuery.disableAnimationsOf(context)) {
      _pages.jumpToPage(page);
    } else {
      _pages.animateToPage(
        page,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final engagement = isFeatureEnabled(context, kFeatureEngagement);
    return Theme(
      data: appDarkTheme,
      child: SafeArea(
        child: BlocBuilder<_VideoFeed, List<_Clip>>(
          bloc: _feed,
          builder: (context, clips) {
            final status = _feed.snapshot;
            final retry = status.status == PagedStatus.failed
                ? _feed.retry
                : status.pagingFailed
                ? _feed.retryMore
                : status.stalled
                ? _feed.continueAfterStall
                : null;
            return CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.escape):
                    widget.onClose,
                if (_current > 0)
                  const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                      _move(-1),
                if (_current + 1 < clips.length)
                  const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                      _move(1),
              },
              child: Focus(
                autofocus: true,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsetsDirectional.only(
                        start: 62,
                        end: 8,
                      ),
                      child: SizedBox(
                        height: 56,
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Videos',
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                            ),
                            if (retry != null && _current >= clips.length - 1)
                              TextButton(
                                onPressed: retry,
                                child: Text(
                                  status.stalled ? 'Load more' : 'Retry',
                                ),
                              ),
                            if (clips.length > 1) ...[
                              IconButton(
                                tooltip: 'Previous video',
                                onPressed: _current > 0
                                    ? () => _move(-1)
                                    : null,
                                icon: const Icon(Icons.keyboard_arrow_up),
                              ),
                              IconButton(
                                tooltip: 'Next video',
                                onPressed: _current + 1 < clips.length
                                    ? () => _move(1)
                                    : null,
                                icon: const Icon(Icons.keyboard_arrow_down),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    Expanded(
                      child: PageView.builder(
                        controller: _pages,
                        scrollDirection: Axis.vertical,
                        itemCount: clips.length,
                        onPageChanged: (i) {
                          setState(() => _current = i);
                          if (i >= clips.length - 2) _feed.loadMore();
                        },
                        itemBuilder: (context, i) {
                          final clip = clips[i];
                          final active = i == _current;
                          if (clip.postId == widget.view.post.postId) {
                            return _clip(
                              widget.view,
                              clip.index,
                              active,
                              engagement,
                            );
                          }
                          return LoadedPost(
                            key: ValueKey(clip),
                            postId: clip.postId,
                            builder: (_, view) =>
                                _clip(view, clip.index, active, engagement),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
