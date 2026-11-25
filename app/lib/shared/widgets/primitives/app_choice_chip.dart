import 'package:material_ui/material_ui.dart';

import '../../../core/icons/dz_icon.dart';
import '../../../core/icons/dz_icons.dart';
import '../../../core/theme/app_theme.dart';
import 'app_chip.dart';

/// The Dz artboards' selectable chip (Plans audience, filters), next to
/// [AppChip] and [AppFilterPill]: 40 dp tall, radius 20, a 1.5 dp border,
/// label 15/600. Selected is the strong fill (navy; pearl on dark) with a
/// tick **and** a w700 label, unselected is white (raised on dark) with the
/// 3:1 border, so selection is never colour alone.
///
/// Announced as a selected button; the visual is 40 dp inside a 48 dp hit
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

  /// The visual height and radius (dp).
  static const double height = 40;
  static const double radius = 20;

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
            DzIcon(DzIcons.check, size: AppIconSize.sm, color: labelColor),
            const SizedBox(width: AppSpacing.xs),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.dzChip(theme).copyWith(
                color: labelColor,
                fontWeight: selected
                    ? AppTypeTokens.weightUi
                    : AppTypeTokens.weightLabel,
              ),
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
