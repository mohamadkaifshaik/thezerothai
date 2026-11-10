import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_shell_scope.dart';
import '../../../core/widgets/app_state_view.dart';
import '../../../core/widgets/app_top_bar.dart';
import '../../../shared/widgets/primitives/app_back_header.dart';
import '../../../shared/widgets/primitives/app_empty_view.dart';
import '../../../shared/widgets/primitives/app_main_column.dart';
import '../../../shared/widgets/user/user_list_skeleton.dart';
import '../../communities/data/communities_repository.dart';
import '../data/beacons_repository.dart';
import '../domain/beacons_feature_flag.dart';
import 'beacons_error_messages.dart';
import 'bloc/beacons_cubit.dart';
import 'bloc/beacons_state.dart';
import 'widgets/beacon_row.dart';

/// `/plans`: the selected audience's upcoming plans (R30). The audience chips
/// show only when the caller has joined communities to choose from.
///
/// Plans is never turned off (ADR-0034 section 4): with `beacons` off for the
/// caller the page stays and shows [kPlansPausedTitle] instead of the list,
/// with no create action and no RPC. A kill switch in mid-session gets there
/// by itself: the list shows the same paused page as soon as the server
/// answers FEATURE_DISABLED (also when the `GetMe` the gate then asks for
/// fails), and once the flag leaves `enabled_features` this widget rebuilds
/// into the paused state.
class BeaconsScreen extends StatelessWidget {
  const BeaconsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return isFeatureEnabled(context, kFeatureBeacons)
        ? const _PlansList()
        : const _PlansPaused();
  }
}

/// The paused copy (accepted, ADR-0034 section 4).
const kPlansPausedTitle = 'Plans are paused';
const kPlansPausedBody =
    'Your plans and requests are safe. They will show again when Plans is '
    'back.';

/// The page header, shared by the list and the paused state.
class _PlansHeader extends StatelessWidget {
  const _PlansHeader({this.actions = const []});

  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return AppBackHeader(
      title: 'Plans',
      onBack: () {
        if (context.canPop()) {
          context.pop();
        } else {
          context.go(AppRouter.homePath);
        }
      },
      // A primary destination: at the root of a phone shell it leads with the
      // avatar (drawer, Profile) instead of Back; when something can be
      // popped, Back stays.
      leading:
          MediaQuery.sizeOf(context).width < AppBreakpoints.mobile &&
              AppShellScope.maybeOf(context) != null &&
              !context.canPop()
          ? const AppAvatarButton()
          : null,
      actions: actions,
    );
  }
}

/// `beacons` is off for the caller: the header and the notice, nothing else.
/// It builds no cubit, so it sends nothing.
class _PlansPaused extends StatelessWidget {
  const _PlansPaused();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: SafeArea(child: AppMainColumn(child: _PlansPausedColumn())),
    );
  }
}

/// The paused page content: the header with no action, and the notice.
class _PlansPausedColumn extends StatelessWidget {
  const _PlansPausedColumn();

  @override
  Widget build(BuildContext context) {
    return const Column(
      children: [
        _PlansHeader(),
        Expanded(
          child: AppStateView(
            icon: Icons.event_outlined,
            title: kPlansPausedTitle,
            body: kPlansPausedBody,
          ),
        ),
      ],
    );
  }
}

class _PlansList extends StatefulWidget {
  const _PlansList();

  @override
  State<_PlansList> createState() => _PlansListState();
}

class _PlansListState extends State<_PlansList> {
  late final BeaconsCubit _cubit;

  @override
  void initState() {
    super.initState();
    final communities = context.read<CommunitiesRepository?>();
    _cubit = BeaconsCubit(
      repository: context.read<BeaconsRepository>(),
      communities: communities,
      communitiesEnabled: communities?.enabled ?? false,
    )..load();
  }

  @override
  void dispose() {
    _cubit.close();
    super.dispose();
  }

  /// Opens [path] and reloads the list when it comes back: a plan created
  /// there, or one cancelled there, is shown on return (one ListBeacons; the
  /// chips are cached).
  Future<void> _open(String path) async {
    await context.push(path);
    if (mounted) await _cubit.load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: AppMainColumn(
          child: BlocBuilder<BeaconsCubit, BeaconsState>(
            bloc: _cubit,
            builder: (context, state) {
              // The server said the feature is off while the flag still
              // lists it (a kill switch before the next `GetMe`, or that
              // `GetMe` failing): the same paused page, with no action and
              // no retry, so nothing more is sent from here.
              if (state.status == BeaconsLoad.error &&
                  state.error is FeatureDisabledException) {
                return const _PlansPausedColumn();
              }
              return Column(
                children: [
                  _PlansHeader(
                    actions: [
                      IconButton(
                        tooltip: 'My plans',
                        icon: const Icon(Icons.event_available_outlined),
                        onPressed: () => _open(AppRouter.plansMinePath),
                      ),
                      IconButton(
                        tooltip: 'New plan',
                        icon: const Icon(Icons.add_circle_outline),
                        onPressed: () => _open(AppRouter.planNewPath),
                      ),
                    ],
                  ),
                  if (state.audiences.length > 1)
                    _AudienceChips(state: state, onSelect: _cubit.select),
                  Expanded(
                    child: RefreshIndicator(
                      onRefresh: _cubit.load,
                      child: _body(context, state),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, BeaconsState state) {
    switch (state.status) {
      case BeaconsLoad.loading:
        return const SingleChildScrollView(
          physics: AlwaysScrollableScrollPhysics(),
          child: UserListSkeleton(semanticsLabel: 'Loading plans'),
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
              title: 'No plans yet',
              subtitle: 'Create one and invite people along.',
            ),
          );
        }
        return ListView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          itemCount: state.views.length + (state.hasMore ? 1 : 0),
          itemBuilder: (context, i) {
            if (i == state.views.length) {
              return _LoadMore(state: state, onLoadMore: _cubit.loadMore);
            }
            final view = state.views[i];
            return BeaconRow(
              view: view,
              onTap: () => _open(AppRouter.planPath(view.beacon.beaconId)),
            );
          },
        );
    }
  }

  /// A pull-to-refresh needs a scrollable even around a static view.
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

class _AudienceChips extends StatelessWidget {
  const _AudienceChips({required this.state, required this.onSelect});

  final BeaconsState state;
  final ValueChanged<BeaconsAudience> onSelect;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      child: Wrap(
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.xs,
        children: [
          for (final a in state.audiences)
            ChoiceChip(
              label: Text(a.name),
              selected: a == state.selected,
              onSelected: (_) => onSelect(a),
            ),
        ],
      ),
    );
  }
}

class _LoadMore extends StatelessWidget {
  const _LoadMore({required this.state, required this.onLoadMore});

  final BeaconsState state;
  final VoidCallback onLoadMore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        children: [
          if (state.error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Text(
                beaconsErrorMessage(state.error!),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          if (state.loadingMore)
            Semantics(
              label: 'Loading more plans',
              child: SizedBox(
                width: AppIconSize.lg,
                height: AppIconSize.lg,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            TextButton(onPressed: onLoadMore, child: const Text('Load more')),
        ],
      ),
    );
  }
}
