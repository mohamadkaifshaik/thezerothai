import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// A display headline with one accented word: "Pick a new " + "handle" + "."
/// (the mocks' `h1.display` and `.accent`). Announced as a header; the
/// accent is the theme's accent text colour, not a colour alone: the words
/// read the same without it. [size] is one of [AppTypeTokens.displaySizes].
class AppAccentHeadline extends StatelessWidget {
  const AppAccentHeadline({
    super.key,
    required this.lead,
    required String this.accent,
    required this.size,
    this.tail = '.',
  });

  /// A headline with no accented word ("Leaving DZEROTH?").
  const AppAccentHeadline.plain(this.lead, {super.key, required this.size})
    : accent = null,
      tail = '';

  final String lead;
  final String? accent;
  final String tail;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.displayLarge!.copyWith(
      fontSize: size,
      letterSpacing: AppTypeTokens.displayTracking * size,
      color: theme.colorScheme.onSurface,
    );
    return Semantics(
      header: true,
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: lead),
            if (accent != null)
              TextSpan(
                text: accent,
                style: TextStyle(color: context.appColors.accentText),
              ),
            if (tail.isNotEmpty) TextSpan(text: tail),
          ],
        ),
        style: base,
      ),
    );
  }
}
