import 'package:flutter/cupertino.dart' show CupertinoPicker;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/privacy_policy_link.dart'
    show launchCommunityRules;
import '../../../../shared/widgets/character_counter.dart';
import '../../domain/composer_draft.dart' show DraftPoll;
import '../../domain/poll_rules.dart';

/// Hint under a duplicate choice (the server says the same on VALIDATION).
const kPollDuplicateHint = 'Choices must be different';

/// Hint under the length when it was raised to the minimum.
const kPollMinLengthHint = 'A poll lasts at least 5 minutes.';

/// The rule in one line under the builder (W6-43; full text in `rules.html`).
const kPollSensitiveHint = "Don't ask for sensitive personal info.";

/// The placeholder of the post text while a poll is open: the text is the
/// poll's question.
const kPollQuestionHint = 'Ask a question';

/// Upper bound on what a choice field accepts, above 25 so the counter can
/// turn red and show how much to cut (as the post text does).
const kPollChoiceInputCap = 60;

/// Asks for a poll length in minutes (null: cancelled). A seam: the builder
/// uses [showPollLengthSheet] under 600dp wide and inline dropdowns above.
typedef PollLengthPicker = Future<int?> Function(
  BuildContext context,
  int initialMinutes,
);

/// The inline poll builder of the composer (W6-12, ADR-0029, `composer.md`
/// section 2): Choice 1 and 2, up to two optional choices with a remove
/// button, "Add a choice", the poll length and a red "Remove poll".
///
/// Presentational: it renders the [poll] the cubit holds and reports edits
/// through the callbacks; the rules come from [analyzePoll] (the shared
/// fixture `testdata/poll_rules.json` pins them). Length is three dropdowns
/// at 600dp and wider and one tappable row opening a wheel sheet below.
class ComposerPollBuilder extends StatefulWidget {
  const ComposerPollBuilder({
    super.key,
    required this.poll,
    required this.durationClamped,
    required this.enabled,
    required this.onChoiceChanged,
    required this.onChoiceAdded,
    required this.onChoiceRemoved,
    required this.onLengthChanged,
    required this.onRemove,
    this.pickLength = showPollLengthSheet,
    this.openRules = launchCommunityRules,
  });

  final DraftPoll poll;

  /// The length was raised to the 5 minute minimum: say so.
  final bool durationClamped;

  /// False while the post is being sent.
  final bool enabled;
  final void Function(int index, String text) onChoiceChanged;
  final VoidCallback onChoiceAdded;
  final ValueChanged<int> onChoiceRemoved;
  final ValueChanged<int> onLengthChanged;
  final VoidCallback onRemove;
  final PollLengthPicker pickLength;

  /// Opens the community rules (a test seam; default opens the web page).
  final void Function(BuildContext context) openRules;

  @override
  State<ComposerPollBuilder> createState() => _ComposerPollBuilderState();
}

class _ComposerPollBuilderState extends State<ComposerPollBuilder> {
  final _controllers = <TextEditingController>[];

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(ComposerPollBuilder old) {
    super.didUpdateWidget(old);
    _sync();
  }

  /// One controller per row; a row's text follows the cubit only when it
  /// differs (a typed edit already equals it, so the caret never jumps).
  void _sync() {
    final choices = widget.poll.choices;
    while (_controllers.length < choices.length) {
      _controllers.add(TextEditingController());
    }
    while (_controllers.length > choices.length) {
      _controllers.removeLast().dispose();
    }
    for (var i = 0; i < choices.length; i++) {
      if (_controllers[i].text != choices[i]) _controllers[i].text = choices[i];
    }
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickLength() async {
    final minutes = await widget.pickLength(
      context,
      widget.poll.durationMinutes,
    );
    if (minutes != null) widget.onLengthChanged(minutes);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final poll = widget.poll;
    final analysis = analyzePoll(poll);
    final wide = MediaQuery.sizeOf(context).width >= AppBreakpoints.mobile;
    final canAdd = poll.choices.length < kPollMaxChoices;
    final box = DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: FocusTraversalGroup(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < poll.choices.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: _ChoiceRow(
                    // The slot, not the text: a row keeps its field (and
                    // focus) while it is edited.
                    key: ValueKey('poll-choice-$i'),
                    index: i,
                    controller: _controllers[i],
                    check: analysis.choices[i],
                    enabled: widget.enabled,
                    isLast: i == poll.choices.length - 1,
                    onChanged: (text) => widget.onChoiceChanged(i, text),
                    onRemove: i >= kPollMinChoices
                        ? () => widget.onChoiceRemoved(i)
                        : null,
                  ),
                ),
              if (canAdd)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    onPressed: widget.enabled ? widget.onChoiceAdded : null,
                    icon: const Icon(Icons.add, size: AppIconSize.md),
                    label: const Text('Add a choice'),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(
                        AppSpacing.minButtonWidth,
                        AppSpacing.minTapTarget,
                      ),
                    ),
                  ),
                ),
              const Divider(height: AppSpacing.md),
              Text('Poll length', style: theme.textTheme.titleSmall),
              const SizedBox(height: AppSpacing.sm),
              if (wide)
                _LengthDropdowns(
                  totalMinutes: poll.durationMinutes,
                  enabled: widget.enabled,
                  onChanged: widget.onLengthChanged,
                )
              else
                _LengthRow(
                  totalMinutes: poll.durationMinutes,
                  enabled: widget.enabled,
                  onTap: _pickLength,
                ),
              if (widget.durationClamped)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.xs),
                  child: Text(
                    kPollMinLengthHint,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              const Divider(height: AppSpacing.lg),
              Align(
                alignment: AlignmentDirectional.center,
                child: TextButton(
                  onPressed: widget.enabled ? widget.onRemove : null,
                  style: TextButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                    minimumSize: const Size(
                      AppSpacing.minButtonWidth,
                      AppSpacing.minTapTarget,
                    ),
                  ),
                  child: const Text('Remove poll'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        box,
        _SensitiveInfoHint(onTap: () => widget.openRules(context)),
      ],
    );
  }
}

/// The one-line rule under the builder (W6-43, GDPR Art. 9): polls must not ask
/// for sensitive personal information. "See the rules" opens the community
/// rules; the whole row is at least 48dp tall and wraps at large text.
class _SensitiveInfoHint extends StatelessWidget {
  const _SensitiveInfoHint({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Semantics(
      link: true,
      label: "$kPollSensitiveHint. See the community rules.",
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        key: const ValueKey("poll-sensitive-hint"),
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppSpacing.minTapTarget),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text.rich(
              TextSpan(
                style: style,
                children: [
                  const TextSpan(text: kPollSensitiveHint),
                  const TextSpan(text: " "),
                  TextSpan(
                    text: "See the rules",
                    style: TextStyle(
                      color: context.appColors.accentText,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One choice: the field with its "N / 25" counter, the inline hint for a
/// duplicate or an unsupported character, and (choices 3 and 4) a remove
/// button. Choices 3 and 4 are optional and say so.
class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({
    super.key,
    required this.index,
    required this.controller,
    required this.check,
    required this.enabled,
    required this.isLast,
    required this.onChanged,
    required this.onRemove,
  });

  final int index;
  final TextEditingController controller;
  final PollChoiceCheck check;
  final bool enabled;
  final bool isLast;
  final ValueChanged<String> onChanged;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final label = index < kPollMinChoices
        ? 'Choice ${index + 1}'
        : 'Choice ${index + 1} (optional)';
    final errorText = check.duplicate
        ? kPollDuplicateHint
        : check.forbidden
        ? 'Remove the unsupported characters.'
        : null;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            enabled: enabled,
            maxLines: 1,
            textInputAction: isLast
                ? TextInputAction.done
                : TextInputAction.next,
            inputFormatters: [
              LengthLimitingTextInputFormatter(kPollChoiceInputCap),
            ],
            onChanged: onChanged,
            decoration: InputDecoration(
              labelText: label,
              errorText: errorText,
              errorMaxLines: 2,
              // Over 25 the field turns red without a second line of text:
              // the counter already says by how much.
              error: check.tooLong && errorText == null
                  ? const SizedBox.shrink()
                  : null,
              counter: CharacterCounter(
                remaining: kPollChoiceMaxCodePoints - check.codePoints,
                limit: kPollChoiceMaxCodePoints,
              ),
            ),
          ),
        ),
        if (onRemove != null)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs),
            child: IconButton(
              tooltip: 'Remove choice ${index + 1}',
              icon: const Icon(Icons.close),
              onPressed: enabled ? onRemove : null,
            ),
          ),
      ],
    );
  }
}

/// The compact length control under 600dp: one 48dp+ row with the length in
/// words that opens [showPollLengthSheet]. The words wrap at large text.
class _LengthRow extends StatelessWidget {
  const _LengthRow({
    required this.totalMinutes,
    required this.enabled,
    required this.onTap,
  });

  final int totalMinutes;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = pollLengthText(totalMinutes);
    return Semantics(
      button: true,
      enabled: enabled,
      label: 'Poll length, $text',
      hint: 'Change the poll length',
      excludeSemantics: true,
      onTap: enabled ? onTap : null,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppSpacing.minTapTarget),
          child: Row(
            children: [
              Expanded(child: Text(text, style: theme.textTheme.bodyLarge)),
              const SizedBox(width: AppSpacing.sm),
              Icon(
                Icons.expand_more,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Days / Hours / Minutes dropdowns for 600dp and wider (CMP-D6 uses the
/// platform picker on phones and the desktop form on wide screens).
class _LengthDropdowns extends StatelessWidget {
  const _LengthDropdowns({
    required this.totalMinutes,
    required this.enabled,
    required this.onChanged,
  });

  final int totalMinutes;
  final bool enabled;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final length = PollLength.fromMinutes(totalMinutes);
    Widget field(String label, int value, int count, int unit) {
      return Expanded(
        child: DropdownButtonFormField<int>(
          // Re-keyed by value: the field shows what the cubit holds.
          key: ValueKey('poll-$label-$value'),
          initialValue: value,
          isExpanded: true,
          decoration: InputDecoration(labelText: label),
          items: [
            for (var n = 0; n < count; n++)
              DropdownMenuItem(value: n, child: Text('$n')),
          ],
          onChanged: enabled
              ? (n) {
                  if (n == null) return;
                  onChanged(totalMinutes - value * unit + n * unit);
                }
              : null,
        ),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        field('Days', length.days, 8, 1440),
        const SizedBox(width: AppSpacing.sm),
        field('Hours', length.hours, 24, 60),
        const SizedBox(width: AppSpacing.sm),
        field('Minutes', length.minutes, 60, 1),
      ],
    );
  }
}

/// The phone length picker: a bottom sheet with three wheels (days, hours,
/// minutes) and a Done button; returns the total minutes, or null when
/// dismissed. The cubit raises anything under 5 minutes and cuts anything
/// over 7 days, so the wheels need no cross-limits.
Future<int?> showPollLengthSheet(BuildContext context, int initialMinutes) {
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _PollLengthSheet(initial: initialMinutes),
  );
}

class _PollLengthSheet extends StatefulWidget {
  const _PollLengthSheet({required this.initial});

  final int initial;

  @override
  State<_PollLengthSheet> createState() => _PollLengthSheetState();
}

class _PollLengthSheetState extends State<_PollLengthSheet> {
  late int _days;
  late int _hours;
  late int _minutes;

  @override
  void initState() {
    super.initState();
    final l = PollLength.fromMinutes(widget.initial);
    _days = l.days;
    _hours = l.hours;
    _minutes = l.minutes;
  }

  Widget _wheel(
    String label,
    int count,
    int initial,
    ValueChanged<int> onChanged,
  ) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        children: [
          Text(label, style: theme.textTheme.labelLarge),
          SizedBox(
            height: 160,
            child: Semantics(
              label: label,
              child: CupertinoPicker(
                itemExtent: AppSpacing.xxl,
                scrollController: FixedExtentScrollController(
                  initialItem: initial,
                ),
                onSelectedItemChanged: onChanged,
                children: [
                  for (var n = 0; n < count; n++)
                    Center(child: Text('$n', style: theme.textTheme.bodyLarge)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Poll length',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  _wheel('Days', 8, _days, (n) => _days = n),
                  _wheel('Hours', 24, _hours, (n) => _hours = n),
                  _wheel('Minutes', 60, _minutes, (n) => _minutes = n),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              FilledButton(
                onPressed: () =>
                    Navigator.of(context)
                        .pop(_days * 1440 + _hours * 60 + _minutes),
                child: const Text('Done'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
