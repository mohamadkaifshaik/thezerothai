import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import 'list_row.dart';

/// Whether the window is a phone (the dzeroth-mobile mocks); tablet and
/// desktop share the dz.css mocks. Only presentation reads this.
bool isListsPhone(BuildContext context) =>
    MediaQuery.sizeOf(context).width < AppBreakpoints.mobile;

/// The page row look for the window's width.
ListRowStyle listsPageRowStyle(BuildContext context) =>
    isListsPhone(context) ? ListRowStyle.phone : ListRowStyle.wide;

/// The title of a Lists page header (the mocks' title over a muted
/// subtitle): a one-line 800-weight title and, when there is one, the
/// subtitle (the @handle, the List's name).
class ListsHeaderTitle extends StatelessWidget {
  const ListsHeaderTitle({super.key, required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final phone = isListsPhone(context);
    final subtitle = this.subtitle;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleLarge?.copyWith(
            fontSize: phone
                ? AppListsLayout.phoneTitle
                : AppListsLayout.wideTitle,
            fontWeight: FontWeight.w800,
          ),
        ),
        if (subtitle != null && subtitle.isNotEmpty)
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: phone
                  ? AppListsLayout.phoneSubtitle
                  : AppListsLayout.wideSubtitle,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}

/// A section's title over its rows ("Pinned", "Your Lists", "Add from your
/// Lists"), with an optional text link at the end ("Manage"). Announced as a
/// header.
class ListsSectionHeader extends StatelessWidget {
  const ListsSectionHeader({
    super.key,
    required this.title,
    this.actionLabel,
    this.onAction,
    this.label = false,
  }) : assert((actionLabel == null) == (onAction == null));

  /// Draws the wide mocks' `.sect` (small, uppercase, muted) instead of the
  /// bold title; a phone keeps the bold title either way.
  final bool label;

  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final phone = isListsPhone(context);
    final gutter = phone
        ? AppListsLayout.phoneGutter
        : AppListsLayout.wideGutter;
    final sect = label && !phone;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        gutter,
        phone ? AppListsLayout.phoneSectionTop : AppListsLayout.wideSectionTop,
        gutter,
        sect ? AppListsLayout.sectLabelBottom : AppListsLayout.sectionBottom,
      ),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                sect ? title.toUpperCase() : title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: sect
                    ? AppTextStyles.eyebrow(theme)
                          .copyWith(color: theme.colorScheme.onSurfaceVariant)
                    : theme.textTheme.titleLarge?.copyWith(
                        fontSize: phone
                            ? AppListsLayout.phoneSectionTitle
                            : AppListsLayout.wideSectionTitle,
                        fontWeight: FontWeight.w800,
                      ),
              ),
            ),
          ),
          if (onAction != null)
            TextButton(onPressed: onAction, child: Text(actionLabel!)),
        ],
      ),
    );
  }
}

/// The page header's round action (the mocks' `.iconbtn.raised`): a surface
/// disc with a soft shadow, 44 dp so the tap target holds.
class ListsRaisedIconButton extends StatelessWidget {
  const ListsRaisedIconButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Theme.of(context).colorScheme.surface,
        boxShadow: AppShadows.searchRaised,
      ),
      child: IconButton(
        tooltip: tooltip,
        icon: Icon(icon),
        onPressed: onPressed,
      ),
    );
  }
}
