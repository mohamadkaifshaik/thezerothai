import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../primitives/app_skeleton.dart';

/// Placeholder rows shaped like user rows (avatar, name, handle), shown while
/// a people list's first page loads. Built on [AppSkeletonScope]: a slow pulse
/// that is static under reduced motion. Announced once as [semanticsLabel].
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
    return AppSkeletonScope(
      semanticsLabel: semanticsLabel,
      child: Column(
        children: [
          for (var i = 0; i < rows; i++) ...[
            const AppSkeletonRow(
              avatarSize: _avatarSize,
              barWidths: [0.5, 0.3],
            ),
            const Divider(height: 1),
          ],
        ],
      ),
    );
  }
}
