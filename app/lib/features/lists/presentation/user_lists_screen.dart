import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../shared/widgets/app_back_header.dart';
import '../../../shared/widgets/app_empty_view.dart';
import '../../../shared/widgets/app_main_column.dart';
import '../../../shared/widgets/app_section_header.dart';
import '../../../shared/widgets/user_list_skeleton.dart';
import '../data/lists_repository.dart';
import 'bloc/lists_cubit.dart';
import 'bloc/lists_state.dart';
import 'widgets/list_row.dart';

/// `/u/:userId/lists` (W5-13): another person's public Lists. 1 `ListUserLists`
/// per open. A row opens the list (`/lists/:id`, W5-12). The `lists` flag gates
/// the route. A person who is hidden from you (private, blocked, gone) answers
/// NOT_FOUND, shown as one fixed text that hints at no cause.
class UserListsScreen extends StatefulWidget {
  const UserListsScreen({super.key, required this.userId, this.handle});

  final String userId;

  /// For the header only (`@handle`); null when the link carried none.
  final String? handle;

  @override
  State<UserListsScreen> createState() => _UserListsScreenState();
}

class _UserListsScreenState extends State<UserListsScreen> {
  late final ListsCubit _cubit = ListsCubit(
    repository: context.read<ListsRepository>(),
    ownerId: widget.userId,
  )..load();

  @override
  void dispose() {
    _cubit.close();
    super.dispose();
  }

  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRouter.profileByIdPath(widget.userId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final handle = widget.handle;
    return Scaffold(
      body: SafeArea(
        child: AppMainColumn(
          child: Column(
            children: [
              AppBackHeader(
                title: handle == null || handle.isEmpty
                    ? 'Lists'
                    : "@$handle's Lists",
                onBack: _back,
              ),
              Expanded(
                child: BlocBuilder<ListsCubit, ListsState>(
                  bloc: _cubit,
                  builder: _body,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, ListsState state) {
    switch (state.status) {
      case ListsStatus.loading:
        return const UserListSkeleton(semanticsLabel: 'Loading Lists');
      case ListsStatus.error:
        final error = state.error;
        if (error is FeatureDisabledException) {
          return const AppEmptyView(
            icon: Icons.list_alt_outlined,
            title: "Lists aren't available right now",
            subtitle: 'Please try again in a little while.',
          );
        }
        if (error is NotFoundException) {
          return const AppEmptyView(
            icon: Icons.list_alt_outlined,
            title: 'These Lists are unavailable',
            subtitle: "They can't be shown right now.",
          );
        }
        return Center(
          child: SingleChildScrollView(
            child: AppErrorView(
              error: error ?? const UnknownApiException('Failed to load'),
              onRetry: _cubit.load,
            ),
          ),
        );
      case ListsStatus.ready:
        final lists = state.lists;
        if (lists.isEmpty) {
          return const AppEmptyView(
            icon: Icons.list_alt_outlined,
            title: 'No public Lists',
            subtitle: "This person hasn't shared any Lists.",
          );
        }
        return RefreshIndicator(
          onRefresh: _cubit.load,
          child: CustomScrollView(
            slivers: [
              const SliverToBoxAdapter(child: AppSectionHeader(title: 'Lists')),
              SliverList.builder(
                itemCount: lists.length,
                itemBuilder: (context, i) {
                  final list = lists[i];
                  return ListRow(
                    key: ValueKey(list.listId),
                    list: list,
                    onTap: () => context.push(AppRouter.listPath(list.listId)),
                  );
                },
              ),
            ],
          ),
        );
    }
  }
}
