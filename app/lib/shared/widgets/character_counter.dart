import 'package:flutter/material.dart';

/// Characters left in a text field (negative once over the limit, e.g. `-1`
/// for 281 of 280). Announced as "Characters remaining: N" / "Characters over
/// the limit: N" instead of the bare number. Used by the composer, the reply
/// composer and Edit profile (as `InputDecoration.counter`).
class CharacterCounter extends StatelessWidget {
  const CharacterCounter({super.key, required this.remaining});

  final int remaining;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final over = remaining < 0;
    final label = over
        ? 'Characters over the limit: ${-remaining}'
        : 'Characters remaining: $remaining';
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: Text(
        '$remaining',
        style: theme.textTheme.labelLarge?.copyWith(
          color: over
              ? theme.colorScheme.error
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
