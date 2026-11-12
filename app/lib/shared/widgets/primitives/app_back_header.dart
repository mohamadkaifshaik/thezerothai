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
/// accessible name of the header. [subtitle] puts one muted line under the
/// title (the viewer's @handle, "3 pending", the plan a People page is
/// about). [actions] sit at the end (an overflow menu); all default to
/// nothing, so existing callers are unchanged.
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
    final subtitle = this.subtitle;
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
                            ? _titleText(theme)
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _titleText(theme),
                                  Text(
                                    subtitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodyMedium?.copyWith(
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

  Text _titleText(ThemeData theme) => Text(
    title,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: theme.textTheme.titleLarge,
  );
}
