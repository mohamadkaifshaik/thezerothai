import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../../shared/widgets/app_back_header.dart';
import '../../../shared/widgets/app_empty_view.dart';
import '../../../shared/widgets/app_main_column.dart';
import '../../graph/data/graph_repository.dart';
import '../../graph/presentation/bloc/user_list_cubit.dart';
import '../../graph/presentation/bloc/user_list_state.dart';
import '../../graph/presentation/widgets/paged_user_list.dart';
import '../../graph/presentation/widgets/user_list_row.dart';
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../data/lists_repository.dart';
import 'lists_error_messages.dart';
import 'widgets/list_unavailable_view.dart';

/// `/lists/:id/members` (W5-12): the people on a List, newest first, each
/// with a Follow button; the owner also gets Remove.
///
/// - 1 `ListListMembers` per page (20). A page can be short or empty while a
///   token is set, so the repository follows empty pages (up to 5) and the
///   list pages on scroll. A token older than 24 h restarts at page 1.
/// - Remove asks to confirm, then the row leaves at once and returns with a
///   message if the call fails; one idempotency key per member, reused on a
///   retry.
/// - NOT_FOUND shows the same "This List is unavailable" as the detail;
///   FEATURE_DISABLED / UNIMPLEMENTED shows "not available yet".
class ListMembersScreen extends StatefulWidget {
  const ListMembersScreen({super.key, required this.listId});

  final String listId;

  @override
  State<ListMembersScreen> createState() => _ListMembersScreenState();
}

class _ListMembersScreenState extends State<ListMembersScreen> {
  static const _uuid = Uuid();

  late final ListsRepository _lists = context.read<ListsRepository>();
  late final UserListCubit _cubit = UserListCubit(fetchPage: _fetch)
    ..loadFirstPage();
  final Map<String, String> _keys = {};

  Future<GraphPage> _fetch({
    required int pageSize,
    required String pageToken,
  }) async {
    final page = await _lists.listMembers(
      listId: widget.listId,
      pageSize: pageSize,
      pageToken: pageToken,
      maxEmptyPages: 5,
    );
    return GraphPage(items: page.users, nextPageToken: page.nextPageToken);
  }

  @override
  void dispose() {
    _cubit.close();
    super.dispose();
  }

  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRouter.listPath(widget.listId));
    }
  }

  void _say(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _remove(graph.UserListItem item) async {
    final handle = item.user.handle;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove @$handle?'),
        content: const Text('They will no longer be on this List.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final userId = item.user.userId;
    final removed = _cubit.removeUser(userId);
    if (removed == null) return;
    final (removedItem, index) = removed;
    final key = _keys[userId] ??= _uuid.v4();
    try {
      await _lists.removeMember(
        idempotencyKey: key,
        listId: widget.listId,
        userId: userId,
      );
      _keys.remove(userId);
      if (mounted) _say('Removed @$handle from this List.');
    } on AppException catch (e) {
      _cubit.restoreItem(removedItem, index);
      if (mounted) _say(listsErrorMessage(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final viewerUserId = context.select(
      (OnboardingBloc bloc) => bloc.state.profile?.userId,
    );
    // The owner is known from the header the detail screen already holds.
    final isOwner =
        viewerUserId != null &&
        _lists.header(widget.listId)?.owner.userId == viewerUserId;
    return Scaffold(
      body: SafeArea(
        child: AppMainColumn(
          child: Column(
            children: [
              AppBackHeader(title: 'Members', onBack: _back),
              Expanded(
                child: BlocBuilder<UserListCubit, UserListState>(
                  bloc: _cubit,
                  buildWhen: (a, b) =>
                      a.error.runtimeType != b.error.runtimeType,
                  builder: (context, state) {
                    final error = state.error;
                    if (error is NotFoundException) {
                      return const Center(
                        child: SingleChildScrollView(
                          child: ListUnavailableView(),
                        ),
                      );
                    }
                    if (error is FeatureDisabledException) {
                      return const Center(
                        child: SingleChildScrollView(
                          child: AppEmptyView(
                            icon: Icons.list_alt_outlined,
                            title: "Lists aren't available right now",
                            subtitle: 'Please try again in a little while.',
                          ),
                        ),
                      );
                    }
                    return PagedUserList(
                      cubit: _cubit,
                      emptyMessage: 'No one is on this List yet',
                      rowBuilder: (context, item) => UserListRow(
                        key: ValueKey(item.user.userId),
                        item: item,
                        extraAction: isOwner && item.user.userId != viewerUserId
                            ? _RemoveButton(
                                handle: item.user.handle,
                                onPressed: () => _remove(item),
                              )
                            : null,
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RemoveButton extends StatelessWidget {
  const _RemoveButton({required this.handle, required this.onPressed});

  final String handle;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Remove @$handle from this List',
      excludeSemantics: true,
      onTap: onPressed,
      child: OutlinedButton(
        style: kListOutlinedButtonStyle,
        onPressed: onPressed,
        child: const Text('Remove'),
      ),
    );
  }
}
