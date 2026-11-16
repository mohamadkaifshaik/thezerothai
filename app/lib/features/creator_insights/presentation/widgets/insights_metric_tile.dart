import 'package:material_ui/material_ui.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/primitives/app_card.dart';
import 'insights_sparkline.dart';

/// "+12.5%", "-3%", "0%": one decimal under 10 percent, none above.
String formatChangePct(double pct) {
  final abs = pct.abs();
  final text = abs < 10 ? abs.toStringAsFixed(1) : abs.toStringAsFixed(0);
  final trimmed = text.endsWith('.0')
      ? text.substring(0, text.length - 2)
      : text;
  if (trimmed == '0') return '0%';
  return '${pct < 0 ? '-' : '+'}$trimmed%';
}

/// One metric: label, the window total, the change against the previous
/// window (hidden when [changePct] is null) and a sparkline of the daily
/// series. Read as one line by a screen reader. [wide] stacks the sparkline
/// under the figures (tablet and desktop); the phone puts it at the end.
class InsightsMetricTile extends StatelessWidget {
  const InsightsMetricTile({
    super.key,
    required this.label,
    required this.value,
    required this.series,
    required this.wide,
    this.changePct,
    this.caption,
  });

  final String label;
  final String value;
  final List<int> series;
  final bool wide;
  final double? changePct;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.appColors;
    final pct = changePct;
    final change = pct == null ? null : formatChangePct(pct);
    final changeColor = pct == null
        ? null
        : (pct < 0 ? theme.colorScheme.error : colors.accentText);
    final spark = InsightsSparkline(
      values: series,
      color: colors.accentText,
      width: wide ? double.infinity : 96,
    );
    final figures = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            style: theme.textTheme.headlineMedium?.copyWith(
              fontSize: wide
                  ? AppStudioLayout.statValueWide
                  : AppStudioLayout.statValuePhone,
              fontWeight: AppTypeTokens.weightDisplay,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ),
        if (change != null)
          Text(
            '$change vs previous',
            key: const ValueKey('insight-change'),
            style: theme.textTheme.labelLarge?.copyWith(color: changeColor),
          ),
        if (caption != null)
          Text(
            caption!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
    return Semantics(
      container: true,
      excludeSemantics: true,
      label: [
        '$label, $value',
        ?(change == null ? null : '$change against the previous period'),
        ?caption,
      ].join(', '),
      child: AppCard(
        padding: EdgeInsets.symmetric(
          horizontal: wide
              ? AppStudioLayout.statPaddingHWide
              : AppStudioLayout.statPaddingPhone,
          vertical: wide
              ? AppStudioLayout.statPaddingVWide
              : AppStudioLayout.statPaddingPhone,
        ),
        child: wide
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  figures,
                  const SizedBox(height: AppSpacing.md),
                  spark,
                ],
              )
            : Row(
                children: [
                  Expanded(child: figures),
                  const SizedBox(width: AppSpacing.md),
                  spark,
                ],
              ),
      ),
    );
  }
}
