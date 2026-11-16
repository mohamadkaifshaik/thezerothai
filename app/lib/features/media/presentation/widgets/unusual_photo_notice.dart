import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/theme/app_theme.dart';
import '../../domain/unusual_aspect.dart';
import '../bloc/attachments_cubit.dart';
import '../media_error_messages.dart';

/// The shape to warn about: only when [items] is exactly one photo (not a
/// GIF) that is very narrow or very wide. Two or more photos show as uncropped
/// strips in the feed, so they need no notice.
UnusualShape? singleThinShape(List<Attachment> items) =>
    items.length == 1 ? items.single.unusualShape : null;

/// The notice text for [shape].
String thinPhotoLine(UnusualShape shape) =>
    thinPhotoNotice(narrow: shape == UnusualShape.narrow);

/// Under the attachment grid: tells the user their only photo is very narrow
/// or very wide and will be cropped in the feed. Never blocks posting.
/// "Remove" drops the photo; "Keep photo" hides the notice until the photo
/// set changes.
class UnusualPhotoNotice extends StatefulWidget {
  const UnusualPhotoNotice({
    super.key,
    required this.items,
    this.enabled = true,
  });

  final List<Attachment> items;
  final bool enabled;

  @override
  State<UnusualPhotoNotice> createState() => _UnusualPhotoNoticeState();
}

class _UnusualPhotoNoticeState extends State<UnusualPhotoNotice> {
  String? _dismissed;

  @override
  void didUpdateWidget(UnusualPhotoNotice old) {
    super.didUpdateWidget(old);
    // Leaving the single-photo state forgets a dismissal, so going back to
    // one thin photo shows the notice again.
    if (widget.items.length != 1) _dismissed = null;
  }

  @override
  Widget build(BuildContext context) {
    final shape = singleThinShape(widget.items);
    if (shape == null || _dismissed == widget.items.single.id) {
      return const SizedBox.shrink();
    }
    final id = widget.items.single.id;
    final theme = Theme.of(context);
    final warning = context.appColors.warning;
    return Semantics(
      container: true,
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.xs,
          AppSpacing.md,
          0,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.xs),
                  child: ExcludeSemantics(
                    child: Icon(
                      Icons.info_outline_rounded,
                      size: AppIconSize.md,
                      color: warning,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    thinPhotoLine(shape),
                    style: theme.textTheme.bodySmall?.copyWith(color: warning),
                  ),
                ),
              ],
            ),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Wrap(
                spacing: AppSpacing.sm,
                children: [
                  TextButton(
                    onPressed: widget.enabled
                        ? () => context.read<AttachmentsCubit>().remove(id)
                        : null,
                    child: const Text(kThinPhotoRemove),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _dismissed = id),
                    child: const Text(kThinPhotoKeep),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
