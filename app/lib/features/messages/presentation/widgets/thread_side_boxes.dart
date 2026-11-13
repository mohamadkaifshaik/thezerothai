import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/context_pane.dart';
import '../../../../gen/dzeroth/common/v1/common.pb.dart' as common;
import '../../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../../../shared/widgets/primitives/app_avatar.dart';
import '../../../../shared/widgets/primitives/app_surface.dart';
import '../../../beacons/data/beacons_repository.dart';
import '../../../beacons/presentation/widgets/beacon_row.dart';
import '../../../graph/data/graph_repository.dart';
import '../../../graph/presentation/bloc/relationship_cubit.dart';
import '../../../graph/presentation/bloc/relationship_state.dart';
import '../../../graph/presentation/graph_error_messages.dart';
import '../../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as beacons;
import 'thread_info_sheet.dart';

/// The desktop Chat mock's side column (>= 1200 dp, inside the shell): the
/// peer's card (avatar, name, handle, what the caller already knows of the
/// follow, View profile, Mute), the plans the two share
/// (`chat_shared_plans`) and the chat actions the info menu has (Block,
/// Report, Delete conversation). Lent to the shell by the thread screens
/// (`ShellSideColumnLease`), built over what they already hold.
///
/// Not drawn: "Share live location" (no flag, no RPC) and the call button
/// (no calling).
class ThreadSideBoxes extends StatelessWidget {
  const ThreadSideBoxes({
    super.key,
    required this.peer,
    required this.onViewProfile,
    this.silent = false,
    this.graphRepository,
    this.beaconsRepository,
    this.actions = const [],
  });

  final common.AuthorSnapshot peer;

  /// The conversation says the caller muted the peer.
  final bool silent;

  /// Opens the peer's profile; null without a handle.
  final VoidCallback? onViewProfile;

  /// With a graph repository the card has Mute and the follow state it
  /// caches; without, neither.
  final GraphRepository? graphRepository;

  /// With a repository (`chat_shared_plans` and `beacons` on, a user id), the
  /// "Shared plan" box; without, none.
  final BeaconsRepository? beaconsRepository;

  /// The chat actions of the info menu, in order; none: no box.
  final List<ThreadSideAction> actions;

  @override
  Widget build(BuildContext context) {
    final beaconsRepository = this.beaconsRepository;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PeerCard(
          key: ValueKey('peer-${peer.userId}'),
          peer: peer,
          silent: silent,
          onViewProfile: onViewProfile,
          graphRepository: peer.userId.isEmpty ? null : graphRepository,
        ),
        if (beaconsRepository != null && peer.userId.isNotEmpty)
          _SharedPlans(
            key: ValueKey('shared-${peer.userId}'),
            peerUserId: peer.userId,
            repository: beaconsRepository,
          ),
        if (actions.isNotEmpty)
          AppSurface(
            margin: const EdgeInsets.only(bottom: AppSpacing.md),
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (final action in actions)
                  ThreadInfoActionRow(
                    icon: action.icon,
                    label: action.label,
                    destructive: action.destructive,
                    onTap: action.onTap,
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// One chat action of [ThreadSideBoxes]: the info menu's row.
@immutable
class ThreadSideAction {
  const ThreadSideAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.destructive = false,
  });

  final IconData icon;
  final String label;

  /// Null: shown, disabled.
  final VoidCallback? onTap;
  final bool destructive;
}

class _PeerCard extends StatefulWidget {
  const _PeerCard({
    super.key,
    required this.peer,
    required this.silent,
    required this.onViewProfile,
    required this.graphRepository,
  });

  final common.AuthorSnapshot peer;
  final bool silent;
  final VoidCallback? onViewProfile;
  final GraphRepository? graphRepository;

  @override
  State<_PeerCard> createState() => _PeerCardState();
}

class _PeerCardState extends State<_PeerCard> {
  RelationshipCubit? _relationship;

  @override
  void initState() {
    super.initState();
    final repository = widget.graphRepository;
    if (repository == null) return;
    final cached = repository.cached(widget.peer.userId);
    _relationship = RelationshipCubit(
      graphRepository: repository,
      userId: widget.peer.userId,
      initial: graph.Relationship(
        userId: widget.peer.userId,
        followState: cached?.followState,
        blocking: cached?.blocking,
        // The conversation knows the mute even when the cache does not.
        muting: (cached?.muting ?? false) || widget.silent,
      ),
    );
  }

  @override
  void dispose() {
    unawaited(_relationship?.close());
    super.dispose();
  }

  Future<void> _toggleMute(RelationshipCubit cubit, bool muting) async {
    final messenger = ScaffoldMessenger.of(context);
    await (muting ? cubit.unmute() : cubit.mute());
    final AppException? error = cubit.state.error;
    if (error == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(relationshipErrorMessage(error))));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final peer = widget.peer;
    final hasName = peer.displayName.isNotEmpty;
    final name = hasName ? peer.displayName : '@${peer.handle}';
    final cubit = _relationship;
    return AppSurface(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ExcludeSemantics(
            child: AppAvatar(url: peer.avatarUrl, radius: AppSpacing.xl),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            name,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          if (hasName && peer.handle.isNotEmpty)
            Text(
              '@${peer.handle}',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          if (cubit != null)
            BlocBuilder<RelationshipCubit, RelationshipState>(
              bloc: cubit,
              builder: (context, state) {
                final line = _followLine(state.relationship.followState);
                return line == null
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(top: AppSpacing.xs),
                        child: Text(
                          line,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      );
              },
            ),
          if (widget.onViewProfile != null || cubit != null) ...[
            const SizedBox(height: AppSpacing.md),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                if (widget.onViewProfile != null)
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, AppSpacing.minTapTarget),
                    ),
                    onPressed: widget.onViewProfile,
                    child: const Text('View profile'),
                  ),
                if (cubit != null)
                  BlocBuilder<RelationshipCubit, RelationshipState>(
                    bloc: cubit,
                    builder: (context, state) {
                      final muting = state.relationship.muting;
                      return OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, AppSpacing.minTapTarget),
                        ),
                        onPressed: state.isUpdating
                            ? null
                            : () => unawaited(_toggleMute(cubit, muting)),
                        child: Text(muting ? 'Unmute' : 'Mute'),
                      );
                    },
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// What the cache knows of the follow, or null (nothing is fetched for it).
  static String? _followLine(graph.FollowState state) => switch (state) {
    graph.FollowState.FOLLOW_STATE_FOLLOWING => 'You follow them',
    graph.FollowState.FOLLOW_STATE_REQUESTED => 'Follow requested',
    _ => null,
  };
}

/// The "Shared plan" box: one `ListSharedBeacons` while the box is on screen,
/// nothing while it loads, when it fails or when there are none (a side box
/// never shows an error of its own).
class _SharedPlans extends StatefulWidget {
  const _SharedPlans({
    super.key,
    required this.peerUserId,
    required this.repository,
  });

  final String peerUserId;
  final BeaconsRepository repository;

  @override
  State<_SharedPlans> createState() => _SharedPlansState();
}

class _SharedPlansState extends State<_SharedPlans> {
  List<beacons.BeaconView> _views = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final page = await widget.repository.listSharedBeacons(
        peerUserId: widget.peerUserId,
        limit: 3,
      );
      if (mounted) setState(() => _views = page.views);
    } on AppException {
      // The box stays out; the chat itself is unaffected.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_views.isEmpty) return const SizedBox.shrink();
    return ContextPaneCard(
      title: _views.length == 1 ? 'Shared plan' : 'Shared plans',
      child: Column(
        children: [
          for (final view in _views)
            BeaconRow(
              key: ValueKey('shared-plan-${view.beacon.beaconId}'),
              view: view,
              dense: true,
              onTap: () =>
                  context.push(AppRouter.planPath(view.beacon.beaconId)),
            ),
        ],
      ),
    );
  }
}
