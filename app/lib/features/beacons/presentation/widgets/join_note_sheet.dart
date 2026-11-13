import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/primitives/character_counter.dart';
import '../../../../shared/widgets/primitives/app_sheet.dart';
import '../../../lists/domain/list_text_rules.dart' show normalizeListText;
import '../../domain/beacon_text_rules.dart';
import '../../domain/beacons_feature_flag.dart';

/// The line under the title when the note is required.
const kJoinNoteRequiredLine = 'Add a note so the organiser knows who you are';

/// Asks for the note of a join request (0-140 code points, one line).
/// Answers the normalised note, or null when dismissed. A bottom sheet, or a
/// dialog on the tablet layout (600-1199 dp).
///
/// The note is optional, unless [noteRequired] (`beacon_quick_join` is on and
/// the organiser does not follow the caller): then "Send request" waits for a
/// note with text in it.
Future<String?> showJoinNoteSheet(
  BuildContext context, {
  required String title,
  bool noteRequired = false,
}) => showAppSheet<String>(
  context: context,
  material: const MaterialSheetOptions(
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    // Over the phone shell's floating bar, not under it.
    useRootNavigator: true,
  ),
  tabletScrollable: true,
  builder: (context) => JoinNoteSheet(title: title, noteRequired: noteRequired),
);

class JoinNoteSheet extends StatefulWidget {
  const JoinNoteSheet({
    super.key,
    required this.title,
    this.noteRequired = false,
  });

  /// The plan's title, shown under the heading.
  final String title;

  /// Submit needs a note with non-whitespace text.
  final bool noteRequired;

  @override
  State<JoinNoteSheet> createState() => _JoinNoteSheetState();
}

class _JoinNoteSheetState extends State<JoinNoteSheet> {
  final _note = TextEditingController();

  @override
  void initState() {
    super.initState();
    _note.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final issue = beaconNoteIssue(_note.text);
    final missing =
        widget.noteRequired && normalizeListText(_note.text).isEmpty;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.md,
        0,
        AppSpacing.md,
        AppSpacing.md + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text('Ask to join', style: theme.textTheme.titleLarge),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            widget.title,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _note,
            autofocus: true,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: widget.noteRequired ? 'Note' : 'Note (optional)',
              helperText: widget.noteRequired
                  ? kJoinNoteRequiredLine
                  : 'The organiser sees it with your request.',
              errorText: beaconFieldError(issue, max: kBeaconNoteMaxLength),
              counter: CharacterCounter(
                remaining: kBeaconNoteMaxLength - beaconTextLength(_note.text),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          FilledButton(
            onPressed: issue == null && !missing
                ? () => Navigator.of(context).pop(normalizeListText(_note.text))
                : null,
            child: const Text('Send request'),
          ),
        ],
      ),
    );
  }
}
