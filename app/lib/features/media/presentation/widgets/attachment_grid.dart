import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/gif_badge.dart';
import '../bloc/attachments_cubit.dart';
import 'alt_text_editor.dart';

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
class AttachmentTile extends StatefulWidget {
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

  @override
  State<AttachmentTile> createState() => _AttachmentTileState();
}

class _AttachmentTileState extends State<AttachmentTile> {
  /// On the "+ ALT" / "ALT" button, so focus returns to it when the editor
  /// closes (a touch tap does not focus a button, and the route would
  /// otherwise restore nothing).
  final FocusNode _altFocus = FocusNode(debugLabel: 'attachment alt text');

  Attachment get attachment => widget.attachment;
  int get position => widget.position;
  int get total => widget.total;
  bool get enabled => widget.enabled;

  @override
  void dispose() {
    _altFocus.dispose();
    super.dispose();
  }

  String get _label {
    final base = attachment.isGif ? 'GIF' : 'Photo $position of $total';
    if (attachment.status == AttachmentStatus.rejected &&
        attachment.rejectionReason.isNotEmpty) {
      final reason = attachment.rejectionReason.replaceAll(RegExp(r'\.$'), '');
      return '$base, was not accepted. $reason. Remove it.';
    }
    return switch (attachment.status) {
      AttachmentStatus.processing => '$base, preparing',
      AttachmentStatus.uploading => '$base, uploading',
      AttachmentStatus.uploaded => '$base, uploaded',
      AttachmentStatus.failed =>
        "$base, upload failed. It retries when you "
            'tap Post.',
      AttachmentStatus.unchecked =>
        "$base, couldn't be checked. Use Retry on this tile.",
      AttachmentStatus.rejected => '$base, was not accepted. Remove it.',
      AttachmentStatus.unsupported => "$base, can't be used. Remove it.",
      AttachmentStatus.ready => base,
    };
  }

  Future<void> _describe(BuildContext context) async {
    final cubit = context.read<AttachmentsCubit>();
    final id = attachment.id;
    final text = await showAltTextEditor(
      context,
      initial: attachment.altText,
      preview: attachment.previewBytes,
    );
    if (text != null && !cubit.isClosed) cubit.setAltText(id, text);
    if (mounted) _altFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final preview = attachment.previewBytes;
    final problem =
        attachment.status == AttachmentStatus.failed ||
        attachment.status == AttachmentStatus.unchecked ||
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
                    tooltip: attachment.isGif
                        ? 'Remove GIF'
                        : 'Remove photo $position',
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
                if (attachment.isGif)
                  const PositionedDirectional(
                    bottom: AppSpacing.xs,
                    end: AppSpacing.xs,
                    child: GifBadge(),
                  ),
                if (attachment.status == AttachmentStatus.unchecked)
                  // ADR-0029 Amendment 1 A5.6: the upload is kept; Retry
                  // checks the same media id again, with no re-upload.
                  PositionedDirectional(
                    bottom: 0,
                    start: 0,
                    child: TextButton(
                      onPressed: enabled
                          ? () => context.read<AttachmentsCubit>().retryCheck(
                              attachment.id,
                            )
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
                      child: const Text('Retry'),
                    ),
                  )
                else if (attachment.image != null)
                  PositionedDirectional(
                    bottom: 0,
                    start: 0,
                    child: TextButton(
                      focusNode: _altFocus,
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
                            ? 'Add description for ${attachment.isGif ? 'GIF' : 'photo $position'}'
                            : 'Edit description for ${attachment.isGif ? 'GIF' : 'photo $position'}',
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
      case AttachmentStatus.unchecked:
        // The tile's Retry button sits at the bottom, where ALT usually is.
        return _problem(
          context,
          Icons.cloud_off_outlined,
          "Couldn't check this image",
        );
      case AttachmentStatus.rejected:
        // The server's reason is written for users (invalid, policy,
        // capacity, "This GIF is too large or too long.").
        return _problem(
          context,
          Icons.block_outlined,
          attachment.rejectionReason.isEmpty
              ? 'Not accepted'
              : attachment.rejectionReason,
        );
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
        Flexible(
          child: Text(
            text,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall,
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }
}
