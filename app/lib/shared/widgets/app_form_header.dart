import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import 'app_pill_button.dart';

/// Share of the header row one of its buttons (Cancel, the action) may take.
const double _kHeaderButtonShare = 0.4;

/// The share each button may take when a secondary action is present, so the
/// three buttons together stay inside the row.
const double _kHeaderButtonShareOfThree = 0.28;

/// The header of a full-screen form (compose, Edit profile, Change handle):
/// Cancel, the [title] (announced as a header) and, with [actionLabel], the
/// screen's gradient primary action. Cancel is off while [busy]; a null
/// [onAction] shows the action disabled, and [busy] shows its spinner (the
/// caller owns both from its bloc state). Each button may take at most 40 %
/// of the row, so at large text on a small phone its label ellipsizes and the
/// title yields; nothing overflows. A divider closes the header.
///
/// [secondaryLabel] adds a quiet text button before the primary action (the
/// composer's "Drafts"); with it each button may take 28 % of the row.
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
    this.secondaryLabel,
    this.onSecondary,
  });

  final String title;
  final VoidCallback onCancel;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool busy;
  final String? busySemanticsLabel;
  final String cancelLabel;

  /// An optional text button between the title and the action.
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

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
                maxWidth:
                    constraints.maxWidth *
                    (secondaryLabel == null
                        ? _kHeaderButtonShare
                        : _kHeaderButtonShareOfThree),
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
                  if (secondaryLabel != null)
                    ConstrainedBox(
                      constraints: cap,
                      child: TextButton(
                        onPressed: busy ? null : onSecondary,
                        child: Text(
                          secondaryLabel!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  if (action != null)
                    ConstrainedBox(
                      constraints: cap,
                      child: AppPillButton(
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
