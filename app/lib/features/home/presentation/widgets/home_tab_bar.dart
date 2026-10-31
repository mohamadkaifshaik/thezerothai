import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_router.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/app_tab_bar.dart';
import '../../../lists/presentation/bloc/home_tabs_cubit.dart';
import '../../../lists/presentation/bloc/home_tabs_state.dart';

/// The Home tab bar with pinned timelines (W5-14): Following first, then the
/// pinned tabs in order, then a trailing "+" that opens Manage pinned. A thin
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
          fixedTrailing: IconButton(
            tooltip: 'Manage pinned timelines',
            constraints: const BoxConstraints(
              minWidth: AppSpacing.minTapTarget,
              minHeight: AppSpacing.minTapTarget,
            ),
            icon: const Icon(Icons.add),
            onPressed: () => context.push(AppRouter.pinnedPath),
          ),
        );
      },
    );
  }
}
