import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// Placeholder rows shaped like user rows (avatar, name, handle), shown while
/// a people list's first page loads. Static (no shimmer): cheap, and respects
/// reduced motion. Announced once as [semanticsLabel].
class UserListSkeleton extends StatelessWidget {
  const UserListSkeleton({
    super.key,
    this.rows = 6,
    this.semanticsLabel = 'Loading people',
  });

  final int rows;
  final String semanticsLabel;

  /// Same footprint as the real row's avatar (`AppAvatar` radius 20).
  static const double _avatarSize = AppSpacing.xl + AppSpacing.sm;

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
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.sm,
                ),
                child: Row(
                  children: [
                    Container(
                      width: _avatarSize,
                      height: _avatarSize,
                      decoration: BoxDecoration(
                        color: colors.surfaceContainerHigh,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        children: [
                          bar(0.5),
                          const SizedBox(height: AppSpacing.sm),
                          bar(0.3),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
            ],
          ],
        ),
      ),
    );
  }
}
