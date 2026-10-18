import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/theme/app_theme.dart';
import '../../domain/media_feature_flag.dart';
import '../bloc/attachments_cubit.dart';

/// The composer's picked images: a single row of removable preview tiles
/// (at most [kMaxPostImages]) with per-image state (processing, upload
/// progress, failed, rejected) and an "Add description" (alt text) action.
///
/// Display + intents only: every action dispatches to the
/// [AttachmentsCubit] above it. Hidden when nothing is attached.
class AttachmentGrid extends StatelessWidget {
  const AttachmentGrid({super.key, this.enabled = true});

  /// False while the post is being sent (no remove / describe).
  final bool enabled;

  /// Tile edge: 2 x 48dp targets plus a gutter, so the remove and alt text
  /// buttons keep full-size targets inside the tile.
  static const double tileSize = AppSpacing.xxl * 2 + AppSpacing.md;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AttachmentsCubit, AttachmentsState>(
      buildWhen: (a, b) => !identical(a.items, b.items),
      builder: (context, state) {
        if (state.isEmpty) return const SizedBox.shrink();
        return SizedBox(
          height: tileSize,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            itemCount: state.items.length,
            separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.sm),
            itemBuilder: (context, index) {
              final item = state.items[index];
              return AttachmentTile(
                key: ValueKey(item.id),
                attachment: item,
                position: index + 1,
                total: state.items.length,
                enabled: enabled,
              );
            },
          ),
        );
      },
    );
  }
}

/// One preview tile; see [AttachmentGrid].
class AttachmentTile extends StatelessWidget {
  const AttachmentTile({
    super.key,
    required this.attachment,
    required this.position,
    required this.total,
    required this.enabled,
  });

  final Attachment attachment;
  final int position;
  final int total;
  final bool enabled;

  String get _label {
    final base = 'Photo $position of $total';
    return switch (attachment.status) {
      AttachmentStatus.processing => '$base, preparing',
      AttachmentStatus.uploading => '$base, uploading',
      AttachmentStatus.uploaded => '$base, uploaded',
      AttachmentStatus.failed =>
        "$base, upload failed. It retries when you "
            'tap Post.',
      AttachmentStatus.rejected => '$base, was not accepted. Remove it.',
      AttachmentStatus.unsupported => "$base, can't be used. Remove it.",
      AttachmentStatus.ready => base,
    };
  }

  Future<void> _describe(BuildContext context) async {
    final cubit = context.read<AttachmentsCubit>();
    final text = await showDialog<String>(
      context: context,
      builder: (_) => _AltTextDialog(initial: attachment.altText),
    );
    if (text != null) cubit.setAltText(attachment.id, text);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final preview = attachment.previewBytes;
    final problem =
        attachment.status == AttachmentStatus.failed ||
        attachment.status == AttachmentStatus.rejected ||
        attachment.status == AttachmentStatus.unsupported;
    final busy =
        attachment.status == AttachmentStatus.processing ||
        attachment.status == AttachmentStatus.uploading;

    return Semantics(
      container: true,
      label: _label,
      child: SizedBox(
        width: AttachmentGrid.tileSize,
        height: AttachmentGrid.tileSize,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surfaceContainerHigh,
              border: Border.all(
                color: problem ? colors.error : colors.outlineVariant,
              ),
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (preview != null)
                  ExcludeSemantics(
                    child: Image.memory(
                      preview,
                      fit: BoxFit.cover,
                      cacheWidth:
                          (AttachmentGrid.tileSize *
                                  MediaQuery.devicePixelRatioOf(context))
                              .ceil(),
                      gaplessPlayback: true,
                      errorBuilder: (_, _, _) => Icon(
                        Icons.broken_image_outlined,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                if (busy || problem)
                  ColoredBox(
                    color: colors.surface.withValues(alpha: 0.7),
                    // The tile's own label already states the status.
                    child: ExcludeSemantics(
                      child: Center(
                        child: _Status(attachment: attachment, colors: colors),
                      ),
                    ),
                  ),
                PositionedDirectional(
                  top: 0,
                  end: 0,
                  child: IconButton(
                    tooltip: 'Remove photo $position',
                    icon: const Icon(Icons.close, size: AppIconSize.md),
                    style: IconButton.styleFrom(
                      backgroundColor: colors.surface.withValues(alpha: 0.7),
                      minimumSize: const Size.square(AppSpacing.minTapTarget),
                    ),
                    onPressed: enabled && !_uploading
                        ? () => context.read<AttachmentsCubit>().remove(
                            attachment.id,
                          )
                        : null,
                  ),
                ),
                if (attachment.image != null)
                  PositionedDirectional(
                    bottom: 0,
                    start: 0,
                    child: TextButton(
                      onPressed: enabled && !_uploading
                          ? () => _describe(context)
                          : null,
                      style: TextButton.styleFrom(
                        minimumSize: const Size(
                          AppSpacing.minTapTarget,
                          AppSpacing.minTapTarget,
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.sm,
                        ),
                        backgroundColor: colors.surface.withValues(alpha: 0.7),
                      ),
                      child: Text(
                        attachment.altText.isEmpty ? '+ ALT' : 'ALT',
                        semanticsLabel: attachment.altText.isEmpty
                            ? 'Add description for photo $position'
                            : 'Edit description for photo $position',
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  bool get _uploading => attachment.status == AttachmentStatus.uploading;
}

class _Status extends StatelessWidget {
  const _Status({required this.attachment, required this.colors});

  final Attachment attachment;
  final ColorScheme colors;

  @override
  Widget build(BuildContext context) {
    switch (attachment.status) {
      case AttachmentStatus.processing:
        return const SizedBox.square(
          dimension: AppIconSize.lg,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
      case AttachmentStatus.uploading:
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: LinearProgressIndicator(
            value: attachment.progress <= 0 ? null : attachment.progress,
            semanticsLabel: 'Uploading',
          ),
        );
      case AttachmentStatus.failed:
        return _problem(context, Icons.refresh, 'Not sent');
      case AttachmentStatus.rejected:
        return _problem(context, Icons.block_outlined, 'Not accepted');
      case AttachmentStatus.unsupported:
        return _problem(context, Icons.broken_image_outlined, "Can't use this");
      case AttachmentStatus.ready || AttachmentStatus.uploaded:
        return const SizedBox.shrink();
    }
  }

  Widget _problem(BuildContext context, IconData icon, String text) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: AppIconSize.lg, color: colors.error),
        const SizedBox(height: AppSpacing.xs),
        Text(
          text,
          style: Theme.of(context).textTheme.labelSmall,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _AltTextDialog extends StatefulWidget {
  const _AltTextDialog({required this.initial});

  final String initial;

  @override
  State<_AltTextDialog> createState() => _AltTextDialogState();
}

class _AltTextDialogState extends State<_AltTextDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Describe this photo'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        minLines: 2,
        maxLines: 5,
        maxLength: kMaxAltTextLength,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(
          hintText: 'For people who cannot see the photo',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
