import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';

/// Up to five tappable free handles under a taken one (sign-up and Change
/// handle). Tapping one fills the field and asks for it to be checked again
/// (the caller does both in [onChosen]). The look is built from the theme's
/// chips; the design mocks have no suggestion chips.
class HandleSuggestionChips extends StatelessWidget {
  const HandleSuggestionChips({
    super.key,
    required this.handles,
    required this.onChosen,
  });

  final List<String> handles;
  final ValueChanged<String> onChosen;

  @override
  Widget build(BuildContext context) {
    if (handles.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Try one of these',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Wrap(
          key: const ValueKey('handle-suggestions'),
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.xs,
          children: [
            for (final h in handles)
              ActionChip(
                label: Text('@$h'),
                tooltip: 'Use @$h',
                onPressed: () => onChosen(h),
              ),
          ],
        ),
      ],
    );
  }
}
