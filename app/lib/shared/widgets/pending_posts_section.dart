import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'pending_post_row.dart';

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
          PendingPostRow(
            key: ValueKey('pending-${p.localId}'),
            text: p.text,
            author: p.author,
            createdAt: p.createdAt,
            thumbnails: p.thumbnails,
            now: now,
          ),
      ],
    );
  }
}
