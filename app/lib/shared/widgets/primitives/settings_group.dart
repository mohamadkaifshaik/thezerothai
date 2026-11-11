import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import 'app_section_header.dart';
import 'app_skeleton.dart';
import 'app_status_pill.dart';
import 'app_surface.dart';
import 'app_tile_icon.dart';

/// How a [SettingsGroup] is drawn.
enum SettingsGroupStyle {
  /// A title header over a bordered card (the shell pages).
  plain,

  /// The phone Settings mock: an uppercase label over a raised card (the
  /// card gradient and shadow), no hairlines between rows. The caller gives
  /// the page's side padding.
  raised,

  /// The tablet / desktop Settings mocks: an uppercase label over a flat
  /// bordered box, hairlines between rows.
  flat,
}

/// One Settings section: a [title] header above a card whose [rows] are
/// separated by hairlines. Shared by the Settings screen and the shell pages
/// (Creator Studio, Calls...). With no [title] the card stands alone (a
/// Settings category page, whose bar already names it).
///
/// [style] picks the Settings mocks' looks; the [SettingsRow]s inside follow
/// it (through [SettingsGroupScope]), rows built by other widgets included.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({
    super.key,
    this.title,
    required this.rows,
    this.style = SettingsGroupStyle.plain,
  }) : assert(rows.length > 0, 'an empty group must not be built');

  final String? title;
  final List<Widget> rows;
  final SettingsGroupStyle style;

  @override
  Widget build(BuildContext context) {
    return switch (style) {
      SettingsGroupStyle.plain => _plain(context),
      SettingsGroupStyle.raised => _raised(context),
      SettingsGroupStyle.flat => _flat(context),
    };
  }

  /// The uppercase label: shown in capitals, spoken as written.
  Widget _label(BuildContext context, String title) => Semantics(
    header: true,
    label: title,
    excludeSemantics: true,
    child: Text(
      title.toUpperCase(),
      style: AppTextStyles.eyebrow(Theme.of(context)),
    ),
  );

  Widget _raised(BuildContext context) {
    final title = this.title;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSettingsLayout.groupGap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null) ...[
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSettingsLayout.labelInset,
              ),
              child: _label(context, title),
            ),
            const SizedBox(height: AppSettingsLayout.labelGap),
          ],
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.card),
              gradient: dark ? AppGradients.darkCard : AppGradients.card,
              boxShadow: dark ? null : AppShadows.card,
            ),
            child: Padding(
              padding: const EdgeInsets.all(AppSettingsLayout.raisedPadding),
              // Clips the row ripples to the card's inner corners.
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.cardSmall),
                child: SettingsGroupScope(
                  style: style,
                  child: Column(children: rows),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _flat(BuildContext context) {
    final title = this.title;
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSettingsLayout.flatLabelTop,
              AppSpacing.md,
              AppSettingsLayout.flatLabelBottom,
            ),
            child: _label(context, title),
          )
        else
          const SizedBox(height: AppSpacing.md),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          decoration: BoxDecoration(
            color: colors.surfaceContainer,
            border: Border.all(color: colors.outlineVariant),
            borderRadius: BorderRadius.circular(AppRadius.cardSmall),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.cardSmall - 1),
            child: SettingsGroupScope(
              style: style,
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
        ),
      ],
    );
  }

  Widget _plain(BuildContext context) {
    final title = this.title;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null) AppSectionHeader(title: title),
          AppSurface(
            padding: EdgeInsets.zero,
            margin: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            // Clips the row ripples to the card's rounded corners.
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.cardSmall),
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

/// The [SettingsGroupStyle] of the enclosing [SettingsGroup], for the rows
/// inside it (a [SettingsRow], or a custom row such as a choice row).
class SettingsGroupScope extends InheritedWidget {
  const SettingsGroupScope({
    super.key,
    required this.style,
    required super.child,
  });

  final SettingsGroupStyle style;

  /// The style of the enclosing group; [SettingsGroupStyle.plain] outside a
  /// raised or flat one.
  static SettingsGroupStyle of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SettingsGroupScope>()?.style ??
      SettingsGroupStyle.plain;

  @override
  bool updateShouldNotify(SettingsGroupScope oldWidget) =>
      style != oldWidget.style;
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
    this.subtitleMaxLines = 2,
    this.busy = false,
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

  /// Makes the row a switch: non-null shows a [Switch] in place of
  /// the chevron and announces on / off. [onTap] flips it (null = disabled,
  /// e.g. while saving; announced as disabled).
  final bool? toggled;

  /// Lines of [subtitle] before it ellipsizes; null shows it whole (a key
  /// explanation at large text, R4). Two by default.
  final int? subtitleMaxLines;

  /// A switch row whose change is being saved: an 18 dp progress indicator
  /// takes the switch's place, announced as "Saving" (and disabled).
  final bool busy;

  /// The progress indicator's size while [busy].
  static const double busySize = 18;

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
    // The Settings mocks: bold 15 sp titles; the phone's taller, inset rows.
    final style = SettingsGroupScope.of(context);
    final mock = style != SettingsGroupStyle.plain;
    final raised = style == SettingsGroupStyle.raised;
    final staticValue = onTap == null ? value : null;
    final stack =
        staticValue != null &&
        MediaQuery.textScalerOf(context).scale(1) >= stackValueScale;
    Widget textColumn(Widget? below) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: tint,
            fontSize: mock ? AppSettingsLayout.titleSize : null,
            fontWeight: mock ? AppTypeTokens.weightUi : null,
          ),
        ),
        if (subtitle != null)
          Text(
            subtitle!,
            maxLines: subtitleMaxLines,
            overflow: subtitleMaxLines == null ? null : TextOverflow.ellipsis,
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
      constraints: BoxConstraints(
        minHeight: raised
            ? AppSettingsLayout.raisedRowMinHeight
            : AppSpacing.xxl + AppSpacing.sm,
      ),
      child: Padding(
        padding: switch (style) {
          SettingsGroupStyle.raised => const EdgeInsets.symmetric(
            horizontal: AppSettingsLayout.raisedRowPaddingH,
            vertical: AppSettingsLayout.raisedRowPaddingV,
          ),
          SettingsGroupStyle.flat => const EdgeInsets.symmetric(
            horizontal: AppSettingsLayout.flatRowPaddingH,
            vertical: AppSettingsLayout.flatRowPaddingV,
          ),
          SettingsGroupStyle.plain => const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
        },
        child: LayoutBuilder(
          builder: (context, box) {
            final narrow = box.maxWidth < stackValueWidth;
            final below = staticValue != null && (stack || narrow);
            return Row(
              children: [
                AppTileIcon(
                  icon: icon,
                  size: AppSpacing.xl + AppSpacing.sm,
                  destructive: destructive,
                ),
                SizedBox(
                  width: switch (style) {
                    SettingsGroupStyle.raised => AppSettingsLayout.raisedRowGap,
                    SettingsGroupStyle.flat => AppSettingsLayout.flatRowGap,
                    SettingsGroupStyle.plain => AppSpacing.md,
                  },
                ),
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
                ] else if (toggled != null && busy) ...[
                  const SizedBox(width: AppSpacing.sm),
                  const SizedBox(
                    width: busySize,
                    height: busySize,
                    child: CircularProgressIndicator(strokeWidth: 2),
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
        // A switch with no tap is disabled (saving), and says so.
        enabled: toggled == null ? null : false,
        value: busy ? 'Saving' : null,
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

/// A [SettingsGroup] while its values load: the optional [title] header and
/// [rows] rows of the same height, so nothing jumps when the rows arrive.
/// Announced once as [semanticsLabel] (the Notification and Message settings
/// pages, R4).
class SettingsGroupPlaceholder extends StatelessWidget {
  const SettingsGroupPlaceholder({
    super.key,
    this.title,
    required this.rows,
    required this.semanticsLabel,
  });

  final String? title;
  final int rows;
  final String semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final title = this.title;
    return AppSkeletonScope(
      semanticsLabel: semanticsLabel,
      child: Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title != null) AppSectionHeader(title: title),
            AppSurface(
              padding: EdgeInsets.zero,
              margin: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              child: Column(
                children: [
                  for (var i = 0; i < rows; i++) ...[
                    if (i > 0) const Divider(height: 1),
                    const SizedBox(
                      height: AppSpacing.xxl + AppSpacing.sm,
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: AppSpacing.md,
                        ),
                        child: Row(
                          children: [
                            AppSkeletonBlock(
                              width: AppSpacing.xl + AppSpacing.sm,
                              height: AppSpacing.xl + AppSpacing.sm,
                              radius: AppRadius.md,
                            ),
                            SizedBox(width: AppSpacing.md),
                            Expanded(
                              child: FractionallySizedBox(
                                alignment: AlignmentDirectional.centerStart,
                                widthFactor: 0.6,
                                child: AppSkeletonBlock(height: AppSpacing.md),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
