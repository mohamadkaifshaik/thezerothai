import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../shared/widgets/primitives/app_back_header.dart';
import '../../../shared/widgets/primitives/app_empty_view.dart';
import '../../../shared/widgets/primitives/app_main_column.dart';
import '../../../shared/widgets/user/user_list_skeleton.dart';
import '../../../gen/dzeroth/lists/v1/lists.pb.dart' as pb;
import '../data/home_tabs_repository.dart';
import '../data/lists_repository.dart';
import '../domain/home_tab_entry.dart';
import '../domain/lists_feature_flag.dart';
import 'bloc/lists_cubit.dart';
import 'bloc/lists_state.dart';
import 'widgets/list_editor_sheet.dart';
import 'widgets/list_row.dart';
import 'widgets/lists_page_chrome.dart';
import '../../../core/widgets/shell_bottom_inset_sliver.dart';

/// `/lists`: the Lists the viewer pinned to Home ("Pinned", with a Manage
/// link to Manage pinned), then "Your Lists" with a Create button, one row
/// per list and an Edit button per row. The same page at every width; the
/// phone and the wide mocks differ in gutters, tiles and the chevron.
///
/// - A List that is pinned shows under "Pinned" only (the Home tabs, live
///   from [HomeTabsRepository]); one whose header this session has not seen
///   is left out there (Manage pinned lists every tab).
/// - The wide header carries the viewer's @handle (from the owner of the
///   Lists); a phone has Back.
/// - 1 `ListUserLists` per open; Create / Edit / Delete are one RPC each, in
///   the editor ([showListEditor]).
/// - Create is disabled at 20 lists, with the reason as its tooltip.
/// - Tapping a row opens `/lists/:id` (the list detail).
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
  late final HomeTabsRepository _tabs = context.read<HomeTabsRepository>();
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
              final phone = isListsPhone(context);
              // Every one of the viewer's own Lists carries the viewer as its
              // owner, so the handle needs no profile of its own.
              final handle = state.lists.firstOrNull?.owner.handle;
              return Column(
                children: [
                  AppBackHeader(
                    title: 'Lists',
                    titleContent: ListsHeaderTitle(
                      title: 'Lists',
                      subtitle: phone || handle == null || handle.isEmpty
                          ? null
                          : '@$handle',
                    ),
                    onBack: _back,
                    // A rail destination on the wide layouts: nothing to go
                    // back to (the mocks have no Back there).
                    leading: phone
                        ? null
                        : const SizedBox(width: AppSpacing.sm),
                    actions: [
                      if (state.status == ListsStatus.ready)
                        ListsRaisedIconButton(
                          tooltip: atCap
                              ? 'You have $kMaxListsPerUser Lists, the most '
                                    'allowed. Delete one to create another.'
                              : 'Create a new List',
                          icon: Icons.playlist_add,
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
        final style = listsPageRowStyle(context);
        return StreamBuilder<List<HomeTabEntry>>(
          initialData: _tabs.tabs,
          stream: _tabs.changes,
          builder: (context, tabs) {
            final pinned = _pinned(lists, tabs.data ?? const []);
            final pinnedIds = {for (final l in pinned) l.listId};
            final rest = [
              for (final l in lists)
                if (!pinnedIds.contains(l.listId)) l,
            ];
            Widget row(pb.ListInfo list) => ListRow(
              key: ValueKey(list.listId),
              list: list,
              style: style,
              pinned: pinnedIds.contains(list.listId),
              onTap: () => context.push(AppRouter.listPath(list.listId)),
              onEdit: lists.any((l) => l.listId == list.listId)
                  ? () => _openEditor(list)
                  : null,
            );
            return RefreshIndicator(
              onRefresh: _cubit.load,
              child: CustomScrollView(
                slivers: [
                  if (pinned.isNotEmpty) ...[
                    SliverToBoxAdapter(
                      child: ListsSectionHeader(
                        title: 'Pinned',
                        actionLabel: 'Manage',
                        onAction: () => context.push(AppRouter.pinnedPath),
                      ),
                    ),
                    SliverList.builder(
                      itemCount: pinned.length,
                      itemBuilder: (context, i) => row(pinned[i]),
                    ),
                  ],
                  if (lists.isEmpty)
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: _EmptyLists(),
                    )
                  else if (rest.isNotEmpty) ...[
                    const SliverToBoxAdapter(
                      child: ListsSectionHeader(title: 'Your Lists'),
                    ),
                    SliverList.builder(
                      itemCount: rest.length,
                      itemBuilder: (context, i) => row(rest[i]),
                    ),
                  ],
                  const ShellBottomInsetSliver(),
                ],
              ),
            );
          },
        );
    }
  }

  /// The List tabs of Home, in their order, as the Lists this page knows:
  /// the viewer's own, else a header seen this session. A tab with neither
  /// is left out.
  List<pb.ListInfo> _pinned(List<pb.ListInfo> own, List<HomeTabEntry> tabs) => [
    for (final tab in tabs)
      if (tab.kind == HomeTabKind.list)
        ?(own.where((l) => l.listId == tab.id).firstOrNull ??
            _repository.header(tab.id)),
  ];
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
