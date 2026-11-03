import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// Connect only adjacent posts with an actual parent/child relationship.
/// The rail sits in the avatar column, never across post text or controls.
class ConversationRow extends StatelessWidget {
  const ConversationRow({
    super.key,
    required this.child,
    this.connectBefore = false,
    this.connectAfter = false,
  });

  final Widget child;
  final bool connectBefore;
  final bool connectAfter;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      if (connectBefore)
        PositionedDirectional(
          start: AppSpacing.md + AppSpacing.minTapTarget / 2 - 1,
          top: 0,
          height: AppSpacing.sm,
          width: 2,
          child: ColoredBox(color: Theme.of(context).dividerColor),
        ),
      if (connectAfter)
        PositionedDirectional(
          start: AppSpacing.md + AppSpacing.minTapTarget / 2 - 1,
          top: AppSpacing.sm + AppSpacing.minTapTarget,
          bottom: 0,
          width: 2,
          child: ColoredBox(color: Theme.of(context).dividerColor),
        ),
      child,
    ],
  );
}
