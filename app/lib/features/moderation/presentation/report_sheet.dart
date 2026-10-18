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

  /// The server accepted the report (or already had it).
  sent,

  /// Sent, and the user asked to block the account next.
  blockRequested,
}

/// Opens the report sheet for one post or account (ADR-0016, P7).
///
/// [subject] is the sentence fragment shown in the title ("@alice's post",
/// "@alice"). [offerBlock] adds a "Block" action after a successful report;
/// the caller runs its own block flow when the result is
/// [ReportOutcome.blockRequested] (reusing `RelationshipCubit` and the block
/// confirmation, never a second implementation).
Future<ReportOutcome> showReportSheet(
  BuildContext context, {
  required ReportTargetType targetType,
  required String targetId,
  required String subject,
  String? blockLabel,
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
        child: ReportSheet(subject: subject, blockLabel: blockLabel),
      ),
    );
    if (result != null) return result;
    // Swiped away or tapped outside after the report went through: it was
    // still sent, so the caller can say so.
    return cubit.state.sent ? ReportOutcome.sent : ReportOutcome.cancelled;
  } finally {
    unawaited(cubit.close());
  }
}

/// The content of the report sheet: reasons, optional note, send, and the
/// confirmation (with the optional follow-up "Block"). Drives a
/// [ReportCubit] provided above it.
class ReportSheet extends StatelessWidget {
  const ReportSheet({super.key, required this.subject, this.blockLabel});

  final String subject;

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
                : _Form(subject: subject);
          },
        ),
      ),
    );
  }
}

class _Form extends StatelessWidget {
  const _Form({required this.subject});

  final String subject;

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
            "won't see who reported.",
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
                onPressed: () => Navigator.of(context).pop(ReportOutcome.sent),
                child: const Text('Done'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
