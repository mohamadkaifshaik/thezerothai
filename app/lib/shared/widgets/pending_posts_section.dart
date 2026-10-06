import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart';

import '../../core/theme/app_theme.dart';
import '../../features/posts/presentation/bloc/pending_posts_cubit.dart';
import '../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'post_card.dart';

/// The optimistic posts (T16) a screen shows above its feed: Home, and the
/// own profile's Posts tab. Renders nothing when none are pending. Wrap it in
/// a `SliverToBoxAdapter` inside a `CustomScrollView`. Reads the app-wide
/// [PendingPostsCubit]; pass [authorId] to show only that author's posts
/// (the own profile), omit it for Home.
class PendingPostsSection extends StatelessWidget {
  const PendingPostsSection({super.key, this.authorId, this.now});

  final String? authorId;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final pending = context.watch<PendingPostsCubit>().state;
    final shown = [
      for (final p in pending)
        if (authorId == null || p.author.userId == authorId) p,
    ];
    if (shown.isEmpty) return const SizedBox.shrink();
    return Column(
      children: [
        for (final p in shown)
          Semantics(
            label: 'Sending your post',
            child: Opacity(
              key: ValueKey('pending-${p.localId}'),
              opacity: 0.6,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  PostCard(
                    view: pb.PostView(
                      post: pb.Post(
                        postId: p.localId,
                        text: p.text,
                        author: p.author,
                        createdAt: Timestamp.fromDateTime(p.createdAt.toUtc()),
                      ),
                    ),
                    viewerUserId: p.author.userId,
                    graphActionsEnabled: false,
                    now: now,
                  ),
                  Padding(
                    padding: const EdgeInsets.only(
                      left: AppSpacing.md,
                      bottom: AppSpacing.sm,
                    ),
                    child: Text(
                      'Posting...',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
