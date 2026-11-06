import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/primitives/app_back_header.dart';
import '../../../shared/widgets/primitives/app_empty_view.dart';
import '../../../shared/widgets/primitives/app_main_column.dart';
import '../../../shared/widgets/user/user_list_skeleton.dart';
import '../../communities/data/communities_repository.dart';
import '../data/beacons_repository.dart';
import 'beacons_error_messages.dart';
import 'bloc/beacons_cubit.dart';
import 'bloc/beacons_state.dart';
import 'widgets/beacon_row.dart';

/// `/plans`: the selected audience's upcoming plans (R30). The audience chips
/// show only when the caller has joined communities to choose from.
class BeaconsScreen extends StatefulWidget {
  const BeaconsScreen({super.key});

  @override
  State<BeaconsScreen> createState() => _BeaconsScreenState();
}

class _BeaconsScreenState extends State<BeaconsScreen> {
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

  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRouter.homePath);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: AppMainColumn(
          child: BlocBuilder<BeaconsCubit, BeaconsState>(
            bloc: _cubit,
            builder: (context, state) {
              return Column(
                children: [
                  AppBackHeader(
                    title: 'Plans',
                    onBack: _back,
                    actions: [
                      IconButton(
                        tooltip: 'New plan',
                        icon: const Icon(Icons.add_circle_outline),
                        onPressed: () => context.push(AppRouter.planNewPath),
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
              onTap: () =>
                  context.push(AppRouter.planPath(view.beacon.beaconId)),
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
