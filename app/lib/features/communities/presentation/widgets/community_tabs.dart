import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/primitives/app_tab_bar.dart';

/// Up to this text scale the communities pages' tab bars may share the
/// width equally (the designs); above it each tab keeps its label's width
/// and the bar scrolls (R10 review item 3).
const kCommunityTabsShareWidthUpTo = 1.3;

/// Whether a tab bar of [labels], [width] wide, shares the width equally:
/// only up to [kCommunityTabsShareWidthUpTo], and only when every label (at
/// the selected weight and the ambient text scale) fits its share with a
/// little room each side. Otherwise the labels would be ellipsized.
bool communityTabsShareWidth(
  BuildContext context, {
  required List<String> labels,
  required double width,
}) {
  final scaler = MediaQuery.textScalerOf(context);
  if (scaler.scale(1) > kCommunityTabsShareWidthUpTo) return false;
  if (!width.isFinite || labels.isEmpty) return true;
  final style = Theme.of(context).textTheme.titleSmall
      ?.copyWith(fontWeight: FontWeight.w700);
  final share = width / labels.length - 2 * AppSpacing.sm;
  for (final label in labels) {
    final painter = TextPainter(
      text: TextSpan(text: label, style: style),
      textScaler: scaler,
      maxLines: 1,
      textDirection: Directionality.of(context),
    )..layout();
    final fits = painter.width <= share;
    painter.dispose();
    if (!fits) return false;
  }
  return true;
}

/// The communities pages' tab bar (Communities, CommunityMembers): the
/// shared [AppTabBar], equal-width when [communityTabsShareWidth] allows,
/// otherwise content-sized and scrolling, so no label is ellipsized.
class CommunityTabBar extends StatelessWidget {
  const CommunityTabBar({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.onChanged,
    required this.semanticLabel,
  });

  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onChanged;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => AppTabBar(
      tabs: [for (final l in labels) AppTab(label: l)],
      selectedIndex: selectedIndex,
      equalWidth: communityTabsShareWidth(
        context,
        labels: labels,
        width: constraints.maxWidth,
      ),
      semanticLabel: semanticLabel,
      onChanged: onChanged,
    ),
  );
}
