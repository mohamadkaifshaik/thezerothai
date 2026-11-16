import 'package:material_ui/material_ui.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/primitives/app_avatar.dart';
import '../bloc/timeline_state.dart';

/// The "N new posts" pill a feed shows instead of inserting posts above what
/// the user is reading (section 7). Tap to show them. Up to three small author
/// avatars (overlapping) sit between the arrow and the label.
///
/// Semantics: one button, "Show new posts" (the count is its value); a polite
/// live region, so a screen reader announces it once, when it appears.
class NewPostsPill extends StatelessWidget {
  const NewPostsPill({
    super.key,
    required this.count,
    required this.onTap,
    this.authors = const [],
  });

  final int count;
  final VoidCallback onTap;
  final List<NewPostAuthor> authors;

  static const double _avatarRadius = 10;
  static const double _avatarStep = 14;

  @override
  Widget build(BuildContext context) {
    final label = count == 1 ? '1 new post' : '$count new posts';
    final shown = authors.take(kNewPostAvatarCount).toList();
    return Semantics(
      button: true,
      liveRegion: true,
      label: 'Show new posts',
      value: label,
      excludeSemantics: true,
      onTap: onTap,
      child: FilledButton(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, AppSpacing.minTapTarget),
          shape: const StadiumBorder(),
        ),
        onPressed: onTap,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.arrow_upward, size: 18),
            if (shown.isNotEmpty) ...[
              const SizedBox(width: AppSpacing.xs),
              SizedBox(
                key: const ValueKey('new-posts-avatars'),
                width: _avatarRadius * 2 + _avatarStep * (shown.length - 1),
                height: _avatarRadius * 2,
                child: Stack(
                  children: [
                    for (var i = 0; i < shown.length; i++)
                      Positioned(
                        left: _avatarStep * i,
                        child: AppAvatar(
                          url: shown[i].avatarUrl,
                          name: shown[i].name,
                          radius: _avatarRadius,
                          maxDecodePx: 64,
                        ),
                      ),
                  ],
                ),
              ),
            ],
            const SizedBox(width: AppSpacing.xs),
            Text(label),
          ],
        ),
      ),
    );
  }
}
