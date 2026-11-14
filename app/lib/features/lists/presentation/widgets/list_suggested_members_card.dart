import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../../../shared/widgets/primitives/app_pill_button.dart';
import '../../../../shared/widgets/primitives/app_surface.dart';
import '../../../graph/presentation/widgets/user_list_row.dart';
import '../../data/lists_repository.dart';
import '../bloc/list_suggestions_cubit.dart';
import '../lists_error_messages.dart';
import 'lists_page_chrome.dart';

/// How many people the card shows before "Show more".
const kListSuggestionsCollapsedRows = 3;

/// The "Suggested members" card on the members page of a List the viewer owns
/// (the `list_suggestions` flag and the owner check are the caller's). It owns
/// its [ListSuggestionsCubit]: one `ListSuggestedMembers` when it first
/// appears, and an Add button per person (one `AddListMember`). Shows nothing
/// while loading, when empty and when the call failed. [onAdded] receives the
/// person once they are on the List (the page puts them at the top of
/// Members). Errors of Add show a snackbar.
///
/// Mock gap: no mock draws it; it is the "Who to follow" card pattern (an
/// [AppSurface], the shared user row) at every width. It is capped at 45 % of
/// the window height and scrolls inside, so Members stays on screen.
class ListSuggestedMembersCard extends StatefulWidget {
  const ListSuggestedMembersCard({
    super.key,
    required this.listId,
    required this.onAdded,
  });

  final String listId;
  final ValueChanged<graph.UserListItem> onAdded;

  @override
  State<ListSuggestedMembersCard> createState() =>
      _ListSuggestedMembersCardState();
}

class _ListSuggestedMembersCardState extends State<ListSuggestedMembersCard> {
  late final ListSuggestionsCubit _cubit = ListSuggestionsCubit(
    repository: context.read<ListsRepository>(),
    listId: widget.listId,
  )..load();
  bool _expanded = false;

  @override
  void dispose() {
    _cubit.close();
    super.dispose();
  }

  Future<void> _add(String userId) async {
    final result = await _cubit.add(userId);
    if (!mounted) return;
    final item = result.item;
    if (result.added && item != null) {
      widget.onAdded(item);
      return;
    }
    final error = result.error;
    if (error != null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(listsErrorMessage(error))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final phone = isListsPhone(context);
    final gutter = phone
        ? AppListsLayout.phoneGutter
        : AppListsLayout.wideGutter;
    return BlocBuilder<ListSuggestionsCubit, ListSuggestionsState>(
      bloc: _cubit,
      builder: (context, state) {
        final items = state.items;
        if (state.status != ListSuggestionsStatus.ready || items.isEmpty) {
          return const SizedBox.shrink();
        }
        final collapsed =
            !_expanded && items.length > kListSuggestionsCollapsedRows;
        final shown = collapsed
            ? items.take(kListSuggestionsCollapsedRows).toList()
            : items;
        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.45,
          ),
          child: SingleChildScrollView(
            child: AppSurface(
              margin: EdgeInsets.fromLTRB(
                gutter,
                AppSpacing.sm,
                gutter,
                AppSpacing.sm,
              ),
              padding: EdgeInsets.zero,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.md,
                      AppSpacing.md,
                      AppSpacing.md,
                      AppSpacing.xs,
                    ),
                    child: Semantics(
                      header: true,
                      child: Text(
                        'Suggested members',
                        style: AppTextStyles.cardTitleFor(context),
                      ),
                    ),
                  ),
                  // A stable key per person, so a removed row hands nothing
                  // to the one that moved up.
                  for (var i = 0; i < shown.length; i++)
                    UserListRow(
                      key: ValueKey('suggested-${shown[i].user.userId}'),
                      item: shown[i],
                      showDivider: collapsed || i < shown.length - 1,
                      trailing: AddSuggestionButton(
                        handle: shown[i].user.handle,
                        busy: state.busyIds.contains(shown[i].user.userId),
                        onPressed: () => _add(shown[i].user.userId),
                      ),
                    ),
                  if (collapsed)
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton(
                        style: TextButton.styleFrom(
                          minimumSize: const Size(0, AppSpacing.minTapTarget),
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.md,
                          ),
                        ),
                        onPressed: () => setState(() => _expanded = true),
                        child: const Text('Show more'),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The Add pill of a suggested person; disabled while its call is in flight.
class AddSuggestionButton extends StatelessWidget {
  const AddSuggestionButton({
    super.key,
    required this.handle,
    required this.busy,
    required this.onPressed,
  });

  final String handle;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      button: true,
      enabled: !busy,
      label: 'Add @$handle to this List',
      excludeSemantics: true,
      onTap: busy ? null : onPressed,
      child: AppPillButton(
        label: 'Add',
        compact: true,
        variant: AppButtonVariant.primary,
        onPressed: busy ? null : onPressed,
      ),
    );
  }
}
