import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../shared/widgets/app_back_header.dart';
import '../../../shared/widgets/app_main_column.dart';
import '../../../shared/widgets/app_section_header.dart';
import '../../../shared/widgets/app_tile_icon.dart';
import '../../../gen/dzeroth/lists/v1/lists.pb.dart' as pb;
import '../data/home_tabs_repository.dart';
import '../data/lists_repository.dart';
import '../domain/home_tab_entry.dart';
import '../domain/lists_feature_flag.dart';
import 'bloc/home_tabs_cubit.dart';
import 'bloc/home_tabs_state.dart';
import 'bloc/lists_cubit.dart';
import 'bloc/lists_state.dart';
import 'lists_error_messages.dart';
import 'widgets/list_row.dart';

/// `/home/pinned` (W5-14): Manage pinned timelines. Following is fixed on
/// top; under it the pinned tabs, each with a drag handle, "Move up" / "Move
/// down" actions (for screen readers and keyboards) and Unpin; then "Add from
/// your Lists" with a Pin button per List that is not pinned yet.
///
/// - 1 `ListUserLists` per open; every change is one optimistic
///   `SetHomeTabs` through [HomeTabsRepository] (a reorder is one call),
///   rolled back with a message on failure.
/// - At five tabs Pin is disabled, with the reason as its tooltip and a note.
/// - Communities are not offered yet (they arrive with W5-30).
class ManagePinnedScreen extends StatefulWidget {
  const ManagePinnedScreen({super.key});

  @override
  State<ManagePinnedScreen> createState() => _ManagePinnedScreenState();
}

class _ManagePinnedScreenState extends State<ManagePinnedScreen> {
  late final ListsRepository _lists = context.read<ListsRepository>();
  late final HomeTabsCubit _tabs = HomeTabsCubit(
    tabs: context.read<HomeTabsRepository>(),
    lists: _lists,
  );
  late final ListsCubit _own = ListsCubit(repository: _lists)..load();

  @override
  void dispose() {
    _tabs.close();
    _own.close();
    super.dispose();
  }

  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRouter.homePath);
    }
  }

  Future<void> _report(Future<AppException?> action) async {
    final error = await action;
    if (error == null || !mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(listsErrorMessage(error))));
  }

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider<HomeTabsCubit>.value(value: _tabs),
        BlocProvider<ListsCubit>.value(value: _own),
      ],
      child: Scaffold(
        body: SafeArea(
          child: AppMainColumn(
            child: Column(
              children: [
                AppBackHeader(title: 'Manage pinned', onBack: _back),
                Expanded(
                  child: BlocBuilder<HomeTabsCubit, HomeTabsState>(
                    builder: (context, tabs) =>
                        BlocBuilder<ListsCubit, ListsState>(
                          builder: (context, own) => _body(tabs, own),
                        ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(HomeTabsState tabs, ListsState own) {
    final pinnedIds = {
      for (final t in tabs.tabs)
        if (t.kind == HomeTabKind.list) t.id,
    };
    final addable = [
      for (final l in own.lists)
        if (!pinnedIds.contains(l.listId)) l,
    ];
    final canPin = !tabs.isFull && !tabs.writeUnavailable;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return CustomScrollView(
      slivers: [
        const SliverToBoxAdapter(
          child: AppSectionHeader(
            title: 'Pinned',
            subtitle: 'Following is always first. Drag to reorder.',
          ),
        ),
        const SliverToBoxAdapter(child: _FollowingRow()),
        if (tabs.tabs.isEmpty)
          SliverToBoxAdapter(
            child: _Note(
              "Nothing pinned yet. Pin a List below to give it a tab on Home.",
              style: muted,
            ),
          )
        else
          SliverReorderableList(
            itemCount: tabs.tabs.length,
            // onReorderItem gives the index after the removal; the cubit takes the
            // one before it (ReorderableListView.onReorder).
            onReorderItem: (from, to) =>
                _report(_tabs.reorder(from, to > from ? to + 1 : to)),
            itemBuilder: (context, i) {
              final tab = tabs.tabs[i];
              final label = tabs.labelOf(tab);
              return _PinnedRow(
                key: ValueKey(tab.key),
                index: i,
                last: i == tabs.tabs.length - 1,
                label: label,
                onUnpin: () => _report(_tabs.unpin(tab)),
                onMove: (delta) =>
                    _report(_tabs.reorder(i, delta > 0 ? i + 2 : i - 1)),
              );
            },
          ),
        if (tabs.writeUnavailable)
          SliverToBoxAdapter(
            child: _Note(
              "Pinning isn't available yet. Please try again later.",
              style: muted,
            ),
          )
        else if (tabs.isFull)
          SliverToBoxAdapter(
            child: _Note(
              'You have $kMaxPinnedHomeTabs pinned timelines, the most '
              'allowed. Unpin one to add another.',
              style: muted,
            ),
          ),
        const SliverToBoxAdapter(
          child: AppSectionHeader(title: 'Add from your Lists'),
        ),
        ..._addSlivers(own, addable, canPin, muted),
        const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.xl)),
      ],
    );
  }

  List<Widget> _addSlivers(
    ListsState own,
    List<pb.ListInfo> addable,
    bool canPin,
    TextStyle? muted,
  ) {
    switch (own.status) {
      case ListsStatus.loading:
        return [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Center(
                child: Semantics(
                  label: 'Loading your Lists',
                  child: const SizedBox.square(
                    dimension: AppSpacing.lg,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
            ),
          ),
        ];
      case ListsStatus.error:
        final error = own.error;
        return [
          SliverToBoxAdapter(
            child: error is FeatureDisabledException
                ? _Note("Lists aren't available right now.", style: muted)
                : AppErrorView(
                    error: error ?? const UnknownApiException('Failed to load'),
                    onRetry: _own.load,
                  ),
          ),
        ];
      case ListsStatus.ready:
        if (addable.isEmpty) {
          return [
            SliverToBoxAdapter(
              child: _Note(
                own.lists.isEmpty
                    ? "You haven't created any Lists yet. Make one on the "
                          'Lists screen, then pin it here.'
                    : 'All your Lists are pinned.',
                style: muted,
              ),
            ),
          ];
        }
        return [
          SliverList.builder(
            itemCount: addable.length,
            itemBuilder: (context, i) {
              final list = addable[i];
              return ListRow(
                key: ValueKey(list.listId),
                list: list,
                onTap: () => context.push(AppRouter.listPath(list.listId)),
                trailing: IconButton(
                  tooltip: canPin
                      ? 'Pin ${list.name} to Home'
                      : "Can't pin ${list.name}: Home is full",
                  constraints: const BoxConstraints(
                    minWidth: AppSpacing.minTapTarget,
                    minHeight: AppSpacing.minTapTarget,
                  ),
                  icon: const Icon(Icons.push_pin_outlined),
                  onPressed: canPin
                      ? () => _report(
                          _tabs.pin(HomeTabKind.list, list.listId, list.name),
                        )
                      : null,
                ),
              );
            },
          ),
        ];
    }
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text, {this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: AppSpacing.md,
      vertical: AppSpacing.smd,
    ),
    child: Text(text, style: style),
  );
}

/// Following: first and fixed, so no handle and no Unpin.
class _FollowingRow extends StatelessWidget {
  const _FollowingRow();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: 'Following, always first',
      excludeSemantics: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: AppSpacing.minTapTarget),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.smd,
          ),
          child: Row(
            children: [
              const AppTileIcon(icon: Icons.people_outline),
              const SizedBox(width: AppSpacing.smd),
              Expanded(
                child: Text('Following', style: theme.textTheme.titleMedium),
              ),
              Icon(
                Icons.lock_outline,
                size: AppIconSize.md,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One pinned tab: name, a drag handle and Unpin. The row exposes "Move up"
/// and "Move down" as semantic actions, so a reorder needs no drag.
class _PinnedRow extends StatelessWidget {
  const _PinnedRow({
    super.key,
    required this.index,
    required this.last,
    required this.label,
    required this.onUnpin,
    required this.onMove,
  });

  final int index;
  final bool last;
  final String label;
  final VoidCallback onUnpin;

  /// -1 up, +1 down.
  final ValueChanged<int> onMove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Semantics(
      container: true,
      label: label,
      customSemanticsActions: {
        if (index > 0)
          const CustomSemanticsAction(label: 'Move up'): () => onMove(-1),
        if (!last)
          const CustomSemanticsAction(label: 'Move down'): () => onMove(1),
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowUp, alt: true): () {
            if (index > 0) onMove(-1);
          },
          const SingleActivator(LogicalKeyboardKey.arrowDown, alt: true): () {
            if (!last) onMove(1);
          },
        },
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppSpacing.minTapTarget),
          child: Padding(
            padding: const EdgeInsets.only(left: AppSpacing.md),
            child: Row(
              children: [
                const AppTileIcon(icon: Icons.list_alt_outlined),
                const SizedBox(width: AppSpacing.smd),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: 'Unpin $label',
                  constraints: const BoxConstraints(
                    minWidth: AppSpacing.minTapTarget,
                    minHeight: AppSpacing.minTapTarget,
                  ),
                  icon: const Icon(Icons.push_pin),
                  onPressed: onUnpin,
                ),
                ReorderableDragStartListener(
                  index: index,
                  child: SizedBox.square(
                    dimension: AppSpacing.minTapTarget,
                    child: ExcludeSemantics(
                      child: Icon(Icons.drag_handle, color: muted),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
