import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import 'app_main_column.dart';

/// The header of a pushed list page (followers/following): a back button, the
/// [title] (announced as a header, one line) and a divider underneath. Use it
/// inside a main column; [onBack] decides where Back goes. Purely
/// presentational.
///
/// [titleContent] replaces the one-line title text with richer content (the
/// conversation header's avatar, name and handle); [title] is then only the
/// accessible name of the header. [actions] sit at the end (an overflow
/// menu); both default to nothing, so existing callers are unchanged.
/// [subtitle] adds a muted line under the title (the plan a People page is
/// about).
class AppBackHeader extends StatelessWidget {
  const AppBackHeader({
    super.key,
    required this.title,
    required this.onBack,
    this.backTooltip = 'Back',
    this.titleContent,
    this.subtitle,
    this.actions = const [],
    this.leading,
  });

  final String title;
  final VoidCallback onBack;
  final String backTooltip;
  final Widget? titleContent;
  final String? subtitle;
  final List<Widget> actions;

  /// Replaces the back button (a root destination leads with the account
  /// avatar instead: there is nothing to go back to).
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // The controls across the pane on the tablet layout (T8f, one header
        // rule): Back at the pane's leading edge, the actions at its
        // trailing edge. A pass-through everywhere else.
        AppFullBleed(
          interactive: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.xs,
              vertical: AppSpacing.sm,
            ),
            child: Row(
              children: [
                leading ??
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
                        (subtitle == null
                            ? Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleLarge,
                              )
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.titleLarge,
                                  ),
                                  Text(
                                    subtitle!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              )),
                  ),
                ),
                ...actions,
              ],
            ),
          ),
        ),
        // Spans the pane on the tablet layout (the column's bleed).
        const AppFullBleed(child: Divider(height: 1)),
      ],
    );
  }
}
