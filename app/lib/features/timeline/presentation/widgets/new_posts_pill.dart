import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';

/// The "N new posts" pill a feed shows instead of inserting posts above what
/// the user is reading (ADR-0004 section 7). Tap to show them.
class NewPostsPill extends StatelessWidget {
  const NewPostsPill({super.key, required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final label = count == 1 ? '1 new post' : '$count new posts';
    return Semantics(
      button: true,
      liveRegion: true,
      label: label,
      excludeSemantics: true,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, AppSpacing.minTapTarget),
          shape: const StadiumBorder(),
        ),
        onPressed: onTap,
        icon: const Icon(Icons.arrow_upward, size: 18),
        label: Text(label),
      ),
    );
  }
}
