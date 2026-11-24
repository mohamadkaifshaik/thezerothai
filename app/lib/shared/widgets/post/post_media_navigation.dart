import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/router/app_router.dart';
import '../../../features/media/domain/processed_image.dart'
    show kVideoContentType;
import '../../../features/posts/presentation/bloc/thread_cubit.dart';
import '../../../features/timeline/presentation/bloc/timeline_cubit.dart';

/// Carry the visible conversation or timeline into the video viewer.
void openPostVideo(BuildContext context, String postId, int index) {
  final timeline = context.read<TimelineCubit?>()?.state.entries;
  final thread = context.read<ThreadCubit?>()?.state;
  final neighbours = [
    if (timeline != null)
      for (final entry in timeline) ?entry.postView,
    if (thread != null) ...[
      ?thread.root,
      ?thread.parent,
      ?thread.focal,
      ...thread.replies,
    ],
  ];
  // Only pass media locations. Each post is checked again when opened.
  final videos = <String, List<int>>{};
  for (final view in neighbours) {
    final post = view.post;
    for (var i = 0; i < post.media.length; i++) {
      if (post.media[i].contentType == kVideoContentType &&
          post.media[i].url.isNotEmpty) {
        (videos[post.postId] ??= []).add(i);
      }
    }
  }
  context.push(AppRouter.postPhotoPath(postId, index + 1), extra: videos);
}
