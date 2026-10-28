import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import 'app_section_header.dart';
import 'app_status_pill.dart';
import 'app_surface.dart';

/// One Settings section: a [title] header above a card whose [rows] are
/// separated by hairlines. Shared by the Settings screen and the shell pages
/// (Creator tools, Calls...).
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, required this.title, required this.rows})
    : assert(rows.length > 0, 'an empty group must not be built');

  final String title;
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppSectionHeader(title: title),
          AppSurface(
            padding: EdgeInsets.zero,
            margin: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            // Clips the row ripples to the card's rounded corners.
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.lg),
              child: Column(
                children: [
                  for (var i = 0; i < rows.length; i++) ...[
                    if (i > 0) const Divider(height: 1),
                    rows[i],
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One row of a [SettingsGroup]: a leading icon in a small rounded tile, a
/// [title] (and optional [subtitle]) and a [trailing] widget (a chevron by
/// default). With no [onTap] the row is static text (the Email row), not a
/// button. A [destructive] row uses the error color.
///
/// A static row may show a [value] (a count, an [AppStatusPill]) at its end.
/// From text scale [stackValueScale] up, or in a row narrower than
/// [stackValueWidth], the value moves under the title/subtitle; a value too
/// wide for the line scales down rather than clipping. Spoken, a static row
/// with a value is one non-button node: `title, value text` (then the
/// subtitle on its own line). The value text is [valueLabel], or derived from
/// a [Text] / [AppStatusPill] value; any other widget must pass [valueLabel].
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    this.trailing,
    this.showChevron = true,
    this.destructive = false,
    this.selected = false,
    this.toggled,
    this.value,
    this.valueLabel,
  }) : assert(
         value == null || onTap == null,
         'a value is for static rows; a tappable row uses trailing',
       );

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;

  /// Replaces the default chevron (shown only when [onTap] is set).
  final Widget? trailing;

  /// Whether the default chevron is shown when there is no [trailing]; false
  /// for an action that does not open another page (Sign out).
  final bool showChevron;
  final bool destructive;

  /// The row whose page is open in the detail pane (master-detail layout).
  final bool selected;

  /// Makes the row a switch (W3-33b): non-null shows a [Switch] in place of
  /// the chevron and announces on / off. [onTap] flips it (null = disabled,
  /// e.g. while saving).
  final bool? toggled;

  /// Shown at the end of a static row (no [onTap]); ignored otherwise.
  final Widget? value;

  /// The spoken text of [value]. Derived when [value] is a [Text] or an
  /// [AppStatusPill].
  final String? valueLabel;

  /// Text scale from which [value] is stacked under the title.
  static const double stackValueScale = 1.3;

  /// Row content width (dp) under which [value] is stacked under the title.
  static const double stackValueWidth = 200;

  String? get _valueText {
    if (value == null || onTap != null) return null;
    if (valueLabel != null) return valueLabel;
    final v = value;
    if (v is Text) return v.data ?? v.textSpan?.toPlainText();
    if (v is AppStatusPill) return v.label;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final tint = destructive ? colors.error : colors.onSurface;
    final staticValue = onTap == null ? value : null;
    final stack =
        staticValue != null &&
        MediaQuery.textScalerOf(context).scale(1) >= stackValueScale;
    Widget textColumn(Widget? below) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.bodyLarge?.copyWith(color: tint)),
        if (subtitle != null)
          Text(
            subtitle!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        if (below != null)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs),
            child: below,
          ),
      ],
    );
    final content = ConstrainedBox(
      constraints: const BoxConstraints(
        minHeight: AppSpacing.xxl + AppSpacing.sm,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        child: LayoutBuilder(
          builder: (context, box) {
            final narrow = box.maxWidth < stackValueWidth;
            final below = staticValue != null && (stack || narrow);
            return Row(
              children: [
                Container(
                  width: AppSpacing.xl + AppSpacing.sm,
                  height: AppSpacing.xl + AppSpacing.sm,
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: Icon(icon, size: AppIconSize.md, color: tint),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: textColumn(
                    below
                        ? Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: staticValue,
                          )
                        : null,
                  ),
                ),
                if (staticValue != null && !below) ...[
                  const SizedBox(width: AppSpacing.sm),
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: AlignmentDirectional.centerEnd,
                      child: staticValue,
                    ),
                  ),
                ] else if (toggled != null) ...[
                  const SizedBox(width: AppSpacing.sm),
                  Switch(
                    value: toggled!,
                    onChanged: onTap == null ? null : (_) => onTap!(),
                  ),
                ] else if (onTap != null &&
                    (trailing != null || showChevron)) ...[
                  const SizedBox(width: AppSpacing.sm),
                  trailing ??
                      Icon(
                        Icons.chevron_right,
                        size: AppIconSize.lg,
                        color: colors.onSurfaceVariant,
                      ),
                ],
              ],
            );
          },
        ),
      ),
    );

    final spoken = _valueText == null ? title : '$title, $_valueText';
    final label = subtitle == null ? spoken : '$spoken\n$subtitle';
    // `container` keeps each row its own node: without it a static row would
    // merge into the group header's node above it.
    if (onTap == null) {
      return Semantics(
        container: true,
        toggled: toggled,
        label: label,
        excludeSemantics: true,
        child: content,
      );
    }
    // One node per row: the label once, as a button.
    return Semantics(
      container: true,
      button: toggled == null,
      toggled: toggled,
      selected: selected ? true : null,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: Material(
        color: selected ? context.appColors.selectedRow : Colors.transparent,
        child: InkWell(onTap: onTap, child: content),
      ),
    );
  }
}
