import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../shared/widgets/primitives/app_tab_bar.dart';
import '../../../lists/presentation/bloc/home_tabs_cubit.dart';
import '../../../lists/presentation/bloc/home_tabs_state.dart';

/// The Home tab bar with pinned timelines: Following first, then the
/// pinned tabs in order. (Manage pinned opens from the Feed top bar:
/// `PinnedTimelinesButton`.) A thin
/// BLoC binding of [AppTabBar] (content-sized, scrolls when it overflows);
/// it reads the [HomeTabsCubit] above it and selects by tab key.
class HomeTabBar extends StatelessWidget {
  const HomeTabBar({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<HomeTabsCubit, HomeTabsState>(
      builder: (context, state) {
        final cubit = context.read<HomeTabsCubit>();
        return AppTabBar(
          semanticLabel: 'Home timelines',
          selectedIndex: state.selectedIndex,
          onChanged: (i) =>
              cubit.select(i == 0 ? kFollowingTabKey : state.tabs[i - 1].key),
          tabs: [
            const AppTab(label: 'Following'),
            for (final tab in state.tabs) AppTab(label: state.labelOf(tab)),
          ],
        );
      },
    );
  }
}
