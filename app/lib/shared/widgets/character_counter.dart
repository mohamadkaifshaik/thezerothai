import 'package:flutter/material.dart';

/// Characters left in a text field (negative once over the limit, e.g. `-1`
/// for 281 of 280). Announced as "Characters remaining: N" / "Characters over
/// the limit: N" instead of the bare number. Used by the composer, the reply
/// composer and Edit profile (as `InputDecoration.counter`).
///
/// With [limit] set the visible text is the used count against it, "7 / 25"
/// (the poll builder's choices, W6-12); the spoken label is unchanged.
class CharacterCounter extends StatelessWidget {
  const CharacterCounter({super.key, required this.remaining, this.limit});

  final int remaining;

  /// The field's limit; null shows the bare remaining count.
  final int? limit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final over = remaining < 0;
    final label = over
        ? 'Characters over the limit: ${-remaining}'
        : 'Characters remaining: $remaining';
    final shown = limit == null
        ? '$remaining'
        : '${limit! - remaining} / $limit';
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: Text(
        shown,
        style: theme.textTheme.labelLarge?.copyWith(
          color: over
              ? theme.colorScheme.error
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
