import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/session_wiring.dart' show UnexpectedErrorReporter;
import '../../../core/theme/app_theme.dart';
import '../../../gen/dzeroth/moderation/v1/moderation.pbenum.dart';
import '../../../shared/widgets/character_counter.dart';
import '../data/moderation_repository.dart';
import '../domain/report_rules.dart';
import 'bloc/report_cubit.dart';
import 'report_error_messages.dart';

/// How the report sheet was closed.
enum ReportOutcome {
  /// Dismissed, or the report was not sent.
  cancelled,

  /// The server accepted a new report.
  sent,

  /// The server already had this reporter's report for the target (a free
  /// no-op, ADR-0016): nothing new was sent, and the sheet said so.
  alreadyReported,

  /// Sent, and the user asked to block the account next.
  blockRequested,
}

/// Opens the report sheet for one post or account (ADR-0016, P7).
///
/// [subject] is the sentence fragment shown in the title ("@alice's post",
/// "@alice"). [offerBlock] adds a "Block" action after a successful report;
/// the caller runs its own block flow when the result is
/// [ReportOutcome.blockRequested] (reusing `RelationshipCubit` and the block
/// confirmation, never a second implementation). [detail] is one extra
/// sentence under the intro (what the reviewers will see), or null.
Future<ReportOutcome> showReportSheet(
  BuildContext context, {
  required ReportTargetType targetType,
  required String targetId,
  required String subject,
  String? blockLabel,
  String? detail,
}) async {
  final repository = context.read<ModerationRepository>();
  final onError = context.read<UnexpectedErrorReporter>();
  final cubit = ReportCubit(
    repository: repository,
    targetType: targetType,
    targetId: targetId,
    onUnexpectedError: onError,
  );
  try {
    final result = await showModalBottomSheet<ReportOutcome>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (sheetContext) => BlocProvider.value(
        value: cubit,
        child: ReportSheet(
          subject: subject,
          blockLabel: blockLabel,
          detail: detail,
        ),
      ),
    );
    if (result != null) return result;
    // Swiped away or tapped outside after the report went through: it was
    // still sent, so the caller can say so.
    if (!cubit.state.sent) return ReportOutcome.cancelled;
    return cubit.state.alreadyReported
        ? ReportOutcome.alreadyReported
        : ReportOutcome.sent;
  } finally {
    unawaited(cubit.close());
  }
}

/// The content of the report sheet: reasons, optional note, send, and the
/// confirmation (with the optional follow-up "Block"). Drives a
/// [ReportCubit] provided above it.
class ReportSheet extends StatelessWidget {
  const ReportSheet({
    super.key,
    required this.subject,
    this.blockLabel,
    this.detail,
  });

  final String subject;

  /// One more sentence under the intro (W7-18: what a reported message shares).
  final String? detail;

  /// Label of the block follow-up ("Block @alice"); null hides it.
  final String? blockLabel;

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: AppBreakpoints.mobile),
        child: BlocBuilder<ReportCubit, ReportState>(
          buildWhen: (a, b) => a.sent != b.sent,
          builder: (context, state) {
            return state.sent
                ? _Confirmation(blockLabel: blockLabel)
                : _Form(subject: subject, detail: detail);
          },
        ),
      ),
    );
  }
}

class _Form extends StatelessWidget {
  const _Form({required this.subject, this.detail});

  final String subject;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cubit = context.read<ReportCubit>();
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        0,
        AppSpacing.md,
        AppSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text('Report $subject', style: theme.textTheme.titleLarge),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Why are you reporting this? Reports are private; the account '
            "won't see who reported."
            '${detail == null ? '' : ' $detail'}',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          BlocBuilder<ReportCubit, ReportState>(
            buildWhen: (a, b) =>
                a.reason != b.reason || a.submitting != b.submitting,
            builder: (context, state) {
              return Column(
                children: [
                  for (final reason in kReportReasons)
                    _ReasonRow(
                      key: ValueKey('report-reason-${reason.value}'),
                      label: reportReasonLabel(reason),
                      selected: state.reason == reason,
                      enabled: !state.submitting,
                      onTap: () => cubit.selectReason(reason),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: AppSpacing.sm),
          BlocBuilder<ReportCubit, ReportState>(
            buildWhen: (a, b) =>
                a.noteRemaining != b.noteRemaining ||
                a.submitting != b.submitting,
            builder: (context, state) {
              return TextField(
                key: const ValueKey('report-note'),
                enabled: !state.submitting,
                onChanged: cubit.noteChanged,
                minLines: 2,
                maxLines: 4,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  labelText: 'Add details (optional)',
                  counter: CharacterCounter(remaining: state.noteRemaining),
                ),
              );
            },
          ),
          BlocBuilder<ReportCubit, ReportState>(
            buildWhen: (a, b) => a.error != b.error,
            builder: (context, state) {
              final error = state.error;
              if (error == null) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: AppSpacing.sm),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    reportErrorMessage(error),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: AppSpacing.md),
          BlocBuilder<ReportCubit, ReportState>(
            buildWhen: (a, b) =>
                a.canSubmit != b.canSubmit || a.submitting != b.submitting,
            builder: (context, state) {
              return SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, AppSpacing.minTapTarget),
                  ),
                  onPressed: state.canSubmit ? cubit.submit : null,
                  child: state.submitting
                      ? const SizedBox(
                          width: AppIconSize.md,
                          height: AppIconSize.md,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Send report'),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// One selectable reason: a 48dp row with a radio mark (no ListTile).
class _ReasonRow extends StatelessWidget {
  const _ReasonRow({
    super.key,
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      onTap: enabled ? onTap : null,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppSpacing.minTapTarget),
          child: Row(
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: AppIconSize.lg,
                color: selected ? colors.primary : colors.onSurfaceVariant,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(child: Text(label, style: theme.textTheme.bodyLarge)),
            ],
          ),
        ),
      ),
    );
  }
}

class _Confirmation extends StatelessWidget {
  const _Confirmation({required this.blockLabel});

  final String? blockLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final already = context.select((ReportCubit c) => c.state.alreadyReported);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        0,
        AppSpacing.md,
        AppSpacing.md,
      ),
      child: Semantics(
        liveRegion: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.check_circle_outline,
              size: AppIconSize.xl,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              already ? "You've already reported this" : 'Thanks for reporting',
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              already
                  ? "We have your report and we'll look at it."
                  : "We'll review it within 48 hours. Clearly illegal "
                        'content is removed as soon as we see it.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            if (blockLabel != null) ...[
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, AppSpacing.minTapTarget),
                  ),
                  onPressed: () =>
                      Navigator.of(context).pop(ReportOutcome.blockRequested),
                  child: Text(blockLabel!),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, AppSpacing.minTapTarget),
                ),
                onPressed: () => Navigator.of(context).pop(
                  already ? ReportOutcome.alreadyReported : ReportOutcome.sent,
                ),
                child: const Text('Done'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
