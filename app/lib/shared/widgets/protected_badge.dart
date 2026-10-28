import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// The small lock after the name of a protected account (ADR-0025): the profile
/// header, and the author line of a post only approved followers can see. A
/// 16dp glyph in the secondary text colour, announced as "Protected account".
/// It is a plain inline glyph, not a button, so it adds no tap target; put it
/// in a `Wrap` or a `Text.rich` `WidgetSpan` so it moves under the name at a
/// large text scale instead of overlapping it.
class ProtectedBadge extends StatelessWidget {
  const ProtectedBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Protected account',
      child: ExcludeSemantics(
        child: Icon(
          Icons.lock_outline,
          size: AppIconSize.sm,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
