import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../../../gen/dzeroth/posts/v1/posts.pbenum.dart'
    show ScheduledPostStatus;
import '../../../../shared/format/scheduled_time.dart';
import '../../../../shared/widgets/primitives/app_card.dart';
import '../../../../shared/widgets/primitives/app_pill_button.dart';
import '../post_error_messages.dart';

/// One card of the Scheduled list (the dzeroth-mobile, tablet and desktop
/// Scheduled mocks): the raised card, the teal clock line "Will send on
/// `<time>`", the post text, and the actions. The text part is ONE node for
/// a screen reader ("Will send on `<time>`. `<text>`"); each action is its
/// own button.
///
/// - PENDING: the text (up to 3 lines), a photo count when photos are
///   attached (nothing is fetched for them), then Edit and Post now (when
///   [onEdit] / [onPostNow] are given: the `scheduled_posts` flag) and a
///   More menu with "Cancel scheduled post".
/// - FAILED: the time it was due, a sentence for the failure reason, no text
///   (the draft is cleared on failure) and Dismiss. A failed post is never
///   rescheduled: the user dismisses it and writes it again.
///
/// [wide] is the tablet and desktop look: more padding, a step up in type
/// and a navy Post now pill (the phone's is a text button).
///
/// Purely presentational: the callbacks are the taps.
class ScheduledPostRow extends StatelessWidget {
  const ScheduledPostRow({
    super.key,
    required this.item,
    required this.onRemove,
    this.onEdit,
    this.onPostNow,
    this.wide = false,
  });

  final pb.ScheduledPost item;

  /// Cancel (PENDING) or Dismiss (FAILED).
  final VoidCallback onRemove;
  final VoidCallback? onEdit;
  final VoidCallback? onPostNow;
  final bool wide;

  bool get _failed =>
      item.status == ScheduledPostStatus.SCHEDULED_POST_STATUS_FAILED;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final accent = context.appColors.accentText;
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
    final timeColor = _failed ? colors.error : accent;

    final content = Semantics(
      container: true,
      label: spoken.join('. '),
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: AppScheduledLayout.iconTop),
                child: Icon(
                  _failed ? Icons.error_outline : Icons.schedule_outlined,
                  size: AppIconSize.sm,
                  color: timeColor,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  timeText,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontSize: wide
                        ? AppScheduledLayout.wideTimeSize
                        : AppScheduledLayout.phoneTimeSize,
                    fontWeight: AppTypeTokens.weightUi,
                    color: timeColor,
                  ),
                ),
              ),
            ],
          ),
          if (body.isNotEmpty) ...[
            SizedBox(
              height: wide
                  ? AppScheduledLayout.wideTextGap
                  : AppScheduledLayout.phoneTextGap,
            ),
            Text(
              body,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyLarge?.copyWith(
                fontSize: wide
                    ? AppScheduledLayout.wideTextSize
                    : AppScheduledLayout.phoneTextSize,
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
    );

    final onEdit = this.onEdit;
    final onPostNow = this.onPostNow;
    final actions = Wrap(
      spacing: wide ? AppSpacing.smd : AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: _failed
          ? [
              _Spoken(
                label: 'Dismiss failed post',
                onTap: onRemove,
                child: AppPillButton(
                  label: 'Dismiss',
                  compact: true,
                  variant: AppButtonVariant.outline,
                  onPressed: onRemove,
                ),
              ),
            ]
          : [
              if (onEdit != null)
                AppPillButton(
                  label: 'Edit',
                  compact: true,
                  variant: AppButtonVariant.outline,
                  onPressed: onEdit,
                ),
              if (onPostNow != null)
                AppPillButton(
                  label: 'Post now',
                  compact: true,
                  variant: wide ? AppButtonVariant.navy : AppButtonVariant.text,
                  onPressed: onPostNow,
                ),
              // Without Edit and Post now (scheduling off for this caller),
              // Cancel is the one action and stays in sight.
              if (onEdit == null && onPostNow == null)
                _Spoken(
                  label: 'Cancel scheduled post',
                  onTap: onRemove,
                  child: AppPillButton(
                    label: 'Cancel',
                    compact: true,
                    variant: AppButtonVariant.outline,
                    onPressed: onRemove,
                  ),
                ),
            ],
    );
    final more = !_failed && (onEdit != null || onPostNow != null)
        ? PopupMenuButton<VoidCallback>(
            tooltip: 'More options',
            icon: const Icon(Icons.more_horiz, size: AppIconSize.md),
            onSelected: (action) => action(),
            itemBuilder: (_) => [
              PopupMenuItem(
                value: onRemove,
                child: const Text('Cancel scheduled post'),
              ),
            ],
          )
        : null;

    return AppCard(
      margin: wide
          ? const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppScheduledLayout.wideCardGap / 2,
            )
          : EdgeInsets.zero,
      padding: wide
          ? const EdgeInsets.fromLTRB(
              AppScheduledLayout.wideCardPaddingH,
              AppScheduledLayout.wideCardPaddingV,
              AppSpacing.sm,
              AppScheduledLayout.wideCardPaddingV,
            )
          : const EdgeInsetsDirectional.fromSTEB(
              AppSpacing.md,
              AppSpacing.md,
              AppSpacing.xs,
              AppSpacing.md,
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Padding(
                  padding: EdgeInsetsDirectional.only(
                    end: more == null ? AppSpacing.sm : 0,
                  ),
                  child: content,
                ),
              ),
              ?more,
            ],
          ),
          SizedBox(
            height: wide
                ? AppScheduledLayout.wideActionsGap
                : AppScheduledLayout.phoneTextGap,
          ),
          Align(alignment: AlignmentDirectional.centerStart, child: actions),
        ],
      ),
    );
  }
}

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

/// Speaks [label] for a pill whose visible word is shorter ("Cancel" reads
/// as "Cancel scheduled post"): one button node with the pill's tap.
class _Spoken extends StatelessWidget {
  const _Spoken({
    required this.label,
    required this.onTap,
    required this.child,
  });

  final String label;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    onTap: onTap,
    excludeSemantics: true,
    child: child,
  );
}
