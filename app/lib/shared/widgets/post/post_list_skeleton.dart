import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../primitives/app_skeleton.dart';

/// Placeholder rows shaped like posts, shown while a list's first page
/// loads (Home, profile, thread). Built on [AppSkeletonScope]: a slow pulse
/// that is static under reduced motion. Announced once as [semanticsLabel].
///
/// Each row reserves the real card's footprint so nothing jumps when the
/// posts arrive: the 40dp avatar column, the card padding (16/12) and, on
/// every [mediaEvery]th row, a 16:9 media slot under the text.
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

  /// Same footprint as the real avatar column.
  static const double _avatarSize = AppSize.avatarMd;

  @override
  Widget build(BuildContext context) {
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
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.smd,
                ),
                gap: AppSpacing.sm,
              ),
              const Divider(),
            ],
          ],
        ),
      ),
    );
  }
}
