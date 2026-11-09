import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import '../../../gen/dzeroth/moderation/v1/moderation.pbenum.dart';
import '../../../shared/widgets/primitives/app_avatar.dart';
import '../../../shared/widgets/primitives/app_back_header.dart';
import '../../../shared/widgets/primitives/app_empty_view.dart';
import '../../../shared/widgets/primitives/app_main_column.dart';
import '../../../shared/widgets/primitives/app_menu_item_row.dart';
import '../../../shared/widgets/primitives/app_notice_banner.dart';
import '../../../shared/widgets/primitives/app_status_pill.dart';
import '../../../shared/widgets/primitives/app_tile_icon.dart';
import '../../../shared/widgets/user/user_list_skeleton.dart';
import '../../messages/domain/messaging_feature_flag.dart';
import '../../messages/presentation/open_conversation.dart';
import '../../messages/presentation/report_conversation.dart'
    show thankForReport;
import '../../moderation/domain/reports_feature_flag.dart';
import '../../moderation/presentation/report_sheet.dart';
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../data/beacons_repository.dart';
import '../domain/beacon_labels.dart';
import 'beacon_icons.dart';
import 'beacons_error_messages.dart';
import 'bloc/beacon_detail_cubit.dart';
import 'bloc/beacon_detail_state.dart';
import 'widgets/beacon_status_pill.dart';
import 'widgets/join_note_sheet.dart';

/// The NOT_FOUND text of the plan report sheet.
const kReportBeaconNotFound = "This plan isn't available to report any more.";

/// `/plans/:id` (R32, R37): the server's view of one plan. The buttons follow
/// `ViewerState`: Ask to join, Withdraw request, Leave plan; the organiser's
/// People, Edit and Cancel plan. The menu offers Message organiser (messaging
/// on, not the organiser) and Report plan (reports on, not the organiser).
/// Every write reloads the view (R35).
class BeaconScreen extends StatefulWidget {
  const BeaconScreen({super.key, required this.beaconId});

  final String beaconId;

  @override
  State<BeaconScreen> createState() => _BeaconScreenState();
}

class _BeaconScreenState extends State<BeaconScreen> {
  late final BeaconDetailCubit _cubit = BeaconDetailCubit(
    repository: context.read<BeaconsRepository>(),
    beaconId: widget.beaconId,
  )..load();

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

  /// A flag of the caller; false when no onboarding state is in scope.
  bool _flag(String name) =>
      context.read<OnboardingBloc?>()?.state.enabledFeatures.contains(name) ??
      false;

  Future<bool> _confirm({
    required String title,
    required String body,
    required String keep,
    required String action,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(keep),
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

  Future<void> _cancel() async {
    if (!await _confirm(
      title: 'Cancel this plan?',
      body: 'Everyone who joined will be told.',
      keep: 'Keep',
      action: 'Cancel plan',
    )) {
      return;
    }
    await _cubit.cancel();
  }

  Future<void> _request() async {
    final note = await showJoinNoteSheet(
      context,
      title: _cubit.state.view?.beacon.title ?? 'this plan',
    );
    if (note == null || !mounted) return;
    await _cubit.request(note);
  }

  Future<void> _leave() async {
    if (!await _confirm(
      title: 'Leave this plan?',
      body: 'Your seat opens up for someone else.',
      keep: 'Stay',
      action: 'Leave',
    )) {
      return;
    }
    await _cubit.leave();
  }

  /// Opens [path] and reloads the view on return (an edit or a removal there).
  Future<void> _open(String path) async {
    await context.push(path);
    if (mounted) await _cubit.load();
  }

  Future<void> _report(pb.Beacon b) async {
    final messenger = ScaffoldMessenger.of(context);
    final outcome = await showReportSheet(
      context,
      targetType: ReportTargetType.REPORT_TARGET_TYPE_BEACON,
      targetId: b.beaconId,
      subject: b.title,
      notFoundMessage: kReportBeaconNotFound,
    );
    thankForReport(messenger, outcome);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: AppMainColumn(
          child: BlocConsumer<BeaconDetailCubit, BeaconDetailState>(
            bloc: _cubit,
            listenWhen: (a, b) =>
                b.actionError != null && a.actionError != b.actionError,
            listener: (context, state) => ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(SnackBar(content: Text(state.actionError!))),
            builder: (context, state) => Column(
              children: [
                AppBackHeader(
                  title: 'Plan',
                  onBack: _back,
                  actions: [?_menu(state)],
                ),
                Expanded(child: _body(context, state)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget? _menu(BeaconDetailState state) {
    final view = state.view;
    if (view == null || view.viewer.canManage) return null;
    final message = _flag(kFeatureMessaging);
    final report = _flag(kFeatureReports);
    if (!message && !report) return null;
    return PopupMenuButton<String>(
      tooltip: 'Plan options',
      icon: const Icon(Icons.more_horiz),
      style: IconButton.styleFrom(
        minimumSize: const Size.square(AppSpacing.minTapTarget),
      ),
      onSelected: (value) => switch (value) {
        'message' => unawaited(
          openConversationWith(context, view.beacon.organiser),
        ),
        _ => unawaited(_report(view.beacon)),
      },
      itemBuilder: (context) => [
        if (message)
          const PopupMenuItem(
            value: 'message',
            child: AppMenuItemRow(
              icon: Icons.mail_outline,
              label: 'Message organiser',
            ),
          ),
        if (report)
          const PopupMenuItem(
            value: 'report',
            child: AppMenuItemRow(
              icon: Icons.flag_outlined,
              label: 'Report plan',
            ),
          ),
      ],
    );
  }

  Widget _body(BuildContext context, BeaconDetailState state) {
    switch (state.status) {
      case BeaconDetailStatus.loading:
        return const UserListSkeleton(rows: 2, semanticsLabel: 'Loading plan');
      case BeaconDetailStatus.error:
        final error = state.error!;
        if (error is NotFoundException) {
          return const Center(
            child: AppEmptyView(
              icon: Icons.event_busy_outlined,
              title: 'This plan is unavailable.',
            ),
          );
        }
        return Center(
          child: AppEmptyView(
            icon: Icons.error_outline,
            title: beaconsErrorMessage(error),
            action: TextButton(
              onPressed: _cubit.load,
              child: const Text('Try again'),
            ),
          ),
        );
      case BeaconDetailStatus.ready:
        return RefreshIndicator(
          onRefresh: _cubit.load,
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(AppSpacing.md),
            child: _Details(
              view: state.view!,
              busy: state.busy,
              onCancel: _cancel,
              onRequest: _request,
              onWithdraw: _cubit.withdraw,
              onLeave: _leave,
              onPeople: () => _open(AppRouter.planPeoplePath(widget.beaconId)),
              onEdit: () => _open(AppRouter.planEditPath(widget.beaconId)),
            ),
          ),
        );
    }
  }
}

class _Details extends StatelessWidget {
  const _Details({
    required this.view,
    required this.busy,
    required this.onCancel,
    required this.onRequest,
    required this.onWithdraw,
    required this.onLeave,
    required this.onPeople,
    required this.onEdit,
  });

  final pb.BeaconView view;
  final BeaconAction? busy;
  final VoidCallback onCancel;
  final VoidCallback onRequest;
  final VoidCallback onWithdraw;
  final VoidCallback onLeave;
  final VoidCallback onPeople;
  final VoidCallback onEdit;

  Widget _spinner(IconData icon, BeaconAction action) => busy == action
      ? const SizedBox(
          width: AppIconSize.sm,
          height: AppIconSize.sm,
          child: CircularProgressIndicator(strokeWidth: 2),
        )
      : Icon(icon);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final b = view.beacon;
    final v = view.viewer;
    final live =
        b.status == pb.BeaconStatus.BEACON_STATUS_OPEN ||
        b.status == pb.BeaconStatus.BEACON_STATUS_FULL;
    final canCancel = v.canManage && live;
    final idle = busy == null;
    final viewerPill = switch (v.participantState) {
      pb.ParticipantState.PARTICIPANT_STATE_REQUESTED when v.canWithdraw =>
        'Requested',
      pb.ParticipantState.PARTICIPANT_STATE_ACCEPTED when v.canLeave =>
        "You're going",
      _ => null,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (b.hidden) ...[
          const AppNoticeBanner(
            message: 'Hidden by moderation: only you can see this plan.',
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppTileIcon(icon: activityIcon(b.activity)),
            const SizedBox(width: AppSpacing.smd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    header: true,
                    child: Text(b.title, style: theme.textTheme.titleLarge),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.xs,
                    children: [
                      BeaconStatusPill(status: b.status),
                      if (viewerPill != null)
                        AppStatusPill(
                          label: viewerPill,
                          tone: AppStatusTone.info,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        _Line(icon: Icons.schedule_outlined, text: beaconWhenText(b)),
        _Line(icon: Icons.place_outlined, text: b.venue),
        _Line(icon: Icons.people_outline, text: beaconSeatsText(b)),
        _Line(
          icon: Icons.payments_outlined,
          text: 'Cost: ${costLabel(b.cost)}',
        ),
        _Line(
          icon: Icons.chat_bubble_outline,
          text: 'Chat: ${chatPreferenceLabel(b.chatPreference)}',
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            AppAvatar(url: b.organiser.avatarUrl, radius: 20),
            const SizedBox(width: AppSpacing.smd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    b.organiser.displayName.isEmpty
                        ? b.organiser.handle
                        : b.organiser.displayName,
                    style: theme.textTheme.titleSmall,
                  ),
                  Text(
                    '@${b.organiser.handle}',
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                ],
              ),
            ),
            Text(
              'Organiser',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ],
        ),
        if (b.details.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          Text(b.details, style: theme.textTheme.bodyMedium),
        ],
        if (v.canRequest) ...[
          const SizedBox(height: AppSpacing.lg),
          FilledButton.icon(
            onPressed: idle ? onRequest : null,
            icon: _spinner(Icons.person_add_alt_outlined, BeaconAction.request),
            label: const Text('Ask to join'),
          ),
        ],
        if (v.canWithdraw) ...[
          const SizedBox(height: AppSpacing.lg),
          OutlinedButton.icon(
            onPressed: idle ? onWithdraw : null,
            icon: _spinner(Icons.undo, BeaconAction.withdraw),
            label: const Text('Withdraw request'),
          ),
        ],
        if (v.canLeave) ...[
          const SizedBox(height: AppSpacing.lg),
          OutlinedButton.icon(
            onPressed: idle ? onLeave : null,
            icon: _spinner(Icons.logout, BeaconAction.leave),
            label: const Text('Leave plan'),
          ),
        ],
        if (v.canManage || v.canLeave) ...[
          const SizedBox(height: AppSpacing.lg),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              OutlinedButton.icon(
                onPressed: onPeople,
                icon: const Icon(Icons.people_outline),
                label: Text('People · ${b.acceptedCount}'),
              ),
              if (v.canManage && live)
                OutlinedButton.icon(
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Edit'),
                ),
              if (canCancel)
                OutlinedButton.icon(
                  onPressed: idle ? onCancel : null,
                  icon: _spinner(
                    Icons.event_busy_outlined,
                    BeaconAction.cancel,
                  ),
                  label: const Text('Cancel plan'),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: AppIconSize.md, color: muted),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
