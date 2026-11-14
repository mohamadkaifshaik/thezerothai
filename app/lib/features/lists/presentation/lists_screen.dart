import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/feature_flags/feature_flags.dart';
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
import 'bloc/list_feed_cubit.dart';
import 'bloc/list_feed_state.dart';
import 'bloc/lists_cubit.dart';
import 'bloc/lists_state.dart';
import 'widgets/list_editor_sheet.dart';
import 'widgets/list_row.dart';
import 'widgets/lists_page_chrome.dart';
import '../../../core/widgets/shell_bottom_inset_sliver.dart';
import '../../../core/widgets/shell_fab.dart';

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
/// - Not built (founder F10): the search pill.
/// - With `list_follows`: a "Discover lists" entry (opens `/lists/discover`)
///   and "Lists you follow" (`ListFollowedLists`, pages of 20 behind "Show
///   more") below the viewer's own Lists; the section is hidden when it is
///   empty, and a failure there never touches the page's own state.
class ListsScreen extends StatefulWidget {
  const ListsScreen({super.key});

  @override
  State<ListsScreen> createState() => _ListsScreenState();
}

class _ListsScreenState extends State<ListsScreen> {
  late final ListsRepository _repository = context.read<ListsRepository>();
  late final HomeTabsRepository _tabs = context.read<HomeTabsRepository>();
  late final ListsCubit _cubit = ListsCubit(repository: _repository)..load();

  /// Created on the first build with `list_follows` on, never before.
  ListFeedCubit? _followed;

  ListFeedCubit _followedCubit() => _followed ??= ListFeedCubit(
    repository: _repository,
    unfollowedLeavesFeed: true,
    fetch: (token) => _repository.listFollowedLists(
      pageSize: kListFollowsPageSize,
      pageToken: token,
    ),
  )..load();

  Future<void> _openList(String listId) async {
    await context.push(AppRouter.listPath(listId));
    // The viewer may have followed or unfollowed it over there.
    if (mounted) _followed?.load();
  }

  @override
  void dispose() {
    _cubit.close();
    _followed?.close();
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
    final followsOn = isFeatureEnabled(context, kFeatureListFollows);
    return Scaffold(
      body: SafeArea(
        // The floating bar overlays the page: the scroll view runs behind it
        // and ends with the bar's inset (ShellBottomInsetSliver).
        bottom: false,
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
              return ShellFab(
                // The phone's floating button creates a List.
                action: canCreate
                    ? ShellFabAction(
                        tooltip: 'Create a new List',
                        icon: Icons.playlist_add,
                        onPressed: _openEditor,
                      )
                    : null,
                child: Column(
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
                        // A phone: the floating button creates instead.
                        if (state.status == ListsStatus.ready &&
                            !shellFabCovers(context))
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
                    Expanded(child: _body(context, state, followsOn)),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, ListsState state, bool followsOn) {
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
                    followsOn
                        ? const SliverToBoxAdapter(child: _EmptyLists())
                        : const SliverFillRemaining(
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
                  if (followsOn) ..._followSlivers(context, style),
                  const ShellBottomInsetSliver(),
                ],
              ),
            );
          },
        );
    }
  }

  /// "Discover lists" and "Lists you follow" (the `list_follows` flag is on).
  List<Widget> _followSlivers(BuildContext context, ListRowStyle style) {
    return [
      SliverToBoxAdapter(
        child: _DiscoverEntry(
          style: style,
          onTap: () => context.push(AppRouter.discoverListsPath),
        ),
      ),
      BlocBuilder<ListFeedCubit, ListFeedState>(
        bloc: _followedCubit(),
        builder: (context, followed) {
          // Loading, failed or empty: no section (and no error on the page).
          if (followed.status != ListFeedStatus.ready ||
              followed.lists.isEmpty) {
            return const SliverToBoxAdapter(child: SizedBox.shrink());
          }
          return SliverMainAxisGroup(
            slivers: [
              const SliverToBoxAdapter(
                child: ListsSectionHeader(title: 'Lists you follow'),
              ),
              SliverList.builder(
                itemCount: followed.lists.length,
                itemBuilder: (context, i) {
                  final list = followed.lists[i];
                  return ListRow(
                    key: ValueKey('followed-${list.listId}'),
                    list: list,
                    style: style,
                    followers: true,
                    onTap: () => _openList(list.listId),
                  );
                },
              ),
              if (followed.hasMore || followed.loadMoreFailed)
                SliverToBoxAdapter(
                  child: Center(
                    child: TextButton(
                      onPressed: followed.loadingMore
                          ? null
                          : _followedCubit().loadMore,
                      child: Text(
                        followed.loadMoreFailed
                            ? "Couldn't load more. Retry"
                            : 'Show more',
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    ];
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

/// The "Discover lists" row (the Lists page's entry to `/lists/discover`):
/// the page row look of the width, a teal-tinted tile and a chevron.
class _DiscoverEntry extends StatelessWidget {
  const _DiscoverEntry({required this.style, required this.onTap});

  final ListRowStyle style;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final wide = style == ListRowStyle.wide;
    final gutter = wide
        ? AppListsLayout.wideGutter
        : AppListsLayout.phoneGutter;
    final muted = theme.colorScheme.onSurfaceVariant;
    return Semantics(
      button: true,
      label: 'Discover lists',
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppSpacing.minTapTarget),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: gutter,
              vertical: wide
                  ? AppListsLayout.wideRowPaddingV
                  : AppListsLayout.phoneRowPaddingV,
            ),
            child: Row(
              children: [
                const ListTileIcon(navy: false, icon: Icons.explore_outlined),
                SizedBox(
                  width: wide
                      ? AppListsLayout.wideRowGap
                      : AppListsLayout.phoneRowGap,
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Discover lists',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: wide
                            ? theme.textTheme.titleSmall
                            : theme.textTheme.titleMedium,
                      ),
                      Text(
                        'Public Lists, most followed first',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: muted,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: muted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
