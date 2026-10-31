import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// A heading over a muted line, start aligned, no illustration: the empty
/// Scheduled list, the empty Unsent posts tab and the "not available" state.
/// Not [AppEmptyView], which centres an icon.
class HeadlineMessage extends StatelessWidget {
  const HeadlineMessage({super.key, required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              title,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            body,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
