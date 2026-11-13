import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/post/post_list_skeleton.dart';
import '../../../../shared/widgets/primitives/app_skeleton.dart';

/// Key the tests read.
const kProfileSkeletonKey = ValueKey('profile-skeleton');

/// The profile's loading state: the header (avatar, name, handle, bio lines)
/// and a few post rows, announced once as [semanticsLabel]. Replaces the bare
/// spinner; error and not-found states are unchanged.
class ProfileSkeleton extends StatelessWidget {
  const ProfileSkeleton({super.key, this.semanticsLabel = 'Loading profile'});

  final String semanticsLabel;

  @override
  Widget build(BuildContext context) {
    return AppSkeletonScope(
      key: kProfileSkeletonKey,
      semanticsLabel: semanticsLabel,
      child: SingleChildScrollView(
        physics: const NeverScrollableScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const AppSkeletonBlock(
                    width: AppSize.avatarProfileNarrow,
                    height: AppSize.avatarProfileNarrow,
                    circle: true,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  for (final width in const [0.4, 0.25, 0.9, 0.7]) ...[
                    FractionallySizedBox(
                      widthFactor: width,
                      child: const AppSkeletonBlock(height: AppSpacing.md),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                ],
              ),
            ),
            const Divider(height: 1),
            const PostListSkeleton(rows: 3, mediaEvery: 0),
          ],
        ),
      ),
    );
  }
}
