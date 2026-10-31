import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/lists/v1/lists.pb.dart' as pb;
import '../../../../shared/widgets/app_form_header.dart';
import '../../../../shared/widgets/character_counter.dart';
import '../../data/lists_repository.dart';
import '../../domain/lists_feature_flag.dart';
import '../bloc/list_editor_cubit.dart';

/// Opens the create / edit form of a List (W5-11): a full-screen page below
/// 600dp, a dialog from 600dp. Resolves with the [ListEditorOutcome] (saved or
/// deleted), or null when the user cancelled. Pass [existing] to edit.
///
/// The create flow is not captured from X (plan W5-11: UNKNOWN); the defaults
/// are X-like. Private is on by default (founder F3).
Future<ListEditorOutcome?> showListEditor(
  BuildContext context, {
  required ListsRepository repository,
  pb.ListInfo? existing,
}) {
  Widget body() => BlocProvider(
    create: (_) => ListEditorCubit(repository: repository, existing: existing),
    child: const ListEditorSheet(),
  );
  if (MediaQuery.sizeOf(context).width < AppBreakpoints.mobile) {
    return Navigator.of(context, rootNavigator: true).push<ListEditorOutcome>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => Scaffold(body: SafeArea(child: body())),
      ),
    );
  }
  return showDialog<ListEditorOutcome>(
    context: context,
    builder: (_) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: body(),
      ),
    ),
  );
}

/// The form itself: name (25) and description (100) with counters, a Private
/// switch, Save, and (editing) Delete with a confirm.
class ListEditorSheet extends StatefulWidget {
  const ListEditorSheet({super.key});

  @override
  State<ListEditorSheet> createState() => _ListEditorSheetState();
}

class _ListEditorSheetState extends State<ListEditorSheet> {
  late final ListEditorCubit _cubit = context.read<ListEditorCubit>();
  late final _name = TextEditingController(text: _cubit.existing?.name ?? '');
  late final _description = TextEditingController(
    text: _cubit.existing?.description ?? '',
  );
  late bool _private = _cubit.existing?.isPrivate ?? true;

  @override
  void initState() {
    super.initState();
    _name.addListener(_changed);
    _description.addListener(_changed);
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  void _changed() => setState(() {});

  bool get _canSave {
    final name = _name.text.trim();
    if (name.isEmpty) return false;
    final before = _cubit.existing;
    if (before == null) return true;
    return name != before.name ||
        _description.text.trim() != before.description ||
        _private != before.isPrivate;
  }

  void _save() => _cubit.save(
    name: _name.text.trim(),
    description: _description.text.trim(),
    isPrivate: _private,
  );

  Future<void> _confirmDelete() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this List?'),
        content: const Text(
          'Its members are removed and it leaves your Home timelines. '
          "This can't be undone.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (yes == true) _cubit.delete();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final editing = _cubit.existing != null;
    return BlocConsumer<ListEditorCubit, ListEditorState>(
      listenWhen: (a, b) => a.outcome != b.outcome && b.outcome != null,
      listener: (context, state) => Navigator.of(context).pop(state.outcome),
      builder: (context, state) {
        final busy = state.busy;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppFormHeader(
              title: editing ? 'Edit List' : 'Create a List',
              actionLabel: 'Save',
              busy: busy,
              busySemanticsLabel: 'Saving',
              onCancel: () => Navigator.of(context).pop(),
              onAction: _canSave && !busy ? _save : null,
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _name,
                      enabled: !busy,
                      maxLength: kListNameMaxLength,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(labelText: 'Name'),
                      buildCounter: _counter(kListNameMaxLength),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    TextField(
                      controller: _description,
                      enabled: !busy,
                      maxLength: kListDescriptionMaxLength,
                      minLines: 2,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        labelText: 'Description',
                      ),
                      buildCounter: _counter(kListDescriptionMaxLength),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    MergeSemantics(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          minHeight: AppSpacing.minTapTarget,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Private',
                                    style: theme.textTheme.titleMedium,
                                  ),
                                  Text(
                                    _private
                                        ? 'Only you can see this List.'
                                        : 'Anyone can see this List and who '
                                              'is in it.',
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            Switch(
                              value: _private,
                              onChanged: busy
                                  ? null
                                  : (v) => setState(() => _private = v),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (state.error != null) ...[
                      const SizedBox(height: AppSpacing.md),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          state.error!,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ),
                    ],
                    if (editing) ...[
                      const SizedBox(height: AppSpacing.lg),
                      TextButton(
                        onPressed: busy ? null : _confirmDelete,
                        style: TextButton.styleFrom(
                          foregroundColor: theme.colorScheme.error,
                          minimumSize: const Size.fromHeight(
                            AppSpacing.minTapTarget,
                          ),
                        ),
                        child: const Text('Delete List'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  InputCounterWidgetBuilder _counter(int max) =>
      (context, {required currentLength, required isFocused, maxLength}) =>
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: CharacterCounter(remaining: max - currentLength),
          );
}
