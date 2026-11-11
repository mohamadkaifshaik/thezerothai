import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import '../../../shared/widgets/primitives/app_back_header.dart';
import '../../../shared/widgets/primitives/app_empty_view.dart';
import '../../../shared/widgets/primitives/app_main_column.dart';
import '../../../shared/widgets/primitives/app_menu_item_row.dart';
import '../../../shared/widgets/primitives/app_section_header.dart';
import '../../../shared/widgets/primitives/app_tab_bar.dart';
import '../../../shared/widgets/user/user_list_skeleton.dart';
import '../../graph/data/graph_repository.dart';
import '../data/beacons_repository.dart';
import '../domain/beacon_labels.dart';
import 'beacons_error_messages.dart';
import 'bloc/beacon_people_cubit.dart';
import 'bloc/beacon_people_state.dart';
import 'widgets/participant_row.dart';
import '../../../shared/widgets/primitives/app_dialog.dart';

/// `/plans/:id/people` (R38): who is going, and for the organiser the
/// requests with their notes and the controls (Accept; Decline, Decline and
/// block; Remove). One GetBeacon tells whether the viewer manages the plan.
///
/// The plan's summary sits under the header at every width (tablet plan
/// section 3, R-inline; no pane in band B): its title and time, how many are
/// going, the organiser's requests, the open spots, and who may see the
/// list. A completed accept, decline or remove reads the plan again so the
/// counts follow.
class BeaconPeopleScreen extends StatefulWidget {
  const BeaconPeopleScreen({super.key, required this.beaconId});

  final String beaconId;

  @override
  State<BeaconPeopleScreen> createState() => _BeaconPeopleScreenState();
}

class _BeaconPeopleScreenState extends State<BeaconPeopleScreen> {
  late final BeaconsRepository _repository = context.read<BeaconsRepository>();
  late final BeaconPeopleCubit _going;
  BeaconPeopleCubit? _requests;
  pb.BeaconView? _view;
  AppException? _error;

  /// The organiser and accepted participants may read the list (the proto's
  /// ListParticipants); anyone else is told so without a failing read.
  bool _mayList = false;
  var _tab = 0;

  @override
  void initState() {
    super.initState();
    final graph = context.read<GraphRepository?>();
    _going = BeaconPeopleCubit(
      repository: _repository,
      beaconId: widget.beaconId,
      filter: pb.ParticipantFilter.PARTICIPANT_FILTER_ACCEPTED,
      graph: graph,
    );
    _loadView(graph);
  }

  Future<void> _loadView(GraphRepository? graph) async {
    try {
      final view = await _repository.getBeacon(widget.beaconId);
      if (!mounted) return;
      setState(() {
        _view = view;
        _mayList =
            view.viewer.canManage ||
            view.viewer.participantState ==
                pb.ParticipantState.PARTICIPANT_STATE_ACCEPTED;
        if (_mayList) _going.load();
        if (view.viewer.canManage && _requests == null) {
          _requests = BeaconPeopleCubit(
            repository: _repository,
            beaconId: widget.beaconId,
            filter: pb.ParticipantFilter.PARTICIPANT_FILTER_REQUESTED,
            graph: graph,
          )..load();
        }
      });
    } on AppException catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    }
  }

  /// The counts after an action: one GetBeacon; a failure keeps the last
  /// view (the lists themselves already reloaded).
  Future<void> _refreshView() async {
    try {
      final view = await _repository.getBeacon(widget.beaconId);
      if (mounted) setState(() => _view = view);
    } on AppException {
      return;
    }
  }

  /// An accept, decline or remove that went through.
  static bool _actionDone(BeaconPeopleState a, BeaconPeopleState b) =>
      a.busyUserId != null && b.busyUserId == null && b.actionError == null;

  @override
  void dispose() {
    _going.close();
    _requests?.close();
    super.dispose();
  }

  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRouter.planPath(widget.beaconId));
    }
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    required String action,
  }) async {
    final confirmed = await showAppMaterialDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(action),
          ),
        ],
      ),
    );
    return confirmed == true && mounted;
  }

  Future<void> _decline(pb.Participant p, {required bool block}) async {
    final handle = p.user.handle;
    final ok = block
        ? await _confirm(
            title: 'Decline and block @$handle?',
            body: "They won't see your plans or profile.",
            action: 'Decline and block',
          )
        : await _confirm(
            title: "Decline @$handle's request?",
            body: 'They can ask again later.',
            action: 'Decline',
          );
    if (!ok) return;
    final requests = _requests!;
    await (block
        ? requests.declineAndBlock(p.user.userId)
        : requests.decline(p.user.userId));
  }

  Future<void> _remove(pb.Participant p) async {
    if (!await _confirm(
      title: 'Remove @${p.user.handle}?',
      body: 'Their seat opens up for someone else.',
      action: 'Remove',
    )) {
      return;
    }
    await _going.remove(p.user.userId);
  }

  void _say(String text, {String? retryBlockFor}) =>
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(text),
            duration: retryBlockFor == null
                ? const Duration(seconds: 4)
                : const Duration(seconds: 30),
            action: retryBlockFor == null
                ? null
                : SnackBarAction(
                    label: 'Retry block',
                    onPressed: () => _requests?.retryBlock(retryBlockFor),
                  ),
          ),
        );

  @override
  Widget build(BuildContext context) {
    final manages = _view?.viewer.canManage ?? false;
    final requests = _requests;
    return Scaffold(
      body: SafeArea(
        child: AppMainColumn(
          child: MultiBlocListener(
            listeners: [
              BlocListener<BeaconPeopleCubit, BeaconPeopleState>(
                bloc: _going,
                listenWhen: (a, b) =>
                    b.actionError != null && a.actionError != b.actionError,
                listener: (_, state) => _say(state.actionError!),
              ),
              BlocListener<BeaconPeopleCubit, BeaconPeopleState>(
                bloc: _going,
                listenWhen: _actionDone,
                listener: (_, _) => _refreshView(),
              ),
              if (requests != null)
                BlocListener<BeaconPeopleCubit, BeaconPeopleState>(
                  bloc: requests,
                  listenWhen: _actionDone,
                  listener: (_, _) => _refreshView(),
                ),
              if (requests != null)
                BlocListener<BeaconPeopleCubit, BeaconPeopleState>(
                  bloc: requests,
                  listenWhen: (a, b) =>
                      b.actionError != null && a.actionError != b.actionError,
                  listener: (_, state) => _say(
                    state.actionError!,
                    retryBlockFor: state.retryBlockUserId,
                  ),
                ),
            ],
            child: Column(
              children: [
                AppBackHeader(title: 'People', onBack: _back),
                if (_view case final view?)
                  _PeopleSummary(
                    view: view,
                    requests: manages ? requests : null,
                    // Locked out of the list: the page body already says
                    // who may see it.
                    showNote: _mayList,
                  ),
                if (manages && requests != null)
                  AppTabBar(
                    tabs: const [
                      AppTab(label: 'Going'),
                      AppTab(label: 'Requests'),
                    ],
                    selectedIndex: _tab,
                    equalWidth: true,
                    semanticLabel: 'People lists',
                    onChanged: (i) {
                      setState(() => _tab = i);
                      // The other tab may have changed under an action here.
                      (i == 0 ? _going : requests).load();
                    },
                  )
                else
                  const AppSectionHeader(title: 'Going'),
                if (requests != null)
                  BlocBuilder<BeaconPeopleCubit, BeaconPeopleState>(
                    bloc: requests,
                    buildWhen: (a, b) =>
                        a.pendingBlocks != b.pendingBlocks ||
                        a.busyUserId != b.busyUserId,
                    builder: (context, state) => Column(
                      children: [
                        for (final e in state.pendingBlocks.entries)
                          _PendingBlockRow(
                            handle: e.value,
                            busy: state.busyUserId != null,
                            onRetry: () => requests.retryBlock(e.key),
                          ),
                      ],
                    ),
                  ),
                Expanded(
                  child: _error != null
                      ? Center(
                          child: AppEmptyView(
                            icon: Icons.error_outline,
                            title: beaconsErrorMessage(_error!),
                          ),
                        )
                      : _view == null
                      ? const UserListSkeleton(semanticsLabel: 'Loading people')
                      : !_mayList
                      ? const Center(
                          child: AppEmptyView(
                            icon: Icons.lock_outline,
                            title:
                                'Only people who are going can see this list.',
                          ),
                        )
                      : _tab == 1 && requests != null
                      ? _List(
                          cubit: requests,
                          empty: 'No requests yet',
                          showNote: true,
                          trailing: (p) => _requestControls(p, requests),
                          onTap: _openProfile,
                        )
                      : _List(
                          cubit: _going,
                          empty: 'No one yet',
                          trailing: manages ? _goingControls : null,
                          onTap: _openProfile,
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openProfile(pb.Participant p) =>
      context.push(AppRouter.profileByIdPath(p.user.userId));

  Widget _requestControls(pb.Participant p, BeaconPeopleCubit requests) {
    final busy = requests.state.busyUserId != null;
    final canBlock = context.read<GraphRepository?>() != null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextButton(
          onPressed: busy ? null : () => requests.accept(p.user.userId),
          child: const Text('Accept'),
        ),
        PopupMenuButton<String>(
          tooltip: 'Request options',
          icon: const Icon(Icons.more_horiz),
          enabled: !busy,
          onSelected: (value) => _decline(p, block: value == 'block'),
          itemBuilder: (context) => [
            const PopupMenuItem(
              value: 'decline',
              child: AppMenuItemRow(icon: Icons.close, label: 'Decline'),
            ),
            if (canBlock)
              const PopupMenuItem(
                value: 'block',
                child: AppMenuItemRow(
                  icon: Icons.block,
                  label: 'Decline and block',
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _goingControls(pb.Participant p) => PopupMenuButton<String>(
    tooltip: 'Participant options',
    icon: const Icon(Icons.more_horiz),
    enabled: _going.state.busyUserId == null,
    onSelected: (_) => _remove(p),
    itemBuilder: (context) => const [
      PopupMenuItem(
        value: 'remove',
        child: AppMenuItemRow(
          icon: Icons.person_remove_outlined,
          label: 'Remove',
        ),
      ),
    ],
  );
}

class _List extends StatelessWidget {
  const _List({
    required this.cubit,
    required this.empty,
    required this.onTap,
    this.showNote = false,
    this.trailing,
  });

  final BeaconPeopleCubit cubit;
  final String empty;
  final bool showNote;
  final Widget Function(pb.Participant)? trailing;
  final void Function(pb.Participant) onTap;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<BeaconPeopleCubit, BeaconPeopleState>(
      bloc: cubit,
      builder: (context, state) {
        switch (state.status) {
          case PeopleLoad.loading:
            return const UserListSkeleton(semanticsLabel: 'Loading people');
          case PeopleLoad.error:
            return Center(
              child: AppEmptyView(
                icon: Icons.error_outline,
                title: beaconsErrorMessage(state.error!),
                action: TextButton(
                  onPressed: cubit.load,
                  child: const Text('Try again'),
                ),
              ),
            );
          case PeopleLoad.ready:
            if (state.rows.isEmpty) {
              return Center(
                child: AppEmptyView(icon: Icons.people_outline, title: empty),
              );
            }
            return RefreshIndicator(
              onRefresh: cubit.load,
              child: ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: state.rows.length + (state.hasMore ? 1 : 0),
                itemBuilder: (context, i) {
                  if (i == state.rows.length) {
                    return Padding(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      child: state.loadingMore
                          ? const Center(
                              child: SizedBox(
                                width: AppIconSize.lg,
                                height: AppIconSize.lg,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            )
                          : TextButton(
                              onPressed: cubit.loadMore,
                              child: const Text('Load more'),
                            ),
                    );
                  }
                  final p = state.rows[i];
                  return ParticipantRow(
                    participant: p,
                    showNote: showNote,
                    onTap: () => onTap(p),
                    trailing: trailing?.call(p),
                  );
                },
              ),
            );
        }
      },
    );
  }
}

/// Stays while a declined person is still unblocked, so the retry outlives
/// the snackbar.
class _PendingBlockRow extends StatelessWidget {
  const _PendingBlockRow({
    required this.handle,
    required this.busy,
    required this.onRetry,
  });

  final String handle;
  final bool busy;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final who = handle.isEmpty ? 'this person' : '@$handle';
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Blocking $who failed.',
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: Theme.of(context).colorScheme.error),
            ),
          ),
          TextButton(
            onPressed: busy ? null : onRetry,
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

/// The plan's facts under the People header (tablet plan section 4.1,
/// PlanPeople: "summary (going / requests / open spots + 'Only people who
/// are going…') inl header", at every width). Requests are the organiser's
/// only, counted from the loaded Requests list ("20+" while more pages
/// exist); there is no count on the wire.
class _PeopleSummary extends StatelessWidget {
  const _PeopleSummary({
    required this.view,
    required this.requests,
    required this.showNote,
  });

  final pb.BeaconView view;
  final BeaconPeopleCubit? requests;
  final bool showNote;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final b = view.beacon;
    final open = (b.openSpots - b.acceptedCount).clamp(0, b.openSpots);
    String counts(String? requested) => [
      '${b.acceptedCount} going',
      ?requested,
      open == 1 ? '1 open spot' : '$open open spots',
    ].join(' · ');
    final requests = this.requests;
    return Padding(
      key: const ValueKey('plan-people-summary'),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.smd,
        AppSpacing.md,
        AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            b.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium,
          ),
          Text(
            beaconWhenText(b),
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
          const SizedBox(height: AppSpacing.xs),
          if (requests == null)
            Text(counts(null), style: theme.textTheme.bodyMedium)
          else
            BlocBuilder<BeaconPeopleCubit, BeaconPeopleState>(
              bloc: requests,
              buildWhen: (a, c) =>
                  a.status != c.status ||
                  a.rows.length != c.rows.length ||
                  a.hasMore != c.hasMore,
              builder: (context, state) {
                final requested = state.status != PeopleLoad.ready
                    ? null
                    : '${state.rows.length}${state.hasMore ? '+' : ''} '
                          '${state.rows.length == 1 && !state.hasMore ? 'request' : 'requests'}';
                return Text(
                  counts(requested),
                  style: theme.textTheme.bodyMedium,
                );
              },
            ),
          if (showNote) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              kPeopleListNote,
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ],
        ],
      ),
    );
  }
}

/// Who may see the Going list (the design's PlanPeople note).
const kPeopleListNote = 'Only people who are going can see the Going list.';
