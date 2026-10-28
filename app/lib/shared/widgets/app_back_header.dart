import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// The header of a pushed list page (followers/following): a back button, the
/// [title] (announced as a header, one line) and a divider underneath. Use it
/// inside a main column; [onBack] decides where Back goes. Purely
/// presentational.
///
/// [titleContent] replaces the one-line title text with richer content (the
/// conversation header's avatar, name and handle); [title] is then only the
/// accessible name of the header. [actions] sit at the end (an overflow
/// menu); both default to nothing, so existing callers are unchanged.
class AppBackHeader extends StatelessWidget {
  const AppBackHeader({
    super.key,
    required this.title,
    required this.onBack,
    this.backTooltip = 'Back',
    this.titleContent,
    this.actions = const [],
  });

  final String title;
  final VoidCallback onBack;
  final String backTooltip;
  final Widget? titleContent;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xs,
            vertical: AppSpacing.sm,
          ),
          child: Row(
            children: [
              IconButton(
                tooltip: backTooltip,
                icon: const Icon(Icons.arrow_back),
                onPressed: onBack,
              ),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Semantics(
                  header: true,
                  child:
                      titleContent ??
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleLarge,
                      ),
                ),
              ),
              ...actions,
            ],
          ),
        ),
        const Divider(height: 1),
      ],
    );
  }
}
