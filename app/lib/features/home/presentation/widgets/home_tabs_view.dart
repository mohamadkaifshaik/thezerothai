import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../lists/presentation/bloc/home_tabs_cubit.dart';
import '../../../lists/presentation/bloc/home_tabs_state.dart';
import 'home_list_tab.dart';
import 'home_tab_bar.dart';

/// The body of Home with pinned timelines (W5-14): Following, then one
/// [HomeListTab] per pinned tab, all fed by the [HomeTabsCubit] above.
///
/// - Following is built at once (as without tabs); a list tab is built the
///   first time it is selected, then kept alive (scroll offset, cached rows,
///   its cubit) behind the selected one, so switching costs no RPC beyond the
///   throttled refresh. Only the selected tab ticks (`TimelineFeedView.active`).
/// - Children are keyed by tab key, so a reorder moves them without
///   rebuilding; an unpinned tab disappears with its cubit.
/// - [following] draws the Following feed with the tab bar it must put in its
///   header and whether it is the visible tab.
class HomeTabsView extends StatefulWidget {
  const HomeTabsView({super.key, required this.following});

  final Widget Function(BuildContext context, Widget tabBar, bool active)
  following;

  @override
  State<HomeTabsView> createState() => _HomeTabsViewState();
}

class _HomeTabsViewState extends State<HomeTabsView> {
  final Set<String> _visited = {};

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<HomeTabsCubit, HomeTabsState>(
      builder: (context, state) {
        _visited
          ..removeWhere((key) => !state.tabs.any((t) => t.key == key))
          ..add(state.selectedKey);
        final selected = state.selectedKey;
        return Stack(
          fit: StackFit.expand,
          children: [
            _Layer(
              key: const ValueKey(kFollowingTabKey),
              visible: selected == kFollowingTabKey,
              child: widget.following(
                context,
                const HomeTabBar(),
                selected == kFollowingTabKey,
              ),
            ),
            for (final tab in state.tabs)
              if (_visited.contains(tab.key))
                _Layer(
                  key: ValueKey(tab.key),
                  visible: tab.key == selected,
                  child: HomeListTab(tab: tab, active: tab.key == selected),
                ),
          ],
        );
      },
    );
  }
}

/// Keeps a tab built, laid out and scrolled while hidden, with no focus,
/// semantics or tickers.
class _Layer extends StatelessWidget {
  const _Layer({super.key, required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Visibility(visible: visible, maintainState: true, child: child);
}
