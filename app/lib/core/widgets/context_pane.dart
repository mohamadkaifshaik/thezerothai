import 'package:flutter/material.dart';

import '../../shared/widgets/primitives/app_surface.dart';
import '../theme/app_theme.dart';

/// One titled card of the desktop side column (and the pages' inline
/// sections): an outlined `AppSurface` with a
/// bold [title] (a heading) over [child], as the "What's happening" card.
/// The card owns its bottom gap ([margin]).
class ContextPaneCard extends StatelessWidget {
  const ContextPaneCard({
    super.key,
    required this.title,
    required this.child,
    this.margin = const EdgeInsets.only(bottom: AppSpacing.md),
    this.titleTrailing,
    this.titleSemanticsLabel,
  });

  final String title;
  final Widget child;
  final EdgeInsetsGeometry margin;

  /// Drawn after the title on its line (a count badge); nothing when null.
  final Widget? titleTrailing;

  /// What the heading says instead of [title] (the title with its count).
  final String? titleSemanticsLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppSurface(
      margin: margin,
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.md,
              AppSpacing.md,
              AppSpacing.xs,
            ),
            child: Semantics(
              header: true,
              label: titleSemanticsLabel,
              excludeSemantics: titleSemanticsLabel != null,
              child: _titleRow(theme),
            ),
          ),
          child,
        ],
      ),
    );
  }

  Widget _titleRow(ThemeData theme) {
    final text = Text(
      title,
      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
    );
    final trailing = titleTrailing;
    if (trailing == null) return text;
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [text, trailing],
    );
  }
}
