import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_error_view.dart';
import '../../../../shared/widgets/app_empty_view.dart';
import '../../../../shared/widgets/user_list_skeleton.dart';
import '../../data/lists_repository.dart';
import '../bloc/add_to_lists_cubit.dart';
import 'list_row.dart';

/// What the sheet closed with: [done] or [createList] (the empty state's
/// button: the caller opens `/lists`).
enum AddToListsResult { done, createList }

/// Opens "Add to Lists" for the person [userId] (W5-13): your lists with a
/// checkbox each, checked when they are in it. A bottom sheet, at most 600dp
/// wide. 1 `ListUserLists` on open, one Add or Remove per toggle (optimistic,
/// rolled back with the reason). Resolves with how it was closed.
Future<AddToListsResult?> showAddToListsSheet(
  BuildContext context, {
  required ListsRepository repository,
  required String userId,
  required String handle,
}) {
  return showModalBottomSheet<AddToListsResult>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: AppBreakpoints.mobile),
    builder: (_) => BlocProvider(
      create: (_) =>
          AddToListsCubit(repository: repository, userId: userId)..load(),
      child: AddToListsSheet(handle: handle),
    ),
  );
}

/// The content of [showAddToListsSheet].
class AddToListsSheet extends StatelessWidget {
  const AddToListsSheet({super.key, required this.handle});

  final String handle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxHeight = MediaQuery.sizeOf(context).height * 0.8;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.only(
              start: AppSpacing.md,
              end: AppSpacing.xs,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      'Add or remove @$handle',
                      style: theme.textTheme.titleLarge,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () =>
                      Navigator.of(context).pop(AddToListsResult.done),
                  child: const Text('Done'),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          const Divider(height: 1),
          BlocSelector<AddToListsCubit, AddToListsState, String?>(
            selector: (s) => s.notice,
            builder: (context, notice) => notice == null
                ? const SizedBox.shrink()
                : Semantics(
                    liveRegion: true,
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      child: Text(
                        notice,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                  ),
          ),
          Flexible(
            child: BlocBuilder<AddToListsCubit, AddToListsState>(
              builder: (context, state) => _body(context, state),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(BuildContext context, AddToListsState state) {
    final cubit = context.read<AddToListsCubit>();
    switch (state.status) {
      case AddToListsStatus.loading:
        return const UserListSkeleton(
          rows: 4,
          semanticsLabel: 'Loading your Lists',
        );
      case AddToListsStatus.error:
        final error = state.error;
        if (error is FeatureDisabledException) {
          return const AppEmptyView(
            icon: Icons.list_alt_outlined,
            title: "Lists aren't available right now",
            subtitle: 'Please try again in a little while.',
          );
        }
        return AppErrorView(
          error: error ?? const UnknownApiException('Failed to load'),
          onRetry: cubit.load,
        );
      case AddToListsStatus.ready:
        if (state.lists.isEmpty) {
          return AppEmptyView(
            icon: Icons.list_alt_outlined,
            title: 'No Lists yet',
            subtitle: 'Create a List first, then add people to it.',
            action: FilledButton(
              onPressed: () =>
                  Navigator.of(context).pop(AddToListsResult.createList),
              child: const Text('Create a List'),
            ),
          );
        }
        return ListView.builder(
          // At most 20 rows (the per-owner cap) in a height-capped sheet.
          shrinkWrap: true,
          itemCount: state.lists.length,
          itemBuilder: (context, i) {
            final list = state.lists[i];
            final checked = state.memberOf.contains(list.listId);
            final busy = state.pending.contains(list.listId);
            return ListRow(
              key: ValueKey(list.listId),
              list: list,
              checked: checked,
              enabled: !busy,
              onTap: busy ? null : () => cubit.toggle(list.listId),
              checkTrailing: _RowBox(checked: checked, busy: busy),
            );
          },
        );
    }
  }
}

/// The box at the end of a row: a spinner while that row's call is in flight.
/// Decorative for the screen reader (the row itself is the checkbox).
class _RowBox extends StatelessWidget {
  const _RowBox({required this.checked, required this.busy});

  final bool checked;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: AppSpacing.minTapTarget,
      height: AppSpacing.minTapTarget,
      child: Center(
        child: busy
            ? const SizedBox(
                width: AppIconSize.md,
                height: AppIconSize.md,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : ExcludeSemantics(
                child: IgnorePointer(
                  child: Checkbox(value: checked, onChanged: (_) {}),
                ),
              ),
      ),
    );
  }
}
