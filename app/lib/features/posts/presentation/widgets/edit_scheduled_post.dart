import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../../../shared/format/scheduled_time.dart';
import '../../../../shared/widgets/primitives/app_dialog.dart';
import '../../../../shared/widgets/primitives/app_pill_button.dart';
import '../../domain/post_text_rules.dart';
import '../bloc/scheduled_posts_cubit.dart';
import '../post_error_messages.dart';
import 'draft_problem_hint.dart';
import 'schedule_dialog.dart';

/// Saves the changed fields (null: unchanged) and says how it went.
typedef SaveScheduledEdit = Future<ScheduledEdit> Function({
  String? text,
  DateTime? publishAt,
});

/// Opens the editor of a PENDING scheduled post: a full-screen page below
/// [AppBreakpoints.mobile] wide, a centred dialog above (as the Schedule
/// dialog). Closes itself once [onSave] answers anything but a failure, and
/// returns that outcome; null when left without saving.
Future<ScheduledEditOutcome?> showEditScheduledPost(
  BuildContext context, {
  required pb.ScheduledPost item,
  required SaveScheduledEdit onSave,
  SchedulePickDate? pickDate,
  SchedulePickTime? pickTime,
}) {
  Widget view(BuildContext context, {required bool page}) =>
      EditScheduledPostView(
        item: item,
        onSave: onSave,
        page: page,
        pickDate: pickDate,
        pickTime: pickTime,
      );
  if (MediaQuery.sizeOf(context).width < AppBreakpoints.mobile) {
    return Navigator.of(context).push(
      MaterialPageRoute<ScheduledEditOutcome>(
        fullscreenDialog: true,
        builder: (context) =>
            Scaffold(body: SafeArea(child: view(context, page: true))),
      ),
    );
  }
  return showAppMaterialDialog<ScheduledEditOutcome>(
    context: context,
    maxWidth: AppSize.editScheduledDialog,
    builder: (context) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: AppSize.editScheduledDialog,
        ),
        child: view(context, page: false),
      ),
    ),
  );
}

/// The editor: Close, the title and Save; the text with its counter; the
/// send time with Change (the composer's Schedule dialog). Save sends only
/// what changed and stays disabled until something did and the text can be
/// posted. A failure keeps the editor open with the reason under the text.
class EditScheduledPostView extends StatefulWidget {
  const EditScheduledPostView({
    super.key,
    required this.item,
    required this.onSave,
    this.page = false,
    this.pickDate,
    this.pickTime,
  });

  final pb.ScheduledPost item;
  final SaveScheduledEdit onSave;

  /// Full-screen page (phones) rather than a dialog.
  final bool page;
  final SchedulePickDate? pickDate;
  final SchedulePickTime? pickTime;

  @override
  State<EditScheduledPostView> createState() => _EditScheduledPostViewState();
}

class _EditScheduledPostViewState extends State<EditScheduledPostView> {
  late final TextEditingController _text = TextEditingController(
    text: widget.item.text,
  )..addListener(() => setState(() {}));
  late final DateTime? _initialTime = widget.item.hasPublishAt()
      ? widget.item.publishAt.toDateTime().toLocal()
      : null;
  late DateTime? _time = _initialTime;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  PostDraft get _draft => analyzePostDraft(_text.text);

  bool get _textChanged => _draft.text != widget.item.text.trim();
  bool get _timeChanged => _time != _initialTime;

  /// A photo post may have no text; anything else needs a postable draft.
  bool get _textOk {
    final problem = _draft.problem;
    if (problem == null) return true;
    return problem == PostDraftProblem.empty && widget.item.media.isNotEmpty;
  }

  bool get _canSave =>
      !_saving && (_textChanged || _timeChanged) && _textOk && _time != null;

  Future<void> _changeTime() async {
    final result = await showScheduleDialog(
      context,
      initial: _time,
      hasMedia: widget.item.media.isNotEmpty,
      pickDate: widget.pickDate ?? defaultSchedulePickDate,
      pickTime: widget.pickTime ?? defaultSchedulePickTime,
    );
    if (!mounted) return;
    // Only a chosen time edits; "Remove schedule" and the list link leave
    // the time as it was (Post now is on the card).
    if (result is ScheduleChosen) {
      setState(() => _time = result.publishAt.toLocal());
    }
  }

  Future<void> _save() async {
    if (!_canSave) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await widget.onSave(
      text: _textChanged ? _draft.text : null,
      publishAt: _timeChanged ? _time : null,
    );
    if (!mounted) return;
    if (result.outcome == ScheduledEditOutcome.failed) {
      setState(() {
        _saving = false;
        _error = editScheduledErrorMessage(result.error!);
      });
      return;
    }
    Navigator.of(context).pop(result.outcome);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final use24Hour = MediaQuery.alwaysUse24HourFormatOf(context);
    final time = _time;
    final draft = _draft;
    final error = _error;
    return Column(
      mainAxisSize: widget.page ? MainAxisSize.max : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.xs,
            AppSpacing.sm,
            AppSpacing.md,
            AppSpacing.sm,
          ),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close),
                onPressed: _saving ? null : () => Navigator.of(context).pop(),
              ),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    'Edit scheduled post',
                    style: theme.textTheme.titleLarge,
                  ),
                ),
              ),
              AppPillButton(
                label: 'Save',
                compact: true,
                busy: _saving,
                busySemanticsLabel: 'Saving',
                onPressed: _canSave ? _save : null,
              ),
            ],
          ),
        ),
        Flexible(
          fit: widget.page ? FlexFit.tight : FlexFit.loose,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.xs,
              AppSpacing.md,
              AppSpacing.lg,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _text,
                  enabled: !_saving,
                  minLines: 3,
                  maxLines: 8,
                  keyboardType: TextInputType.multiline,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Post',
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Row(
                  children: [
                    DraftProblemHint(problem: draft.problem),
                    if (draft.problem == null ||
                        draft.problem == PostDraftProblem.empty)
                      const Spacer(),
                    Text(
                      '${draft.remaining}',
                      semanticsLabel: '${draft.remaining} characters left',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: draft.remaining < 0
                            ? colors.error
                            : colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                Row(
                  children: [
                    Icon(
                      Icons.schedule_outlined,
                      size: AppIconSize.md,
                      color: context.appColors.accentText,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        time == null
                            ? 'No time set'
                            : willSendOnText(time, use24Hour: use24Hour),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: AppTypeTokens.weightUi,
                          color: context.appColors.accentText,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: _saving ? null : _changeTime,
                      child: const Text('Change'),
                    ),
                  ],
                ),
                if (error != null) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      error,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.error,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}
