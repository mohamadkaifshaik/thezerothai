import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/shell_geometry.dart';
import '../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import '../../../shared/widgets/primitives/app_back_header.dart';
import '../../../shared/widgets/primitives/app_empty_view.dart';
import '../../../shared/widgets/primitives/app_main_column.dart';
import '../../../shared/widgets/primitives/app_tab_bar.dart';
import '../../../shared/widgets/user/user_list_skeleton.dart';
import '../data/beacons_repository.dart';
import 'beacons_error_messages.dart';
import 'bloc/beacons_state.dart' show BeaconsLoad;
import 'bloc/my_beacons_cubit.dart';
import 'bloc/my_beacons_state.dart';
import 'widgets/beacon_row.dart';

/// `/plans/mine` (R39): the caller's plans, Upcoming or Past, by role.
///
/// In band B of the tablet layout a row opens the plan with `go` (tablet
/// plan section 4.1, MyPlans): `/plans/:id` there is the list–detail with
/// the all-plans list beside it. Everywhere else it is pushed, as before.
class MyBeaconsScreen extends StatefulWidget {
  const MyBeaconsScreen({super.key});

  @override
  State<MyBeaconsScreen> createState() => _MyBeaconsScreenState();
}

class _MyBeaconsScreenState extends State<MyBeaconsScreen> {
  late final MyBeaconsCubit _cubit = MyBeaconsCubit(
    repository: context.read<BeaconsRepository>(),
  )..load();

  static const _roles = [
    (pb.MyBeaconsRole.MY_BEACONS_ROLE_ALL, 'All'),
    (pb.MyBeaconsRole.MY_BEACONS_ROLE_ORGANISER, 'Organising'),
    (pb.MyBeaconsRole.MY_BEACONS_ROLE_PARTICIPANT, 'Joined'),
  ];

  @override
  void dispose() {
    _cubit.close();
    super.dispose();
  }

  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRouter.plansPath);
    }
  }

  Future<void> _open(String id) async {
    final geometry = ShellGeometry.maybeOf(context);
    if (geometry != null &&
        geometry.tablet &&
        geometry.band == ShellBand.expanded) {
      context.go(AppRouter.planPath(id));
      return;
    }
    await context.push(AppRouter.planPath(id));
    if (mounted) await _cubit.load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: AppMainColumn(
          child: BlocBuilder<MyBeaconsCubit, MyBeaconsState>(
            bloc: _cubit,
            builder: (context, state) => Column(
              children: [
                AppBackHeader(title: 'My plans', onBack: _back),
                AppTabBar(
                  tabs: const [
                    AppTab(label: 'Upcoming'),
                    AppTab(label: 'Past'),
                  ],
                  selectedIndex:
                      state.window == pb.MyBeaconsWindow.MY_BEACONS_WINDOW_PAST
                      ? 1
                      : 0,
                  equalWidth: true,
                  semanticLabel: 'When',
                  onChanged: (i) => _cubit.select(
                    window: i == 1
                        ? pb.MyBeaconsWindow.MY_BEACONS_WINDOW_PAST
                        : pb.MyBeaconsWindow.MY_BEACONS_WINDOW_UPCOMING,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.sm,
                  ),
                  child: Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.xs,
                    children: [
                      for (final (role, label) in _roles)
                        ChoiceChip(
                          label: Text(label),
                          selected: state.role == role,
                          onSelected: (_) => _cubit.select(role: role),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: _cubit.load,
                    child: _body(state),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(MyBeaconsState state) {
    switch (state.status) {
      case BeaconsLoad.loading:
        return const SingleChildScrollView(
          physics: AlwaysScrollableScrollPhysics(),
          child: UserListSkeleton(semanticsLabel: 'Loading your plans'),
        );
      case BeaconsLoad.error:
        return _scrollable(
          AppEmptyView(
            icon: Icons.error_outline,
            title: beaconsErrorMessage(state.error!),
            action: TextButton(
              onPressed: _cubit.load,
              child: const Text('Try again'),
            ),
          ),
        );
      case BeaconsLoad.ready:
        if (state.views.isEmpty) {
          return _scrollable(
            const AppEmptyView(
              icon: Icons.event_outlined,
              title: 'Nothing here yet',
              subtitle: 'Plans you organise or join show up here.',
            ),
          );
        }
        return ListView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          itemCount: state.views.length + (state.hasMore ? 1 : 0),
          itemBuilder: (context, i) {
            if (i == state.views.length) {
              return Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: state.loadingMore
                    ? const Center(
                        child: SizedBox(
                          width: AppIconSize.lg,
                          height: AppIconSize.lg,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : TextButton(
                        onPressed: _cubit.loadMore,
                        child: const Text('Load more'),
                      ),
              );
            }
            final view = state.views[i];
            return BeaconRow(
              view: view,
              onTap: () => _open(view.beacon.beaconId),
            );
          },
        );
    }
  }

  Widget _scrollable(Widget child) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: constraints.maxHeight),
        child: Center(child: child),
      ),
    ),
  );
}
