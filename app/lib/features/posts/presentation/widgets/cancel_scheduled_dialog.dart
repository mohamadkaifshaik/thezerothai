import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';

/// "Cancel this scheduled post?" (CMP-D6), laid out like X's confirmation: a
/// centred card with a bold title, one muted sentence, a full-width RED filled
/// pill for the destructive answer and an outlined pill under it for the safe
/// one. An alert dialog (announced as one, focus kept inside). Resolves to
/// true for "Cancel post", false for "Keep" or a dismissed dialog.
Future<bool> showCancelScheduledDialog(BuildContext context) async {
  final cancel = await showDialog<bool>(
    context: context,
    builder: (_) => const CancelScheduledDialog(),
  );
  return cancel ?? false;
}

class CancelScheduledDialog extends StatelessWidget {
  const CancelScheduledDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    const shape = StadiumBorder();
    const size = Size.fromHeight(AppSpacing.minTapTarget);
    return AlertDialog(
      title: Text(
        'Cancel this scheduled post?',
        style: theme.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'It will not be sent.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: colors.error,
              foregroundColor: colors.onError,
              minimumSize: size,
              shape: shape,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Cancel post'),
          ),
          const SizedBox(height: AppSpacing.sm),
          OutlinedButton(
            style: OutlinedButton.styleFrom(minimumSize: size, shape: shape),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep'),
          ),
        ],
      ),
    );
  }
}
