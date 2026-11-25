import 'package:material_ui/material_ui.dart';

import '../../../core/theme/app_theme.dart';

/// The generic list row of the Dz artboards: a [leading] widget (a 40-52 dp
/// avatar or an `AppTileIcon.dz`), a [title] (16/700) with an optional
/// [subtitle] (14, muted) and a [trailing] slot (a button, a count, a
/// chevron), 12 dp of vertical and 16 dp of horizontal padding, and an
/// optional hairline under it.
///
/// With [onTap] the whole row is one button with a press state and at least
/// 48 dp tall; without it the row is plain content. [semanticsLabel] replaces
/// the spoken title and subtitle (a trailing control keeps its own
/// semantics). The title and subtitle ellipsize; at large text they grow the
/// row instead of overflowing.
class AppListRow extends StatelessWidget {
  const AppListRow({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.semanticsLabel,
    this.divider = false,
    this.compactTitle = false,
    this.titleMaxLines = 1,
    this.subtitleMaxLines = 2,
    this.padding = const EdgeInsetsDirectional.symmetric(
      horizontal: AppSpacing.md,
      vertical: AppSpacing.smd,
    ),
  });

  final String title;
  final String? subtitle;

  /// The avatar or icon tile at the start.
  final Widget? leading;

  /// A control or value at the end.
  final Widget? trailing;
  final VoidCallback? onTap;

  /// Spoken form of the row when it differs from the title and subtitle.
  final String? semanticsLabel;

  /// A 1 dp hairline under the row.
  final bool divider;

  /// 15/700 for the title instead of 16/700.
  final bool compactTitle;
  final int titleMaxLines;
  final int subtitleMaxLines;
  final EdgeInsetsGeometry padding;

  /// Gap between the leading widget, the text and the trailing slot.
  static const double gap = AppSpacing.smd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titleStyle = compactTitle
        ? AppTextStyles.dzRowTitleS(theme)
        : AppTextStyles.dzRowTitle(theme);
    final row = Padding(
      padding: padding,
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: gap)],
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: titleMaxLines,
                  overflow: TextOverflow.ellipsis,
                  style: titleStyle,
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    maxLines: subtitleMaxLines,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.dzSubtitle(theme),
                  ),
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: gap), trailing!],
        ],
      ),
    );
    Widget content = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: AppSpacing.minTapTarget),
      child: row,
    );
    if (onTap != null) {
      content = InkWell(onTap: onTap, child: content);
    }
    if (divider) {
      content = DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        child: content,
      );
    }
    if (semanticsLabel == null && onTap == null) return content;
    return Semantics(
      container: true,
      button: onTap != null,
      label: semanticsLabel,
      onTap: onTap,
      child: content,
    );
  }
}
