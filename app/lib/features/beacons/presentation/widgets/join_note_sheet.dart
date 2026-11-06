import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/primitives/character_counter.dart';
import '../../../lists/domain/list_text_rules.dart' show normalizeListText;
import '../../domain/beacon_text_rules.dart';
import '../../domain/beacons_feature_flag.dart';

/// Asks for the optional note of a join request (0-140 code points, one
/// line). Answers the normalised note, or null when dismissed.
Future<String?> showJoinNoteSheet(
  BuildContext context, {
  required String title,
}) => showModalBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  useSafeArea: true,
  builder: (context) => JoinNoteSheet(title: title),
);

class JoinNoteSheet extends StatefulWidget {
  const JoinNoteSheet({super.key, required this.title});

  /// The plan's title, shown under the heading.
  final String title;

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
              labelText: 'Note (optional)',
              helperText: 'The organiser sees it with your request.',
              errorText: beaconFieldError(issue, max: kBeaconNoteMaxLength),
              counter: CharacterCounter(
                remaining: kBeaconNoteMaxLength - beaconTextLength(_note.text),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          FilledButton(
            onPressed: issue == null
                ? () => Navigator.of(context).pop(normalizeListText(_note.text))
                : null,
            child: const Text('Send request'),
          ),
        ],
      ),
    );
  }
}
