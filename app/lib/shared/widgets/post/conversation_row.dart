import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import 'post_card.dart';

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
  Widget build(BuildContext context) {
    // The middle of the card's avatar column, from its gutter.
    final rail = postCardGutterOf(context) + AppSpacing.minTapTarget / 2 - 1;
    return Stack(
      children: [
        if (connectBefore)
          PositionedDirectional(
            start: rail,
            top: 0,
            height: kPostListTop,
            width: 2,
            child: ColoredBox(color: Theme.of(context).dividerColor),
          ),
        if (connectAfter)
          PositionedDirectional(
            start: rail,
            top: kPostListTop + AppSpacing.minTapTarget,
            bottom: 0,
            width: 2,
            child: ColoredBox(color: Theme.of(context).dividerColor),
          ),
        child,
      ],
    );
  }
}
