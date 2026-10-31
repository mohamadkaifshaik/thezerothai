import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../shared/widgets/app_back_header.dart';
import '../../../shared/widgets/app_empty_view.dart';
import '../../../shared/widgets/app_main_column.dart';
import '../../../shared/widgets/app_section_header.dart';
import '../../../shared/widgets/user_list_skeleton.dart';
import '../../../gen/dzeroth/lists/v1/lists.pb.dart' as pb;
import '../data/lists_repository.dart';
import '../domain/lists_feature_flag.dart';
import 'bloc/lists_cubit.dart';
import 'bloc/lists_state.dart';
import 'widgets/list_editor_sheet.dart';
import 'widgets/list_row.dart';

/// `/lists` (W5-11): "Your Lists" with a Create button, one row per list and
/// an Edit button per row.
///
/// - 1 `ListUserLists` per open; Create / Edit / Delete are one RPC each, in
///   the editor ([showListEditor]).
/// - Create is disabled at 20 lists, with the reason as its tooltip.
/// - Tapping a row opens `/lists/:id` (the list detail, W5-12).
/// - The `lists` flag gates the route (the router redirects Home) and every
///   entry point; FEATURE_DISABLED or UNIMPLEMENTED shows the calm
///   "not available yet" state.
/// - Not built (founder F10): the search pill and "Discover new Lists".
class ListsScreen extends StatefulWidget {
  const ListsScreen({super.key});

  @override
  State<ListsScreen> createState() => _ListsScreenState();
}

class _ListsScreenState extends State<ListsScreen> {
  late final ListsRepository _repository = context.read<ListsRepository>();
  late final ListsCubit _cubit = ListsCubit(repository: _repository)..load();

  @override
  void dispose() {
    _cubit.close();
    super.dispose();
  }

  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRouter.homePath);
    }
  }

  Future<void> _openEditor([pb.ListInfo? existing]) async {
    final outcome = await showListEditor(
      context,
      repository: _repository,
      existing: existing,
    );
    if (outcome == null) return;
    final saved = outcome.list;
    if (saved != null) {
      existing == null ? _cubit.created(saved) : _cubit.updated(saved);
    } else if (outcome.deletedId != null) {
      _cubit.deleted(outcome.deletedId!);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: AppMainColumn(
          child: BlocBuilder<ListsCubit, ListsState>(
            bloc: _cubit,
            builder: (context, state) {
              final atCap = state.atCap;
              final canCreate = state.status == ListsStatus.ready && !atCap;
              return Column(
                children: [
                  AppBackHeader(
                    title: 'Lists',
                    onBack: _back,
                    actions: [
                      if (state.status == ListsStatus.ready)
                        IconButton(
                          tooltip: atCap
                              ? 'You have $kMaxListsPerUser Lists, the most '
                                    'allowed. Delete one to create another.'
                              : 'Create a new List',
                          icon: const Icon(Icons.playlist_add),
                          onPressed: canCreate ? () => _openEditor() : null,
                        ),
                    ],
                  ),
                  Expanded(child: _body(context, state)),
                ],
              );
            },
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
        return RefreshIndicator(
          onRefresh: _cubit.load,
          child: CustomScrollView(
            slivers: [
              const SliverToBoxAdapter(
                child: AppSectionHeader(title: 'Your Lists'),
              ),
              if (lists.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: _EmptyLists(),
                )
              else
                SliverList.builder(
                  itemCount: lists.length,
                  itemBuilder: (context, i) {
                    final list = lists[i];
                    return ListRow(
                      key: ValueKey(list.listId),
                      list: list,
                      onTap: () =>
                          context.push(AppRouter.listPath(list.listId)),
                      onEdit: () => _openEditor(list),
                    );
                  },
                ),
            ],
          ),
        );
    }
  }
}

class _EmptyLists extends StatelessWidget {
  const _EmptyLists();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Center(
        child: Text(
          "You haven't created any Lists yet. Make one to follow a group of "
          'people in its own timeline.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
