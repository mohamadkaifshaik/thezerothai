import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../../../gen/dzeroth/posts/v1/posts.pbenum.dart'
    show ScheduledPostStatus;
import '../../../../shared/format/scheduled_time.dart';
import '../post_error_messages.dart';

/// One row of the Scheduled list (CMP-D6). Laid out like X's: line 1 a small
/// clock icon and the muted "Will send on <time>", line 2 the post text in
/// the primary colour; no avatar. The row is ONE node for a screen reader
/// ("Will send on `<time>` `<text>`"); the Cancel / Dismiss button stays its own
/// 48dp button at the end.
///
/// - PENDING: the text (up to 3 lines), a photo count when photos are
///   attached (nothing is fetched for them), and `Cancel`.
/// - FAILED: the time it was due, a sentence for the failure reason, no text
///   (the draft is cleared on failure) and `Dismiss`. A failed post is never
///   rescheduled: the user dismisses it and writes it again.
///
/// Purely presentational: [onRemove] is the Cancel or Dismiss tap.
class ScheduledPostRow extends StatelessWidget {
  const ScheduledPostRow({
    super.key,
    required this.item,
    required this.onRemove,
  });

  final pb.ScheduledPost item;
  final VoidCallback onRemove;

  bool get _failed =>
      item.status == ScheduledPostStatus.SCHEDULED_POST_STATUS_FAILED;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final use24Hour = MediaQuery.alwaysUse24HourFormatOf(context);
    final due = item.hasPublishAt() ? item.publishAt.toDateTime() : null;
    final timeText = due == null
        ? (_failed ? 'Could not send' : 'Scheduled')
        : _failed
        ? 'Could not send on ${formatScheduledTime(due, use24Hour: use24Hour)}'
        : willSendOnText(due, use24Hour: use24Hour);
    final body = _failed
        ? scheduledFailureMessage(item.failure)
        : item.text.trim();
    final photos = item.media.length;
    final photosText = photos == 0
        ? null
        : photos == 1
        ? '1 photo'
        : '$photos photos';
    final spoken = [timeText, body, ?photosText].where((t) => t.isNotEmpty);
    final removeLabel = _failed ? 'Dismiss' : 'Cancel';

    final content = Semantics(
      container: true,
      label: spoken.join('. '),
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.xs),
                  child: Icon(
                    Icons.schedule_outlined,
                    size: AppIconSize.sm,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    timeText,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            if (body.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                body,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: _failed ? colors.error : colors.onSurface,
                ),
              ),
            ],
            if (photosText != null) ...[
              const SizedBox(height: AppSpacing.sm),
              _PhotoCountChip(label: photosText),
            ],
          ],
        ),
      ),
    );
    final action = Semantics(
      button: true,
      label: _failed ? 'Dismiss failed post' : 'Cancel scheduled post',
      excludeSemantics: true,
      onTap: onRemove,
      child: TextButton(
        style: TextButton.styleFrom(
          minimumSize: const Size(
            AppSpacing.minTapTarget,
            AppSpacing.minTapTarget,
          ),
        ),
        onPressed: onRemove,
        child: Text(removeLabel),
      ),
    );

    // Beside the text on a normal phone; under it when the text is large or
    // the screen narrow, where a trailing button would squeeze the text.
    final stacked =
        MediaQuery.textScalerOf(context).scale(_kRefFontSize) >
            _kRefFontSize * _kStackAtScale ||
        MediaQuery.sizeOf(context).width < _kStackBelowWidth;
    return Padding(
      padding: const EdgeInsetsDirectional.only(
        start: AppSpacing.md,
        end: AppSpacing.xs,
        top: AppSpacing.sm,
        bottom: AppSpacing.sm,
      ),
      child: stacked
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: AppSpacing.sm),
                  child: content,
                ),
                Align(alignment: AlignmentDirectional.centerEnd, child: action),
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: content),
                const SizedBox(width: AppSpacing.xs),
                action,
              ],
            ),
    );
  }
}

/// A text scale above this stacks the action under the text.
const double _kStackAtScale = 1.3;
const double _kRefFontSize = 14;

/// A screen narrower than this stacks the action under the text.
const double _kStackBelowWidth = 360;

/// "2 photos": a small outlined chip, so a photo-only post is not an empty
/// row. Decorative to a screen reader (the row's label already says it).
class _PhotoCountChip extends StatelessWidget {
  const _PhotoCountChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.smd,
          vertical: AppSpacing.xs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.image_outlined,
              size: AppIconSize.sm,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: AppSpacing.xs),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
