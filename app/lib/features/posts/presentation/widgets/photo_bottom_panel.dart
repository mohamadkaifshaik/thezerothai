import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/feature_flags/feature_flags.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/common/v1/common.pb.dart' as common;
import '../../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../../../shared/widgets/post/post_action_bar.dart';
import '../../../../shared/widgets/primitives/app_avatar.dart';
import '../../../../shared/widgets/user/follow_button.dart';
import '../../../engagement/presentation/widgets/post_engagement_bar.dart';
import '../../../graph/data/graph_repository.dart';
import '../../../graph/domain/graph_feature_flag.dart';
import '../../../graph/presentation/bloc/relationship_cubit.dart';
import '../../../media/domain/media_feature_flag.dart';
import '../../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../domain/composer_attachment_rules.dart' show kFeatureGif;
import '../../domain/posts_feature_flag.dart';
import '../../domain/reply_audience.dart';
import '../../domain/reply_start.dart';

/// Whether the photo viewer's panel offers "Post your reply" for [view]: the
/// `posts` flag and the `replies` sub-feature are on and the server has not
/// said this viewer may not reply (reply policy).
bool photoRepliesAllowed(BuildContext context, pb.PostView view) =>
    isFeatureEnabled(context, kFeaturePosts) &&
    isFeatureEnabled(context, kPostsSubFeatureReplies) &&
    !replyKnownNotAllowed(view);

/// The panel under the photo in the viewer, as in X's phone app: the author
/// row (avatar, name, handle, Follow), the post text clamped to two lines,
/// the action row and the "Post your reply" bar. It is part of the viewer's
/// controls (the viewer hides and shows it with them) and is drawn in the
/// dark theme whatever the app's.
///
/// [engagement] is the `engagement` flag: without it there is no action row.
class PhotoBottomPanel extends StatelessWidget {
  const PhotoBottomPanel({
    super.key,
    required this.view,
    required this.engagement,
  });

  final pb.PostView view;
  final bool engagement;

  @override
  Widget build(BuildContext context) {
    final post = view.post;
    final replies = photoRepliesAllowed(context, view);
    return Theme(
      data: appDarkTheme,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: AppGradients.photoScrimBottom,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.xl,
            AppSpacing.md,
            AppSpacing.sm,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _AuthorRow(post: post),
              if (post.text.trim().isNotEmpty) ...[
                const SizedBox(height: AppSpacing.sm),
                _ClampedText(text: post.text),
              ],
              if (engagement)
                PostEngagementBar(
                  view: view,
                  style: PostActionBarStyle.photoViewer,
                  iconSize: AppPhotoPanel.actionIcon,
                ),
              if (replies) _ReplyBar(postId: post.postId),
            ],
          ),
        ),
      ),
    );
  }
}

/// Avatar (40 dp), bold display name with the verified badge, grey @handle,
/// and the shared [FollowButton]. A tap on the avatar or name opens the
/// profile. Follow is hidden on the viewer's own posts and with `graph` off.
class _AuthorRow extends StatelessWidget {
  const _AuthorRow({required this.post});

  final pb.Post post;

  void _openProfile(BuildContext context) {
    if (post.author.userId.isEmpty) return;
    context.push(AppRouter.profileByIdPath(post.author.userId));
  }

  @override
  Widget build(BuildContext context) {
    final author = post.author;
    final theme = Theme.of(context);
    final viewerId = context.read<OnboardingBloc>().state.profile?.userId;
    final showFollow =
        isFeatureEnabled(context, kFeatureGraph) &&
        author.userId.isNotEmpty &&
        author.userId != viewerId;
    final name = author.displayName.isEmpty
        ? '@${author.handle}'
        : author.displayName;
    final who = InkWell(
      onTap: () => _openProfile(context),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: AppSpacing.minTapTarget),
        child: Row(
          children: [
            AppAvatar(
              url: author.avatarUrl,
              name: author.displayName,
              radius: AppPhotoPanel.authorAvatar / 2,
            ),
            const SizedBox(width: AppSpacing.smd),
            Expanded(
              child: Semantics(
                link: true,
                label: 'Open profile of $name',
                excludeSemantics: true,
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: AppColors.onPhotoBackground,
                        ),
                      ),
                    ),
                    if (author.verified) ...[
                      const SizedBox(width: AppSpacing.xs),
                      const Icon(
                        Icons.verified,
                        size: AppIconSize.sm,
                        color: AppPhotoPanel.accent,
                      ),
                    ],
                    if (author.handle.isNotEmpty) ...[
                      const SizedBox(width: AppSpacing.xs),
                      Flexible(
                        child: Text(
                          '@${author.handle}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontSize: 15,
                            color: AppPhotoPanel.muted,
                          ),
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
    );
    if (!showFollow) return who;
    return Row(
      children: [
        Expanded(child: who),
        const SizedBox(width: AppSpacing.sm),
        _FollowControl(author: author),
      ],
    );
  }
}

/// The shared [FollowButton] with a [RelationshipCubit] of its own, seeded
/// from the graph cache as the post menu does.
class _FollowControl extends StatefulWidget {
  const _FollowControl({required this.author});

  final common.AuthorSnapshot author;

  @override
  State<_FollowControl> createState() => _FollowControlState();
}

class _FollowControlState extends State<_FollowControl> {
  RelationshipCubit? _cubit;
  String _userId = '';

  RelationshipCubit _cubitFor(BuildContext context) {
    final userId = widget.author.userId;
    if (_cubit != null && _userId == userId) return _cubit!;
    _cubit?.close();
    final repository = context.read<GraphRepository>();
    _userId = userId;
    return _cubit = RelationshipCubit(
      graphRepository: repository,
      userId: userId,
      initial: repository.cached(userId) ?? graph.Relationship(userId: userId),
    );
  }

  @override
  void dispose() {
    _cubit?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => BlocProvider.value(
    value: _cubitFor(context),
    child: const FollowButton(),
  );
}

/// The post text, white 15/20, clamped to two lines with "Show more" (which
/// expands it in place). Nothing is drawn for empty text (the caller checks).
class _ClampedText extends StatefulWidget {
  const _ClampedText({required this.text});

  final String text;

  @override
  State<_ClampedText> createState() => _ClampedTextState();
}

class _ClampedTextState extends State<_ClampedText> {
  static const _lines = 2;
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium?.copyWith(
      fontSize: 15,
      height: 20 / 15,
      color: AppColors.onPhotoBackground,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          maxLines: _lines,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: constraints.maxWidth);
        final overflows = painter.didExceedMaxLines;
        painter.dispose();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.text,
              maxLines: _expanded ? null : _lines,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
            if (overflows && !_expanded)
              InkWell(
                onTap: () => setState(() => _expanded = true),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: AppSpacing.minTapTarget,
                  ),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    widthFactor: 1,
                    child: Text(
                      'Show more',
                      style: style?.copyWith(color: AppPhotoPanel.accent),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// "Post your reply": the viewer's avatar, a pill field and the Photo, GIF
/// and Emoji buttons. Each opens the reply composer for this post
/// ([ReplyStart]); Photo needs `media`, GIF `media` and `gif`.
class _ReplyBar extends StatelessWidget {
  const _ReplyBar({required this.postId});

  final String postId;

  void _open(BuildContext context, ReplyStart start) =>
      context.push(AppRouter.composeReplyPath(postId, start: start));

  @override
  Widget build(BuildContext context) {
    final profile = context.read<OnboardingBloc>().state.profile;
    final media = isFeatureEnabled(context, kFeatureMedia);
    final gif = media && isFeatureEnabled(context, kFeatureGif);
    final style = Theme.of(context).textTheme.bodyMedium
        ?.copyWith(fontSize: 15, color: AppPhotoPanel.muted);
    Widget icon(IconData data, String label, ReplyStart start) => IconButton(
      tooltip: label,
      icon: Icon(data, color: AppPhotoPanel.accent),
      onPressed: () => _open(context, start),
    );
    return Row(
      children: [
        AppAvatar(
          url: profile?.avatarThumbUrl ?? '',
          name: profile?.displayName ?? '',
          radius: AppPhotoPanel.replyAvatar / 2,
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Semantics(
            button: true,
            label: 'Post your reply',
            excludeSemantics: true,
            onTap: () => _open(context, ReplyStart.text),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _open(context, ReplyStart.text),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: AppSpacing.minTapTarget,
                ),
                child: Center(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: AppPhotoPanel.replyField,
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                    ),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        minHeight: AppPhotoPanel.replyFieldHeight,
                      ),
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.md,
                            vertical: AppSpacing.sm,
                          ),
                          child: Text(
                            'Post your reply',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: style,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (media) icon(Icons.image_outlined, 'Add photo', ReplyStart.photo),
        if (gif) icon(Icons.gif_box_outlined, 'Add GIF', ReplyStart.gif),
        icon(Icons.emoji_emotions_outlined, 'Add emoji', ReplyStart.emoji),
      ],
    );
  }
}
