import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../domain/compose_audience.dart';

/// The audience pill of the composer (`composer.md` §2): "Everyone ▾"
/// or the community's name, in the accent colour with a 1dp accent outline.
/// A 48dp-high tap target around a 32dp pill; opens "Choose audience". Spoken
/// as one button: "Choose audience, <label>". A long community name ends in an
/// ellipsis; the pill never grows past its parent.
class AudiencePill extends StatelessWidget {
  const AudiencePill({super.key, required this.audience, required this.onTap});

  final ComposeAudience audience;

  /// Null while the post is being sent (shown disabled).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = onTap != null;
    final color = enabled
        ? context.appColors.accentText
        : theme.colorScheme.onSurfaceVariant;
    final radius = BorderRadius.circular(AppRadius.pill);
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: 'Choose audience, ${audience.label}',
        excludeSemantics: true,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppSpacing.minTapTarget),
          child: Center(
            widthFactor: 1,
            heightFactor: 1,
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                borderRadius: radius,
                onTap: onTap,
                child: Ink(
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    border: Border.all(color: color),
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: AppSize.pillCompact - AppSpacing.xs,
                    ),
                    child: Padding(
                      padding: const EdgeInsetsDirectional.only(
                        start: AppSpacing.smd,
                        end: AppSpacing.xs,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              audience.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelLarge?.copyWith(
                                color: color,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          Icon(
                            Icons.arrow_drop_down,
                            size: AppIconSize.lg,
                            color: color,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
