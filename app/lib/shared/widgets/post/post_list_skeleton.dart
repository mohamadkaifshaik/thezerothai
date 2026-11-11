import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../primitives/app_skeleton.dart';
import 'post_card.dart';

/// Placeholder rows shaped like posts, shown while a list's first page
/// loads (Home, profile, thread). Built on [AppSkeletonScope]: a slow pulse
/// that is static under reduced motion. Announced once as [semanticsLabel].
///
/// Each row reserves the real card's footprint so nothing jumps when the
/// posts arrive: the 42dp avatar where the card draws it (its gutter, 20 dp
/// on phones and 16 dp wider, plus the inset in its 48 dp tap box, 14 dp
/// down), the body column 12 dp after the tap box and, on every
/// [mediaEvery]th row, a 16:9 media slot under the text.
class PostListSkeleton extends StatelessWidget {
  const PostListSkeleton({
    super.key,
    this.rows = 5,
    this.semanticsLabel = 'Loading posts',
    this.mediaEvery = 3,
  });

  final int rows;

  /// Every n-th row (the 2nd, 5th, ...) reserves a media slot; 0 for none.
  final int mediaEvery;
  final String semanticsLabel;

  /// Same footprint as the real avatar.
  static const double _avatarSize = AppSize.avatarPost;

  @override
  Widget build(BuildContext context) {
    final gutter = postCardGutterOf(context);
    return AppSkeletonScope(
      semanticsLabel: semanticsLabel,
      // A non-scrolling scroll view: it takes its natural height in a sliver,
      // and clips (never overflows) when a screen gives it less.
      child: SingleChildScrollView(
        physics: const NeverScrollableScrollPhysics(),
        child: Column(
          children: [
            for (var i = 0; i < rows; i++) ...[
              AppSkeletonRow(
                avatarSize: _avatarSize,
                barWidths: const [0.4, 1, 0.7],
                mediaSlot: mediaEvery > 0 && i % mediaEvery == 1,
                padding: EdgeInsetsDirectional.fromSTEB(
                  gutter + kPostAvatarInset,
                  kPostListTop + kPostAvatarInset,
                  gutter,
                  AppSpacing.smd,
                ),
                gap: kPostAvatarInset + kPostAvatarGap,
              ),
              const Divider(height: 1),
            ],
          ],
        ),
      ),
    );
  }
}

/// The placeholder of an opened post (PostDetail while it loads): the
/// avatar beside two name bars, then the text across the full width under
/// them, as the focal [PostCard] lays it out. The avatar is 56 dp from the
/// tablet width up (42 dp on phones) and starts at the card's gutter.
/// Announced as [semanticsLabel]; with [announce] false (a post that is
/// leaving, deleted) it says nothing.
class FocalPostSkeleton extends StatelessWidget {
  const FocalPostSkeleton({
    super.key,
    this.semanticsLabel = 'Loading post',
    this.announce = true,
  });

  final String semanticsLabel;
  final bool announce;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final gutter = postCardGutter(width);
    final avatar = width >= AppBreakpoints.mobile
        ? AppSize.avatarLg
        : AppSize.avatarPost;
    final skeleton = AppSkeletonScope(
      semanticsLabel: semanticsLabel,
      child: Padding(
        padding: EdgeInsetsDirectional.fromSTEB(
          gutter,
          AppSpacing.smd,
          gutter,
          AppSpacing.smd,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                AppSkeletonBlock(width: avatar, height: avatar, circle: true),
                const SizedBox(width: kPostAvatarGap),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      FractionallySizedBox(
                        widthFactor: 0.4,
                        child: AppSkeletonBlock(height: AppSpacing.md),
                      ),
                      SizedBox(height: AppSpacing.sm),
                      FractionallySizedBox(
                        widthFactor: 0.3,
                        child: AppSkeletonBlock(height: AppSpacing.md),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            for (final factor in const [1.0, 1.0, 0.6]) ...[
              FractionallySizedBox(
                alignment: AlignmentDirectional.centerStart,
                widthFactor: factor,
                child: const AppSkeletonBlock(height: AppSpacing.md + 2),
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
          ],
        ),
      ),
    );
    return announce ? skeleton : ExcludeSemantics(child: skeleton);
  }
}
