import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import 'app_gradient_button.dart';

/// Share of the header row one of its buttons (Cancel, the action) may take.
const double _kHeaderButtonShare = 0.4;

/// The header of a full-screen form (compose, Edit profile, Change handle):
/// Cancel, the [title] (announced as a header) and, with [actionLabel], the
/// screen's gradient primary action. Cancel is off while [busy]; a null
/// [onAction] shows the action disabled, and [busy] shows its spinner (the
/// caller owns both from its bloc state). Each button may take at most 40 %
/// of the row, so at large text on a small phone its label ellipsizes and the
/// title yields; nothing overflows. A divider closes the header.
class AppFormHeader extends StatelessWidget {
  const AppFormHeader({
    super.key,
    required this.title,
    required this.onCancel,
    this.actionLabel,
    this.onAction,
    this.busy = false,
    this.busySemanticsLabel,
    this.cancelLabel = 'Cancel',
  });

  final String title;
  final VoidCallback onCancel;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool busy;
  final String? busySemanticsLabel;
  final String cancelLabel;

  @override
  Widget build(BuildContext context) {
    final action = actionLabel;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.all(AppSpacing.sm),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final cap = BoxConstraints(
                maxWidth: constraints.maxWidth * _kHeaderButtonShare,
              );
              return Row(
                children: [
                  ConstrainedBox(
                    constraints: cap,
                    child: TextButton(
                      onPressed: busy ? null : onCancel,
                      child: Text(
                        cancelLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ),
                  if (action != null)
                    ConstrainedBox(
                      constraints: cap,
                      child: AppGradientButton(
                        label: action,
                        busy: busy,
                        busySemanticsLabel: busySemanticsLabel,
                        onPressed: onAction,
                      ),
                    ),
                ],
              );
            },
          ),
        ),
        const Divider(height: 1),
      ],
    );
  }
}
