import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/shell_geometry.dart';
import 'app_main_column.dart';
import 'app_pill_button.dart';

/// Share of the header row one of its buttons (Cancel, the action) may take.
const double _kHeaderButtonShare = 0.4;

/// The share each button may take when a secondary action is present, so the
/// three buttons together stay inside the row.
const double _kHeaderButtonShareOfThree = 0.28;

/// On the tablet layout the primary action may take up to this share of the
/// row, so a label such as "Schedule" stays whole at text scale 2.0 even in
/// a 439 dp pane (T8f). Cancel, the secondary button and the title share
/// what is left: the title yields first, then the quiet buttons. Phones and
/// desktop keep the shares above.
const double _kTabletActionShare = 0.7;

/// The header of a full-screen form (compose, Edit profile, Change handle):
/// Cancel, the [title] (announced as a header) and, with [actionLabel], the
/// screen's gradient primary action. Cancel is off while [busy]; a null
/// [onAction] shows the action disabled, and [busy] shows its spinner (the
/// caller owns both from its bloc state). Each button may take at most 40 %
/// of the row, so at large text on a small phone its label ellipsizes and the
/// title yields; nothing overflows. A divider closes the header.
///
/// On the tablet layout, in a reading column (T8f, one header rule), the row
/// spans the pane: Cancel at its leading edge, where a sibling page's
/// `AppBar` puts Back, and the action at its trailing edge. The action is
/// laid out first and is never ellipsized for the title's sake.
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
    // In a reading column on the tablet layout the row spans the pane (T8f,
    // one header rule): Cancel at the pane's leading edge, where a sibling
    // page's AppBar puts Back, and the action at its trailing edge.
    final tablet =
        AppMainColumnBleed.inColumn(context) &&
        ShellGeometry.readableTabletAt(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppFullBleed(
          interactive: true,
          child: Padding(
            padding: tablet
                ? const EdgeInsets.symmetric(
                    horizontal: AppSpacing.xs,
                    vertical: AppSpacing.sm,
                  )
                : const EdgeInsets.all(AppSpacing.sm),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final row = constraints.maxWidth;
                final share = secondaryLabel == null
                    ? _kHeaderButtonShare
                    : _kHeaderButtonShareOfThree;
                final actionShare = tablet ? _kTabletActionShare : share;
                // The action first; Cancel, the title and the secondary
                // button share the rest. On phones and desktop the rest is
                // always at least 60 % of the row, so the caps below are the
                // plain shares and the row is laid out as before.
                return Row(
                  children: [
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, rest) {
                          // Phones and desktop: as before. On the tablet layout
                          // the title always keeps a share of what is left
                          // (a title with no width loses its semantics node),
                          // so Cancel and the secondary button take at most
                          // an equal part each.
                          final parts = secondaryLabel == null ? 1 : 2;
                          final quiet = tablet
                              ? rest.maxWidth / (parts + 1)
                              : rest.maxWidth / parts;
                          final cap = BoxConstraints(
                            maxWidth: row * share < quiet ? row * share : quiet,
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
                                  label: title,
                                  excludeSemantics: true,
                                  child: Text(
                                    title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.center,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium,
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
                            ],
                          );
                        },
                      ),
                    ),
                    if (action != null)
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: row * actionShare,
                        ),
                        child: AppPillButton(
                          label: action,
                          singleLine: true,
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
        ),
        // Spans the pane on the tablet layout (the column's bleed).
        const AppFullBleed(child: Divider(height: 1)),
      ],
    );
  }
}
