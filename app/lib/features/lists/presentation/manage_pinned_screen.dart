import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../core/widgets/shell_bottom_inset_sliver.dart';
import '../../../gen/dzeroth/lists/v1/lists.pb.dart' as pb;
import '../../../shared/widgets/primitives/app_back_header.dart';
import '../../../shared/widgets/primitives/app_card.dart';
import '../../../shared/widgets/primitives/app_main_column.dart';
import '../../../shared/widgets/primitives/app_pill_button.dart';
import '../../../shared/widgets/primitives/app_tile_icon.dart';
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
import 'widgets/lists_page_chrome.dart';

/// `/home/pinned`: Manage pinned timelines. Following is fixed on
/// top; under it the pinned tabs, each with a drag handle, "Move up" / "Move
/// down" actions (for screen readers and keyboards) and Unpin; then "Add from
/// your Lists" with a Pin button per List that is not pinned yet. Done (and
/// Back) leave the page: every change is already saved.
///
/// - 1 `ListUserLists` per open; every change is one optimistic
///   `SetHomeTabs` through [HomeTabsRepository] (a reorder is one call),
///   rolled back with a message on failure.
/// - At five tabs Pin is disabled, with the reason as its tooltip and a note.
/// - Communities are not offered yet (they arrive later), and the mocks'
///   "Nearby" tab is not built (no such Home tab).
/// - The phone draws the pinned tabs as raised cards and a Pin icon per List;
///   the wide layouts draw flat rows, an uppercase section label, "Unpin" and
///   a Pin button.
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
                AppBackHeader(
                  title: 'Manage pinned',
                  titleContent: const ListsHeaderTitle(title: 'Manage pinned'),
                  onBack: _back,
                  actions: [
                    Padding(
                      padding: const EdgeInsetsDirectional.only(
                        end: AppSpacing.sm,
                      ),
                      child: AppPillButton(
                        label: 'Done',
                        compact: true,
                        onPressed: _back,
                      ),
                    ),
                  ],
                ),
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
    final phone = isListsPhone(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: _Note(
            'Following is always first. Drag to reorder.',
            style: phone
                ? muted
                : theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
            top: phone ? AppSpacing.md : AppSpacing.smd,
          ),
        ),
        if (!phone)
          const SliverToBoxAdapter(
            child: ListsSectionHeader(title: 'Pinned', label: true),
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
              final list = _lists.header(tab.id);
              return _PinnedRow(
                key: ValueKey(tab.key),
                index: i,
                last: i == tabs.tabs.length - 1,
                label: label,
                subtitle: list == null ? null : listRowSubtitle(list),
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
          child: ListsSectionHeader(title: 'Add from your Lists', label: true),
        ),
        ..._addSlivers(own, addable, canPin, muted),
        const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.xl)),
        const ShellBottomInsetSliver(),
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
        final style = listsPageRowStyle(context);
        return [
          SliverList.builder(
            itemCount: addable.length,
            itemBuilder: (context, i) {
              final list = addable[i];
              final tooltip = canPin
                  ? 'Pin ${list.name} to Home'
                  : "Can't pin ${list.name}: Home is full";
              final pin = canPin
                  ? () => _report(
                      _tabs.pin(HomeTabKind.list, list.listId, list.name),
                    )
                  : null;
              return ListRow(
                key: ValueKey(list.listId),
                list: list,
                style: style,
                onTap: () => context.push(AppRouter.listPath(list.listId)),
                trailing: style == ListRowStyle.wide
                    ? Padding(
                        padding: const EdgeInsetsDirectional.only(
                          end: AppListsLayout.wideGutter,
                        ),
                        child: Tooltip(
                          message: tooltip,
                          child: AppPillButton(
                            label: 'Pin',
                            compact: true,
                            variant: AppButtonVariant.navy,
                            onPressed: pin,
                          ),
                        ),
                      )
                    : IconButton(
                        tooltip: tooltip,
                        constraints: const BoxConstraints(
                          minWidth: AppSpacing.minTapTarget,
                          minHeight: AppSpacing.minTapTarget,
                        ),
                        icon: const Icon(Icons.push_pin_outlined),
                        onPressed: pin,
                      ),
              );
            },
          ),
        ];
    }
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text, {this.style, this.top = AppSpacing.smd});

  final String text;
  final TextStyle? style;
  final double top;

  @override
  Widget build(BuildContext context) {
    final gutter = isListsPhone(context)
        ? AppListsLayout.phoneGutter
        : AppListsLayout.wideGutter;
    return Padding(
      padding: EdgeInsets.fromLTRB(gutter, top, gutter, AppSpacing.smd),
      child: Text(text, style: style),
    );
  }
}

/// One row of the pinned group: a raised card on a phone, a flat row with a
/// hairline on the wide layouts. [child] is the row's content.
class _PinnedShell extends StatelessWidget {
  const _PinnedShell({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (isListsPhone(context)) {
      return Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppListsLayout.phoneGutter,
        ),
        child: AppCard(
          margin: const EdgeInsets.only(bottom: AppListsLayout.raisedGap),
          padding: const EdgeInsets.all(AppListsLayout.raisedPadding),
          child: child,
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppListsLayout.wideGutter,
            vertical: AppSpacing.sm,
          ),
          child: child,
        ),
        const Divider(height: 1),
      ],
    );
  }
}

/// A pinned row's name, with the wide mocks' tile before it and their muted
/// [subtitle] under it.
class _PinnedLabel extends StatelessWidget {
  const _PinnedLabel({required this.label, this.subtitle, required this.tile});

  final String label;
  final String? subtitle;
  final bool tile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitle = this.subtitle;
    return Row(
      children: [
        if (tile) ...[
          const AppTileIcon(
            icon: Icons.list_alt_outlined,
            size: AppListsLayout.pinnedTile,
          ),
          const SizedBox(width: AppListsLayout.wideRowGap),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium,
              ),
              if (subtitle != null && !isListsPhone(context))
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Following: first and fixed, so no handle and no Unpin.
class _FollowingRow extends StatelessWidget {
  const _FollowingRow();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final phone = isListsPhone(context);
    return Semantics(
      label: 'Following, always first',
      excludeSemantics: true,
      child: _PinnedShell(
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppSpacing.minTapTarget),
          child: Row(
            children: [
              // The slot of the other rows' drag handle.
              SizedBox.square(
                dimension: AppSpacing.minTapTarget,
                child: Icon(
                  Icons.lock_outline,
                  size: AppIconSize.md,
                  color: muted,
                ),
              ),
              if (!phone) ...[
                const AppTileIcon(
                  icon: Icons.people_outline,
                  size: AppListsLayout.pinnedTile,
                ),
                const SizedBox(width: AppListsLayout.wideRowGap),
              ],
              Expanded(
                flex: 3,
                child: phone
                    ? Text('Following', style: theme.textTheme.titleMedium)
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Following', style: theme.textTheme.titleMedium),
                          Text(
                            'Always first',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: muted,
                            ),
                          ),
                        ],
                      ),
              ),
              if (phone)
                Expanded(
                  flex: 2,
                  child: Padding(
                    padding: const EdgeInsetsDirectional.only(
                      end: AppSpacing.smd,
                    ),
                    child: Text(
                      'Always first',
                      textAlign: TextAlign.end,
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One pinned tab: a drag handle, the name and Unpin. The row exposes "Move
/// up" and "Move down" as semantic actions, so a reorder needs no drag.
class _PinnedRow extends StatelessWidget {
  const _PinnedRow({
    super.key,
    required this.index,
    required this.last,
    required this.label,
    required this.subtitle,
    required this.onUnpin,
    required this.onMove,
  });

  final int index;
  final bool last;
  final String label;
  final String? subtitle;
  final VoidCallback onUnpin;

  /// -1 up, +1 down.
  final ValueChanged<int> onMove;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final phone = isListsPhone(context);
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
        child: _PinnedShell(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: AppSpacing.minTapTarget,
            ),
            child: Row(
              children: [
                ReorderableDragStartListener(
                  index: index,
                  child: SizedBox.square(
                    dimension: AppSpacing.minTapTarget,
                    child: ExcludeSemantics(
                      child: Icon(Icons.drag_handle, color: muted),
                    ),
                  ),
                ),
                Expanded(
                  child: _PinnedLabel(
                    label: label,
                    subtitle: subtitle,
                    tile: !phone,
                  ),
                ),
                if (phone)
                  IconButton(
                    tooltip: 'Unpin $label',
                    constraints: const BoxConstraints(
                      minWidth: AppSpacing.minTapTarget,
                      minHeight: AppSpacing.minTapTarget,
                    ),
                    icon: Icon(Icons.push_pin, color: muted),
                    onPressed: onUnpin,
                  )
                else
                  Tooltip(
                    message: 'Unpin $label',
                    child: TextButton(
                      onPressed: onUnpin,
                      child: const Text('Unpin'),
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
