import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// The "ALT" chip on a posted image that has a description: a small pill in
/// a 48dp tap target. Tapping it opens [showAltTextSheet]. Place it
/// bottom-start of the image (`PositionedDirectional`). It is its own
/// semantics node ("Image description", a button), separate from the image
/// whose label stays the description.
class AltTextChip extends StatelessWidget {
  const AltTextChip({super.key, required this.text});

  /// The image's description (never empty: the caller shows no chip then).
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    void open() => showAltTextSheet(context, text: text);
    return Semantics(
      button: true,
      label: 'Image description',
      hint: 'Shows the description of the image',
      excludeSemantics: true,
      onTap: open,
      child: InkResponse(
        onTap: open,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minWidth: AppSpacing.minTapTarget,
            minHeight: AppSpacing.minTapTarget,
          ),
          child: Center(
            widthFactor: 1,
            heightFactor: 1,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surface.withValues(alpha: 0.8),
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm,
                  vertical: AppSpacing.xs,
                ),
                child: Text(
                  'ALT',
                  maxLines: 1,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: colors.onSurface,
                    fontWeight: FontWeight.w700,
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

/// The bottom sheet that shows an image's description ([text], selectable,
/// scrolls: a description can be 1,000 characters).
Future<void> showAltTextSheet(BuildContext context, {required String text}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => AltTextSheet(text: text),
  );
}

class AltTextSheet extends StatelessWidget {
  const AltTextSheet({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.6,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            0,
            AppSpacing.md,
            AppSpacing.md,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                header: true,
                child: Text(
                  'Image description',
                  style: theme.textTheme.titleLarge,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              SelectableText(
                text,
                style: theme.textTheme.bodyLarge?.copyWith(height: 1.35),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
