import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../features/auth/presentation/widgets/verify_email_view.dart';
import '../../../features/posts/presentation/bloc/pending_posts_cubit.dart';
import '../../../features/posts/presentation/bloc/post_sender.dart';
import 'pending_post_status_row.dart';

/// The status rows of the posts being sent, shown above a screen's feed:
/// Home, and the own profile's Posts tab. Renders nothing when none is
/// pending. Wrap it in a `SliverToBoxAdapter` inside a `CustomScrollView`.
/// Reads the app-wide [PendingPostsCubit]; pass [authorId] to show only that
/// author's posts (the own profile), omit it for Home. Retry, Edit and
/// Dismiss go to the session's [PostSender] (absent in bare test trees: the
/// row then shows no actions).
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
    final sender = context.read<PostSender?>();
    return Column(
      children: [
        for (final p in shown)
          PendingPostStatusRow(
            key: ValueKey('pending-${p.localId}'),
            post: p,
            onRetry: sender == null ? null : () => sender.retry(p.localId),
            // Edit is always there: the composer reopens from the post
            // itself (its unsent-post row when it has one).
            onEdit: sender == null ? null : () => _edit(context, sender, p),
            onDismiss: sender == null ? null : () => sender.release(p.localId),
            onVerify: sender == null ? null : () => _verify(context, p),
            onUndo: sender == null ? null : () => _undo(context, sender, p),
          ),
      ],
    );
  }

  /// Undo: the composer reopens with everything the post had.
  Future<void> _undo(BuildContext context, PostSender sender, PendingPost p) =>
      _reopen(context, sender.undo(p.localId));

  Future<void> _edit(BuildContext context, PostSender sender, PendingPost p) =>
      _reopen(context, sender.edit(p.localId));

  Future<void> _reopen(
    BuildContext context,
    Future<PostEditSeed?> pendingSeed,
  ) async {
    final router = GoRouter.of(context);
    final seed = await pendingSeed;
    if (seed == null) return;
    // The page went away while the row was released (sign-out, navigation):
    // the photos go with it and nothing opens.
    if (!context.mounted) {
      unawaited(seed.attachments?.close());
      return;
    }
    await router.push<void>(AppRouter.composePath, extra: seed);
  }

  /// The existing verify-email screen, over the page; Retry follows.
  void _verify(BuildContext context, PendingPost p) {
    final navigator = Navigator.of(context, rootNavigator: true);
    navigator.push<void>(
      MaterialPageRoute<void>(
        builder: (_) =>
            VerifyEmailView(banner: p.error, onBack: () => navigator.pop()),
      ),
    );
  }
}
