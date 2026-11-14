import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/shell_bottom_inset_sliver.dart';
import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/shell_geometry.dart';
import '../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import '../../../gen/dzeroth/moderation/v1/moderation.pbenum.dart';
import '../../../shared/widgets/primitives/app_avatar.dart';
import '../../../shared/widgets/primitives/app_back_header.dart';
import '../../../shared/widgets/primitives/app_empty_view.dart';
import '../../../shared/widgets/primitives/app_main_column.dart';
import '../../../shared/widgets/primitives/app_menu_item_row.dart';
import '../../../shared/widgets/primitives/app_notice_banner.dart';
import '../../messages/domain/messaging_feature_flag.dart';
import '../../messages/presentation/open_conversation.dart';
import '../../messages/presentation/report_conversation.dart'
    show thankForReport;
import '../../moderation/domain/reports_feature_flag.dart';
import '../../moderation/presentation/report_sheet.dart';
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../data/beacons_repository.dart';
import '../domain/beacon_labels.dart';
import 'beacons_error_messages.dart';
import 'bloc/beacon_detail_cubit.dart';
import 'bloc/beacon_detail_state.dart';
import 'bloc/plans_session.dart';
import 'plans_list_detail.dart';
import 'widgets/join_note_sheet.dart';
import 'widgets/quick_join.dart';
import 'widgets/plan_skeletons.dart';
import 'widgets/plan_summary.dart';
import '../../../shared/widgets/primitives/app_card.dart';
import '../../../shared/widgets/primitives/app_dialog.dart';
import '../../../shared/widgets/primitives/app_pill_button.dart';
import '../../../shared/widgets/primitives/app_status_pill.dart';
import 'beacon_people_screen.dart' show kPeopleListNote;

/// The NOT_FOUND text of the plan report sheet.
const kReportBeaconNotFound = "This plan isn't available to report any more.";

/// `/plans/:id` (R32, R37): the server's view of one plan. The buttons follow
/// `ViewerState`: Ask to join, Withdraw request, Leave plan; the organiser's
/// People, Edit and Cancel plan. The menu offers Message organiser (messaging
/// on, not the organiser) and Report plan (reports on, not the organiser).
/// Every write reloads the view (R35).
///
/// The meeting point line carries its privacy note ([kMeetingPointNote]) at
/// every width (tablet plan section 3, R-inline). In band B of the tablet
/// layout the Plans list sits beside this page ([PlansMasterScope]): no back
/// arrow, and each write (or a return from Edit or People) reloads the list
/// there too, since nothing returns to it.
class BeaconScreen extends StatefulWidget {
  const BeaconScreen({super.key, required this.beaconId});

  final String beaconId;

  @override
  State<BeaconScreen> createState() => _BeaconScreenState();
}

class _BeaconScreenState extends State<BeaconScreen> {
  late BeaconDetailCubit _cubit = _newCubit();

  BeaconDetailCubit _newCubit() => BeaconDetailCubit(
    repository: context.read<BeaconsRepository>(),
    beaconId: widget.beaconId,
  )..load();

  /// Another plan in the same page: band B's list pane replaces the detail
  /// with `go`, which keeps this page and hands it the new id.
  @override
  void didUpdateWidget(BeaconScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.beaconId == widget.beaconId) return;
    unawaited(_cubit.close());
    _cubit = _newCubit();
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
    final confirmed = await showAppMaterialDialog<bool>(
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

  /// Band B: the list pane beside this page reloads what it shows (a
  /// cancelled plan, a seat taken, "Your plans"). Elsewhere the list reloads
  /// when it comes back into view, as before.
  ///
  /// Decided by the band, not by [PlansMasterScope]: on the way back from a
  /// pushed Edit or People the shell has not put the pane back yet.
  void _listChanged() {
    if (!mounted) return;
    final geometry = ShellGeometry.maybeOf(context);
    if (geometry == null ||
        !geometry.tablet ||
        geometry.band != ShellBand.expanded) {
      return;
    }
    context.read<PlansSession?>()?.refreshAfterWrite();
  }

  Future<void> _cancel() async {
    if (!await _confirm(
      title: 'Cancel this plan?',
      body: 'People who joined will get a notification.',
      keep: 'Keep',
      action: 'Cancel plan',
    )) {
      return;
    }
    await _cubit.cancel();
    _listChanged();
  }

  Future<void> _request() async {
    final viewer = _cubit.state.view?.viewer;
    final title = _cubit.state.view?.beacon.title ?? 'this plan';
    // `beacon_quick_join` on and the organiser does not follow the viewer:
    // the note is required.
    final noteRequired =
        quickJoinEnabled(context, listen: false) &&
        !(viewer?.quickJoinAllowed ?? false);
    final note = await showJoinNoteSheet(
      context,
      title: title,
      noteRequired: noteRequired,
    );
    if (note == null || !mounted) return;
    await _cubit.request(note);
    _listChanged();
  }

  /// "I'm in": RequestToJoin with an empty note; a `note_required` answer
  /// opens the sheet.
  Future<void> _quickJoin() async {
    await quickJoin(
      context,
      _cubit,
      title: _cubit.state.view?.beacon.title ?? 'this plan',
    );
    _listChanged();
  }

  Future<void> _withdraw() async {
    await _cubit.withdraw();
    _listChanged();
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
    _listChanged();
  }

  /// Opens [path] and reloads the view on return (an edit or a removal there).
  Future<void> _open(String path) async {
    await context.push(path);
    if (!mounted) return;
    await _cubit.load();
    _listChanged();
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
      body: BlocConsumer<BeaconDetailCubit, BeaconDetailState>(
        bloc: _cubit,
        listenWhen: (a, b) =>
            b.actionError != null && a.actionError != b.actionError,
        listener: (context, state) => ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(state.actionError!))),
        builder: (context, state) => SafeArea(
          // The floating bar overlays the page: the scroll view runs behind
          // it and ends with the bar's inset.
          bottom: false,
          child: AppMainColumn(
            // The ready page opens with its own hero (Back and the menu in
            // it); the loading and failed pages keep the plain header. The
            // column centres its child, so the page takes all of its height.
            child: state.status == BeaconDetailStatus.ready
                ? SizedBox.expand(child: _ready(context, state))
                : Column(
                    children: [
                      AppBackHeader(
                        title: 'Plan',
                        onBack: _back,
                        // Band B: the list is beside it, so no back arrow.
                        leading: PlansMasterScope.shownOf(context)
                            ? const SizedBox(width: AppSpacing.sm)
                            : null,
                      ),
                      Expanded(child: _unready(state)),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  /// The plan's menu: Report plan (reports on, not the organiser's own plan).
  Widget? _menu(BeaconDetailState state) {
    final view = state.view;
    if (view == null || view.viewer.canManage || !_flag(kFeatureReports)) {
      return null;
    }
    return _HeroButton(
      child: PopupMenuButton<String>(
        tooltip: 'Plan options',
        icon: const Icon(Icons.more_horiz, color: AppPalette.pearl),
        style: IconButton.styleFrom(
          minimumSize: const Size.square(AppPlansLayout.heroButton),
        ),
        onSelected: (_) => unawaited(_report(view.beacon)),
        itemBuilder: (context) => const [
          PopupMenuItem(
            value: 'report',
            child: AppMenuItemRow(
              icon: Icons.flag_outlined,
              label: 'Report plan',
            ),
          ),
        ],
      ),
    );
  }

  /// Back and the menu over the hero (the designs' PlanDetail).
  Widget _heroBar(BeaconDetailState state) {
    final menu = _menu(state);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        // Band B: the list is beside it, so no back arrow.
        if (PlansMasterScope.shownOf(context))
          const SizedBox.shrink()
        else
          _HeroButton(
            child: IconButton(
              tooltip: 'Back',
              icon: const Icon(Icons.arrow_back, color: AppPalette.pearl),
              style: IconButton.styleFrom(
                minimumSize: const Size.square(AppPlansLayout.heroButton),
              ),
              onPressed: _back,
            ),
          ),
        ?menu,
      ],
    );
  }

  /// The loading and failed pages (the header is drawn around them).
  Widget _unready(BeaconDetailState state) {
    if (state.status == BeaconDetailStatus.loading) {
      return const PlanDetailSkeleton();
    }
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
  }

  Widget _ready(BuildContext context, BeaconDetailState state) {
    return RefreshIndicator(
      onRefresh: _cubit.load,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: shellBottomInsets(context),
        child: _Details(
          view: state.view!,
          faces: state.faces,
          busy: state.busy,
          heroBar: _heroBar(state),
          canMessage: _flag(kFeatureMessaging),
          onMessage: () =>
              openConversationWith(context, state.view!.beacon.organiser),
          onCancel: _cancel,
          onRequest: _request,
          onQuickJoin: _quickJoin,
          onWithdraw: _withdraw,
          onLeave: _leave,
          onPeople: () => _open(AppRouter.planPeoplePath(widget.beaconId)),
          onEdit: () => _open(AppRouter.planEditPath(widget.beaconId)),
        ),
      ),
    );
  }
}

/// A 44 dp translucent circle on the hero (the designs' round buttons on the
/// navy): [child] is its icon button.
class _HeroButton extends StatelessWidget {
  const _HeroButton({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: AppPalette.pearl.withValues(alpha: 0.08),
      border: Border.all(color: AppPalette.pearl.withValues(alpha: 0.14)),
    ),
    child: child,
  );
}

/// The plan page (R12, the designs' PlanDetail and PlanDetail-Visitor):
/// [PlanSummary] (the hero with Back and the menu, the organiser row with the
/// organiser's Edit or the viewer's state and Message organiser, the
/// details), the hidden-by-moderation banner, the People card, then the
/// viewer's one action as a full-width pill with its line of explanation.
class _Details extends StatelessWidget {
  const _Details({
    required this.view,
    this.faces = const [],
    required this.busy,
    required this.heroBar,
    required this.canMessage,
    required this.onMessage,
    required this.onCancel,
    required this.onRequest,
    required this.onQuickJoin,
    required this.onWithdraw,
    required this.onLeave,
    required this.onPeople,
    required this.onEdit,
  });

  final pb.BeaconView view;

  /// Up to 3 people going, for the People card (empty when the viewer may not
  /// list them).
  final List<pb.Participant> faces;
  final BeaconAction? busy;
  final Widget heroBar;

  /// Messaging is on for the caller: Message organiser (not on their own
  /// plan).
  final bool canMessage;
  final VoidCallback onMessage;
  final VoidCallback onCancel;
  final VoidCallback onRequest;
  final VoidCallback onQuickJoin;
  final VoidCallback onWithdraw;
  final VoidCallback onLeave;
  final VoidCallback onPeople;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
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
    final organiser = b.organiser.displayName.isEmpty
        ? '@${b.organiser.handle}'
        : b.organiser.displayName;
    final mayList = v.canManage || v.canLeave;
    final quick = showsQuickJoin(context, v);
    Widget action({
      required String label,
      required AppButtonVariant variant,
      required BeaconAction kind,
      required VoidCallback onPressed,
      required String busyLabel,
      required String note,
    }) => Padding(
      padding: const EdgeInsets.only(top: AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppPillButton(
            label: label,
            variant: variant,
            size: AppButtonSize.large,
            busy: busy == kind,
            busySemanticsLabel: busyLabel,
            onPressed: idle ? onPressed : null,
          ),
          const SizedBox(height: AppSpacing.sm),
          _Footnote(note),
        ],
      ),
    );
    final message = canMessage && !v.canManage;
    final trailing = [
      if (v.canManage && live)
        AppPillButton(
          label: 'Edit',
          variant: AppButtonVariant.outline,
          compact: true,
          onPressed: onEdit,
        ),
      if (viewerPill != null)
        AppStatusPill(label: viewerPill, tone: AppStatusTone.info),
      if (message)
        AppPillButton(
          label: 'Message organiser',
          variant: AppButtonVariant.outline,
          compact: true,
          onPressed: onMessage,
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PlanSummary(
          beacon: b,
          heroBar: heroBar,
          organiserTrailing: trailing.isEmpty
              ? null
              : Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.xs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: trailing,
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppPlansLayout.heroGutter,
            AppSpacing.md,
            AppPlansLayout.heroGutter,
            AppSpacing.lg,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (b.hidden) ...[
                const AppNoticeBanner(
                  message: 'Hidden by moderation: only you can see this plan.',
                ),
                const SizedBox(height: AppSpacing.md),
              ],
              _PeopleCard(
                beacon: b,
                faces: faces,
                onTap: mayList ? onPeople : null,
              ),
              if (!mayList) ...[
                const SizedBox(height: AppSpacing.sm),
                const _Footnote(kPeopleListNote, center: false),
              ],
              if (v.canRequest)
                action(
                  label: quick ? kPlanImIn : 'Ask to join',
                  variant: AppButtonVariant.primary,
                  kind: BeaconAction.request,
                  onPressed: quick ? onQuickJoin : onRequest,
                  busyLabel: 'Sending request',
                  note: '$organiser approves each request.',
                ),
              if (v.canWithdraw)
                action(
                  label: 'Withdraw request',
                  variant: AppButtonVariant.outline,
                  kind: BeaconAction.withdraw,
                  onPressed: onWithdraw,
                  busyLabel: 'Withdrawing request',
                  note: '$organiser approves each request.',
                ),
              if (v.canLeave)
                action(
                  label: 'Leave plan',
                  variant: AppButtonVariant.outline,
                  kind: BeaconAction.leave,
                  onPressed: onLeave,
                  busyLabel: 'Leaving plan',
                  note: 'Everyone going can see who else is going.',
                ),
              if (canCancel)
                action(
                  label: 'Cancel plan',
                  variant: AppButtonVariant.outline,
                  kind: BeaconAction.cancel,
                  onPressed: onCancel,
                  busyLabel: 'Cancelling plan',
                  note:
                      'You approve each request. Cancel plan asks first; '
                      'people who joined get a notification.',
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A muted line of explanation under an action (or the People card).
class _Footnote extends StatelessWidget {
  const _Footnote(this.text, {this.center = true});

  final String text;
  final bool center;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      textAlign: center ? TextAlign.center : TextAlign.start,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// "People · N going" and the open spots, as a raised card (the designs'
/// PlanDetail). With [onTap] (the organiser and the people going, who may
/// see the list) it opens People and has a chevron; otherwise it only says
/// the counts.
class _PeopleCard extends StatelessWidget {
  const _PeopleCard({
    required this.beacon,
    required this.onTap,
    this.faces = const [],
  });

  final pb.Beacon beacon;

  /// The first people going; with them the card adds the faces and "Riya and
  /// 2 others are going". Without, the title's count is all it says.
  final List<pb.Participant> faces;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final b = beacon;
    final open = (b.openSpots - b.acceptedCount).clamp(0, b.openSpots);
    final title = 'People · ${b.acceptedCount} going';
    final going = goingSentence(
      faces
          .map(
            (p) => p.user.displayName.isEmpty
                ? '@${p.user.handle}'
                : p.user.displayName,
          )
          .toList(),
      b.acceptedCount,
    );
    final spots = open == 1 ? '1 open spot left' : '$open open spots left';
    final content = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: AppSpacing.minTapTarget),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(
              Icons.people_outline,
              color: context.appColors.accentText,
              size: AppIconSize.md,
            ),
            const SizedBox(width: AppSpacing.smd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleSmall),
                  if (faces.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.xs),
                    Row(
                      key: const ValueKey('plan-going-faces'),
                      children: [
                        AppAvatarStack(
                          total: b.acceptedCount < faces.length
                              ? faces.length
                              : b.acceptedCount,
                          maxVisible: 3,
                          items: [
                            for (final p in faces)
                              AppAvatarStackItem(
                                url: p.user.avatarUrl,
                                name: p.user.displayName.isEmpty
                                    ? '@${p.user.handle}'
                                    : p.user.displayName,
                              ),
                          ],
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Text(
                            going,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurface,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.xs),
                  ],
                  Text(
                    spots,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (onTap != null)
              Icon(
                Icons.chevron_right,
                color: theme.colorScheme.onSurfaceVariant,
              ),
          ],
        ),
      ),
    );
    return Semantics(
      key: const ValueKey('plan-people-card'),
      container: true,
      button: onTap != null,
      label: [title, if (faces.isNotEmpty) going, spots].join(', '),
      onTap: onTap,
      excludeSemantics: true,
      child: AppCard(
        padding: EdgeInsets.zero,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(AppRadius.card),
            child: content,
          ),
        ),
      ),
    );
  }
}
