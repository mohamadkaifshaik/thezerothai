import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';

/// A gap marker between two runs of cached posts: tap to load the posts in
/// between with the gap's page token (ADR-0010 D14).
class TimelineGapRow extends StatelessWidget {
  const TimelineGapRow({super.key, required this.loading, required this.onTap});

  final bool loading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: loading ? 'Loading more posts' : 'Show more posts',
      excludeSemantics: true,
      child: InkWell(
        onTap: loading ? null : onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppSpacing.minTapTarget),
          child: Center(
            child: loading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(
                    'Show more posts',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
