import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// Placeholder rows shaped like posts, shown while a list's first page
/// loads (Home, profile, thread). Static (no shimmer): cheap, and respects
/// reduced motion. Announced once as [semanticsLabel].
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
    final colors = Theme.of(context).colorScheme;
    Widget bar(double widthFactor) => FractionallySizedBox(
      alignment: AlignmentDirectional.centerStart,
      widthFactor: widthFactor,
      child: Container(
        height: AppSpacing.md,
        decoration: BoxDecoration(
          color: colors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
      ),
    );
    return Semantics(
      liveRegion: true,
      label: semanticsLabel,
      // A non-scrolling scroll view: it takes its natural height in a sliver,
      // and clips (never overflows) when a screen gives it less.
      child: ExcludeSemantics(
        child: SingleChildScrollView(
          physics: const NeverScrollableScrollPhysics(),
          child: Column(
            children: [
              for (var i = 0; i < rows; i++) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.smd,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: _avatarSize,
                        height: _avatarSize,
                        decoration: BoxDecoration(
                          color: colors.surfaceContainerHigh,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Column(
                          children: [
                            bar(0.4),
                            const SizedBox(height: AppSpacing.sm),
                            bar(1),
                            const SizedBox(height: AppSpacing.sm),
                            bar(0.7),
                            if (mediaEvery > 0 && i % mediaEvery == 1) ...[
                              const SizedBox(height: AppSpacing.sm),
                              AspectRatio(
                                aspectRatio: 16 / 9,
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: colors.surfaceContainerHigh,
                                    borderRadius: BorderRadius.circular(
                                      AppRadius.lg,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
