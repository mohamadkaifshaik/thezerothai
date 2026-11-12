import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/lists/v1/lists.pb.dart' as pb;
import '../../../../shared/widgets/primitives/app_tile_icon.dart';

/// "1 member" / "N members" (plain digits, no compact form: a list holds at
/// most 150).
String listMemberCountLabel(int count) =>
    count == 1 ? '1 member' : '$count members';

/// How a [ListRow] is drawn.
enum ListRowStyle {
  /// The Add-to-Lists sheet's row: the default tile, a bold name with a muted
  /// "· N members" and a lock icon when private.
  sheet,

  /// The phone mocks' page row: a navy 52 dp tile, the bold name over a muted
  /// "Owner · N members" line, a 20 dp gutter.
  phone,

  /// The tablet and desktop mocks' page row (dz.css `.row`): a 16 dp gutter,
  /// a navy tile only for a pinned List, a lock before "Private", a chevron
  /// and a hairline under it.
  wide;

  bool get page => this != sheet;
}

/// "Owner · N members", or "Private · N members" for a private List (only the
/// owner ever receives one). The owner's name falls back to the @handle and
/// is left out when the answer carries none.
String listRowSubtitle(pb.ListInfo list) {
  final members = listMemberCountLabel(list.memberCount);
  final name = list.owner.displayName.trim();
  final owner = name.isNotEmpty
      ? name
      : (list.owner.handle.isEmpty ? '' : '@${list.owner.handle}');
  final who = list.isPrivate ? 'Private' : owner;
  return who.isEmpty ? members : '$who · $members';
}

/// One List as a row: "Your Lists", a person's Lists and Manage pinned's "Add
/// from your Lists" ([ListRowStyle.phone] / [ListRowStyle.wide], the page
/// looks of the mocks), and the Add-to-Lists sheet ([ListRowStyle.sheet]).
/// A custom row (no `ListTile`); the whole row is the tap target (>= 48dp).
/// [onEdit] adds a trailing Edit button for the owner and [trailing] a
/// widget of the page's own (the Pin button); with [checked] and
/// [checkTrailing] the row is a checkbox row of the sheet. [pinned] marks a
/// List that is a Home tab (the page styles only).
class ListRow extends StatelessWidget {
  const ListRow({
    super.key,
    required this.list,
    this.onTap,
    this.onEdit,
    this.trailing,
    this.checked,
    this.checkTrailing,
    this.enabled = true,
    this.style = ListRowStyle.sheet,
    this.pinned = false,
  });

  final pb.ListInfo list;
  final VoidCallback? onTap;
  final VoidCallback? onEdit;

  /// A widget after the row instead of the Edit button (the Pin button of
  /// Manage pinned). Ignored when [onEdit] is given.
  final Widget? trailing;

  /// Non-null makes the row a checkbox (spoken as checked or not) instead of a
  /// button; [checkTrailing] is the box (or a spinner) at the end of the row.
  final bool? checked;
  final Widget? checkTrailing;

  /// False while the row's action is in flight (spoken as disabled).
  final bool enabled;

  final ListRowStyle style;
  final bool pinned;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final members = listMemberCountLabel(list.memberCount);
    final spoken = [
      list.name,
      members,
      if (list.isPrivate) 'private',
    ].join(', ');
    final page = style.page;
    final wide = style == ListRowStyle.wide;
    final gutter = wide
        ? AppListsLayout.wideGutter
        : page
        ? AppListsLayout.phoneGutter
        : AppSpacing.md;
    final row = Row(
      children: [
        Expanded(
          child: Semantics(
            button: checked == null && onTap != null,
            checked: checked,
            enabled: enabled,
            label: spoken,
            excludeSemantics: true,
            onTap: onTap,
            child: InkWell(
              onTap: onTap,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: AppSpacing.minTapTarget,
                ),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: gutter,
                    vertical: !page
                        ? AppSpacing.smd
                        : wide
                        ? AppListsLayout.wideRowPaddingV
                        : AppListsLayout.phoneRowPaddingV,
                  ),
                  child: Row(
                    children: [
                      if (page)
                        ListTileIcon(navy: !wide || pinned, gradient: !wide)
                      else
                        const AppTileIcon(icon: Icons.list_alt_outlined),
                      SizedBox(
                        width: wide
                            ? AppListsLayout.wideRowGap
                            : page
                            ? AppListsLayout.phoneRowGap
                            : AppSpacing.smd,
                      ),
                      Expanded(
                        child: page
                            ? _PageLabel(list: list, lock: wide)
                            : _SheetLabel(list: list, members: members),
                      ),
                      if (!page && list.isPrivate) ...[
                        const SizedBox(width: AppSpacing.sm),
                        Icon(
                          Icons.lock_outline,
                          size: AppIconSize.md,
                          color: muted,
                        ),
                      ],
                      if (!wide && page && pinned) ...[
                        const SizedBox(width: AppSpacing.sm),
                        Icon(
                          Icons.push_pin,
                          size: AppIconSize.md,
                          color: context.appColors.accentText,
                        ),
                      ],
                      if (wide && trailing == null) ...[
                        const SizedBox(width: AppSpacing.sm),
                        Icon(Icons.chevron_right, color: muted),
                      ],
                      if (checkTrailing != null) ...[
                        const SizedBox(width: AppSpacing.sm),
                        checkTrailing!,
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (onEdit != null)
          IconButton(
            tooltip: 'Edit ${list.name}',
            icon: const Icon(Icons.edit_outlined),
            onPressed: onEdit,
          )
        else
          ?trailing,
      ],
    );
    return wide
        ? Column(
            mainAxisSize: MainAxisSize.min,
            children: [row, const Divider(height: 1)],
          )
        : row;
  }
}

/// The sheet's one line: a bold name with a muted "· N members".
class _SheetLabel extends StatelessWidget {
  const _SheetLabel({required this.list, required this.members});

  final pb.ListInfo list;
  final String members;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: list.name, style: theme.textTheme.titleMedium),
          TextSpan(
            text: ' · $members',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// A page row's name over its muted subtitle; [lock] draws the wide mocks'
/// lock before a private List's "Private".
class _PageLabel extends StatelessWidget {
  const _PageLabel({required this.list, required this.lock});

  final pb.ListInfo list;
  final bool lock;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          list.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleMedium,
        ),
        Row(
          children: [
            if (lock && list.isPrivate) ...[
              Icon(Icons.lock_outline, size: AppIconSize.sm, color: muted),
              const SizedBox(width: AppSpacing.xs),
            ],
            Flexible(
              child: Text(
                listRowSubtitle(list),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(color: muted),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// The 52 dp tile of a page row (the mocks' `.ico`): a rounded navy square
/// with an electric-teal glyph (the diagonal navy wash when [gradient], flat
/// navy otherwise), or a 12 % teal tint when not [navy]. Decorative.
class ListTileIcon extends StatelessWidget {
  const ListTileIcon({super.key, required this.navy, this.gradient = false});

  final bool navy;
  final bool gradient;

  @override
  Widget build(BuildContext context) {
    final glyph = navy ? AppPalette.tealElectric : context.appColors.accentText;
    return ExcludeSemantics(
      child: Container(
        width: AppListsLayout.tileSize,
        height: AppListsLayout.tileSize,
        decoration: BoxDecoration(
          color: navy
              ? (gradient ? null : AppPalette.navy)
              : glyph.withValues(alpha: AppTileIcon.tintAlpha),
          gradient: navy && gradient ? AppGradients.communityCover : null,
          borderRadius: BorderRadius.circular(AppListsLayout.tileRadius),
        ),
        child: Icon(
          Icons.list_alt_outlined,
          size: AppIconSize.lg,
          color: glyph,
        ),
      ),
    );
  }
}
