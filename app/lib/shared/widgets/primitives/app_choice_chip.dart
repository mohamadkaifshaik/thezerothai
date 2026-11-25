import 'package:material_ui/material_ui.dart';

import '../../../core/icons/dz_icon.dart';
import '../../../core/icons/dz_icons.dart';
import '../../../core/theme/app_theme.dart';
import 'app_chip.dart';

/// The Dz artboards' selectable chip (Plans audience, filters), next to
/// [AppChip] and [AppFilterPill]: `height: 40px` plus a 1.5 dp border (43 dp
/// drawn, see [height]), radius 20, 16 dp side padding, label 15/600 in both
/// states. Selected is the strong fill (navy; pearl on dark) with a 16 dp
/// tick (stroke 2.6) 6 dp before the label, unselected is white (raised on
/// dark) with the 3:1 border, so selection is never colour alone.
///
/// Announced as a selected button; the visual is 43 dp inside a 48 dp hit
/// area. The fill changes over 160 ms (none under reduce-motion). A null
/// [onPressed] disables it.
class AppChoiceChip extends StatelessWidget {
  const AppChoiceChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
    this.semanticsLabel,
  });

  final String label;
  final bool selected;
  final VoidCallback? onPressed;

  /// Spoken label when it differs from [label].
  final String? semanticsLabel;

  /// The drawn height (dp), as the canvas renders it. The artboards have no
  /// shared `box-sizing` rule (no `* {}` reset in any `.dc.html` or in
  /// canvas.json; `border-box` is set inline only on some inputs, toggles
  /// and badges, never on a chip), so the chip is CSS `content-box`:
  /// `height: 40px` + 2 x 1.5 border = 43.
  static const double height = 40 + 2 * AppSize.componentBorder;
  static const double radius = 20;

  /// The tick: 16 dp at the artboard's 2.6 stroke, 6 dp before the label.
  static const double tickSize = 16;
  static const double tickStroke = 2.6;
  static const double tickGap = 6;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.appColors;
    final reduce = MediaQuery.disableAnimationsOf(context);
    final enabled = onPressed != null;
    final fill = selected
        ? colors.strongPillFill
        : AppFilterPill.unselectedFill(theme);
    final labelColor = selected
        ? colors.strongPillLabel
        : theme.colorScheme.onSurface;
    final border = selected ? colors.strongPillFill : colors.uiBorder;
    final visual = AnimatedContainer(
      duration: reduce ? Duration.zero : const Duration(milliseconds: 160),
      constraints: const BoxConstraints(minHeight: height),
      // The border is added to this padding (Container adds the
      // decoration's padding), as content-box CSS does.
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: border, width: AppSize.componentBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (selected) ...[
            DzIcon(
              DzIcons.check,
              size: tickSize,
              strokeWidth: tickStroke,
              color: labelColor,
            ),
            const SizedBox(width: tickGap),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              // 15/600 selected or not (DzPlans); the tick and the fill
              // mark the selection.
              style: AppTextStyles.dzChip(theme).copyWith(color: labelColor),
            ),
          ),
        ],
      ),
    );
    return Semantics(
      container: true,
      button: true,
      selected: selected,
      enabled: enabled,
      onTap: onPressed,
      label: semanticsLabel ?? label,
      child: ExcludeSemantics(
        child: Opacity(
          opacity: enabled ? 1 : 0.5,
          child: InkWell(
            onTap: onPressed,
            customBorder: const StadiumBorder(),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: AppSpacing.minTapTarget,
                minWidth: AppSpacing.minTapTarget,
              ),
              child: Center(widthFactor: 1, child: visual),
            ),
          ),
        ),
      ),
    );
  }
}
