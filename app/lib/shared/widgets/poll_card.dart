import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../features/engagement/domain/poll_display.dart';
import '../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../format/poll_time.dart';

/// The poll of a post (ADR-0029, W6-13): choice buttons while the viewer may
/// vote, result bars once the server sent counts, and plain labels in between.
/// Presentational: it draws a [PollDisplay] and calls [onVote] /
/// [onSeeFinalResults]; it reads no bloc and calls no RPC (`PostPoll` wires
/// it to `PollCubit`).
///
/// - [PollMode.vote]: one outlined 48dp-minimum button per choice.
/// - [PollMode.results]: a bar per choice with its percent (the percents total
///   100), the leading choice in bold, a check on the viewer's own choice.
/// - [PollMode.votedHidden] / [PollMode.readOnly] / [PollMode.finalPending]:
///   the labels (a check on the viewer's), no counts. Hidden counts are zeros
///   on the wire, so no bar is drawn from them.
/// - Footer: "12 votes · 2 days left" or "12 votes · Final results". Counts
///   are what the server said when the post was read, never live.
/// - No timer: the countdown is computed from `closes_at` and [now] when the
///   card is built.
class PollCard extends StatelessWidget {
  const PollCard({
    super.key,
    required this.display,
    required this.now,
    this.onVote,
    this.onSeeFinalResults,
    this.refreshing = false,
  });

  final PollDisplay display;

  /// Reference time for the countdown (the card does not tick).
  final DateTime now;

  /// A vote button was tapped (0-based choice). Null: no buttons.
  final ValueChanged<int>? onVote;

  /// "See final results" was tapped. Null hides the button.
  final VoidCallback? onSeeFinalResults;

  /// The final-results read is in flight.
  final bool refreshing;

  String _footer() {
    final votes = formatPollVotes(display.totalVotes);
    if (display.pending) return 'Sending your vote…';
    if (display.closed) return '$votes · Final results';
    final closesAt = display.closesAt;
    if (closesAt == null) return votes;
    return '$votes · ${formatPollTimeLeft(closesAt, now)} left';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final canVote = display.mode == PollMode.vote && onVote != null;
    return Semantics(
      container: true,
      label: 'Poll, ${display.labels.length} choices',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < display.labels.length; i++) ...[
            if (i > 0) const SizedBox(height: AppSpacing.sm),
            _ChoiceRow(
              key: ValueKey('poll-choice-$i'),
              index: i,
              display: display,
              onVote: canVote ? () => onVote!(i) : null,
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Flexible(
                child: Text(
                  _footer(),
                  style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                ),
              ),
            ],
          ),
          if (display.mode == PollMode.finalPending &&
              onSeeFinalResults != null)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Semantics(
                button: true,
                enabled: !refreshing,
                label: 'See final results',
                excludeSemantics: true,
                child: TextButton(
                  key: const ValueKey('poll-see-final'),
                  onPressed: refreshing ? null : onSeeFinalResults,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(
                      AppSpacing.minTapTarget,
                      AppSpacing.minTapTarget,
                    ),
                    padding: EdgeInsets.zero,
                    tapTargetSize: MaterialTapTargetSize.padded,
                  ),
                  child: refreshing
                      ? const SizedBox.square(
                          dimension: AppIconSize.md,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('See final results'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({
    super.key,
    required this.index,
    required this.display,
    required this.onVote,
  });

  final int index;
  final PollDisplay display;
  final VoidCallback? onVote;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = display.labels[index];
    final mine = display.myChoice == index;
    final bars = display.showsBars;
    final percent = bars ? display.percents[index] : 0;
    final leading = display.leading.contains(index);
    final voting = onVote != null;
    final radius = BorderRadius.circular(AppRadius.md);
    final accent = context.appColors.accentText;

    final spoken = [
      if (voting) 'Vote for $label' else label,
      if (bars) '$percent percent',
      if (mine) 'your vote',
    ].join(', ');

    final textStyle = theme.textTheme.bodyLarge?.copyWith(
      fontWeight: leading || mine ? FontWeight.w700 : null,
      color: voting ? accent : null,
    );

    final content = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.smd,
        vertical: AppSpacing.sm,
      ),
      child: Row(
        children: [
          if (mine) ...[
            Icon(Icons.check_circle, size: AppIconSize.md, color: accent),
            const SizedBox(width: AppSpacing.sm),
          ],
          Expanded(
            child: Text(
              label,
              style: textStyle,
              textAlign: voting ? TextAlign.center : TextAlign.start,
            ),
          ),
          if (bars) ...[
            const SizedBox(width: AppSpacing.sm),
            Text(
              '$percent%',
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: leading ? FontWeight.w700 : null,
              ),
            ),
          ],
        ],
      ),
    );

    Widget body = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: AppSpacing.minTapTarget),
      child: Center(child: content),
    );

    if (bars) {
      body = Stack(
        children: [
          Positioned.fill(
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: FractionallySizedBox(
                widthFactor: percent / 100,
                heightFactor: 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: leading
                        ? theme.colorScheme.primary.withValues(
                            alpha: AppOpacity.pollLeadingBar,
                          )
                        : theme.dividerColor,
                  ),
                ),
              ),
            ),
          ),
          body,
        ],
      );
    }

    final bordered = DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(color: voting ? accent : theme.dividerColor),
      ),
      child: ClipRRect(borderRadius: radius, child: body),
    );

    return Semantics(
      container: true,
      button: voting,
      label: spoken,
      excludeSemantics: true,
      onTap: onVote,
      child: voting
          ? InkWell(onTap: onVote, borderRadius: radius, child: bordered)
          : bordered,
    );
  }
}

/// A poll on a repost or quote row (ADR-0029 D5): the frozen definition
/// only (labels and `closes_at`, no counts), so it is read-only and points to
/// the original post for live results. Compact: "Poll · 3 choices · ends in 2
/// days"; with [showOptions] the labels are listed under it. Tapping calls
/// [onOpen] (the original). 48dp minimum height.
class PollEmbedSummary extends StatelessWidget {
  const PollEmbedSummary({
    super.key,
    required this.poll,
    required this.now,
    this.showOptions = false,
    this.onOpen,
  });

  final pb.Poll poll;
  final DateTime now;
  final bool showOptions;
  final VoidCallback? onOpen;

  /// "Poll · 3 choices · ends in 2 days" / "ended".
  static String summary(pb.Poll poll, DateTime now) {
    final count = poll.choices.length;
    final closesAt = poll.hasClosesAt() ? poll.closesAt.toDateTime() : null;
    final ended = poll.closed || (closesAt != null && !closesAt.isAfter(now));
    final tail = ended
        ? 'ended'
        : closesAt == null
        ? null
        : 'ends in ${formatPollTimeLeft(closesAt, now)}';
    return ['Poll', '$count choice${count == 1 ? '' : 's'}', ?tail].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final text = summary(poll, now);
    final radius = BorderRadius.circular(AppRadius.md);
    final box = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: AppSpacing.minTapTarget),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.poll_outlined, size: AppIconSize.md, color: muted),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    text,
                    style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                  ),
                ),
              ],
            ),
            if (showOptions)
              for (final choice in poll.choices) ...[
                const SizedBox(height: AppSpacing.sm),
                DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    border: Border.all(color: theme.dividerColor),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.smd,
                      vertical: AppSpacing.sm,
                    ),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(
                        choice.label,
                        style: theme.textTheme.bodyLarge,
                      ),
                    ),
                  ),
                ),
              ],
          ],
        ),
      ),
    );
    return Semantics(
      container: true,
      button: onOpen != null,
      label: [
        text,
        if (showOptions) poll.choices.map((c) => c.label).join(', '),
        if (onOpen != null) 'Open the post for results',
      ].join('. '),
      excludeSemantics: true,
      onTap: onOpen,
      child: onOpen == null
          ? box
          : InkWell(onTap: onOpen, borderRadius: radius, child: box),
    );
  }
}
