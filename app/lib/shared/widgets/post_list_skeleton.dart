import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// Placeholder rows shaped like posts, shown while a list's first page
/// loads (Home, profile, thread). Static (no shimmer): cheap, and respects
/// reduced motion. Announced once as [semanticsLabel].
class PostListSkeleton extends StatelessWidget {
  const PostListSkeleton({
    super.key,
    this.rows = 5,
    this.semanticsLabel = 'Loading posts',
  });

  final int rows;
  final String semanticsLabel;

  /// Same footprint as the real avatar column.
  static const double _avatarSize = AppSpacing.xxl - AppSpacing.sm;

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
      child: ExcludeSemantics(
        child: Column(
          children: [
            for (var i = 0; i < rows; i++) ...[
              Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
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
    );
  }
}
