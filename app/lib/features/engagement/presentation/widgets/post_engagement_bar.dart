import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/feature_flags/feature_flags.dart';
import '../../../../core/feature_flags/quote_ui.dart';
import '../../../../core/router/app_router.dart';
import '../../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../../../gen/dzeroth/posts/v1/posts.pbenum.dart' show PostKind;
import '../../../../shared/widgets/post_action_bar.dart';
import '../../../posts/data/posts_repository.dart';
import '../../../posts/domain/posts_feature_flag.dart';
import '../../domain/engagement_entry.dart';
import '../bloc/engagement_cubit.dart';
import '../bloc/engagement_state.dart';
import '../engagement_error_messages.dart';
import 'repost_sheet.dart';

/// The frozen snapshot a quote of [view] previews: the original for a REPOST
/// row (quoting a repost quotes its original, ADR-0018 D4), else the post.
pb.EmbeddedPost quotePreviewOf(pb.PostView view) {
  final post = view.post;
  if (post.kind == PostKind.POST_KIND_REPOST && post.hasEmbedded()) {
    return post.embedded;
  }
  return pb.EmbeddedPost(
    postId: post.postId,
    author: post.author,
    text: post.text,
    media: post.media,
    createdAt: post.hasCreatedAt() ? post.createdAt : null,
  );
}

/// The reply / repost / like row of one post, driven by the session's
/// [EngagementCubit] (ADR-0018, plan T7). Nothing is held here: taps call the
/// cubit, which applies the change at once and rolls it back on failure.
///
/// - Acts on [engagementTargetId]: the original for a REPOST row.
/// - Rebuilds only when the entry of that one target changes, so a like
///   rebuilds one card, not the list. A cubit entry older than the row (the
///   feed refreshed since) is ignored: the newer server data wins.
/// - Reply opens the post (its thread has the composer) and is offered only
///   with the `replies` sub-feature and [showReply]; Share does not exist
///   yet, so it is not offered; Quote is in the repost sheet when
///   `PostsRepository.subFeatureEnabled('quotes')`.
/// - A failed action shows one snackbar (from the card of that target),
///   with typed wording; it never auto-retries.
class PostEngagementBar extends StatelessWidget {
  const PostEngagementBar({
    super.key,
    required this.view,
    this.showReply = true,
    this.onQuote,
    this.quoteUiEnabled = kQuoteUiEnabled,
  });

  final pb.PostView view;

  /// Offer Reply (opens the post). The post screen, which has its own reply
  /// composer, turns it off for the focal post.
  final bool showReply;

  /// Opens the quote composer for [view]. Defaults to `/compose?quote=<id>`
  /// with the preview as `extra`.
  final VoidCallback? onQuote;

  /// Whether the repost sheet may offer Quote (MVP build: off, see
  /// [kQuoteUiEnabled]).
  final bool quoteUiEnabled;

  @override
  Widget build(BuildContext context) {
    final target = engagementTargetId(view.post);
    if (target.isEmpty) return const SizedBox.shrink();
    final cubit = context.read<EngagementCubit>();
    final shown = EngagementEntry.fromView(view);
    final replies =
        showReply && isFeatureEnabled(context, kPostsSubFeatureReplies);

    return BlocConsumer<EngagementCubit, EngagementState>(
      listenWhen: (before, after) =>
          after.failure != null &&
          after.failure!.postId == target &&
          before.failure?.serial != after.failure!.serial,
      listener: (context, state) {
        final failure = state.failure!;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                engagementErrorMessage(failure.error, action: failure.action),
              ),
            ),
          );
        cubit.failureShown();
      },
      buildWhen: (before, after) =>
          before.entries[target] != after.entries[target],
      builder: (context, state) {
        final entry = state.entries[target];
        final current = entry != null && entry.matches(view) ? entry : shown;
        return PostActionBar(
          showDisabled: false,
          replyCount: view.post.replyCount.toInt(),
          repostCount: current.repostCount ?? 0,
          likeCount: current.likeCount ?? 0,
          liked: current.liked,
          reposted: current.reposted,
          actions: PostActions(
            onReply: replies
                ? () => context.push(AppRouter.postPath(target))
                : null,
            onLike: () =>
                cubit.setLiked(target, liked: !current.liked, shown: shown),
            onRepost: () => _repost(context, cubit, target, current, shown),
          ),
        );
      },
    );
  }

  Future<void> _repost(
    BuildContext context,
    EngagementCubit cubit,
    String target,
    EngagementEntry current,
    EngagementEntry shown,
  ) async {
    final canQuote =
        quoteUiEnabled &&
        context.read<PostsRepository>().subFeatureEnabled(
          kPostsSubFeatureQuotes,
        );
    final choice = await showRepostSheet(
      context,
      reposted: current.reposted,
      canQuote: canQuote,
    );
    if (choice == null) return;
    switch (choice) {
      case RepostChoice.repost:
        unawaited(cubit.setReposted(target, reposted: true, shown: shown));
      case RepostChoice.undoRepost:
        unawaited(cubit.setReposted(target, reposted: false, shown: shown));
      case RepostChoice.quote:
        if (!context.mounted) return;
        final custom = onQuote;
        if (custom != null) {
          custom();
        } else {
          unawaited(
            context.push(
              AppRouter.composeQuotePath(target),
              extra: quotePreviewOf(view),
            ),
          );
        }
    }
  }
}
