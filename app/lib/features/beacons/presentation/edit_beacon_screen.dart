import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/context_pane.dart';
import '../../../core/widgets/context_pane_slots.dart';
import '../../../core/widgets/shell_geometry.dart';
import '../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import '../../../shared/widgets/primitives/app_dialog.dart';
import '../../../shared/widgets/primitives/app_empty_view.dart';
import '../../../shared/widgets/primitives/app_form_header.dart';
import '../../../shared/widgets/primitives/app_main_column.dart';
import '../../../shared/widgets/primitives/character_counter.dart';
import '../../../shared/widgets/user/user_list_skeleton.dart';
import '../../lists/domain/list_text_rules.dart' show normalizeListText;
import '../data/beacons_repository.dart';
import '../domain/beacon_labels.dart';
import '../domain/beacon_text_rules.dart';
import '../domain/beacons_feature_flag.dart';
import '../domain/plan_preview.dart';
import 'beacons_error_messages.dart';
import 'bloc/edit_beacon_cubit.dart';
import 'create_beacon_screen.dart'
    show platformPickPlanDate, platformPickPlanTime;
import 'widgets/discard_plan_dialog.dart';
import 'widgets/plan_form_fields.dart';
import 'widgets/plan_preview.dart';
import 'widgets/plan_tips.dart';

/// `/plans/:id/edit` (R34): title, details, meeting point and open spots,
/// and (F28, R12) until the plan starts its date, time, duration and cost,
/// the fields `UpdateBeacon` accepts. Activity, chat and audience are shown
/// read-only ("Set when the plan was created"); once the plan has started,
/// so are the start and the cost, with why. Save is enabled when something
/// changed, the text rules pass, a new start is 5 minutes to 30 days away
/// and open spots cover the people already going. [now], [pickDate] and
/// [pickTime] are seams for tests.
///
/// On the tablet layout (T8d, tablet plan section 4.1 PlanEdit), once the
/// plan is loaded, the form has a live preview (the plan page's own
/// `PlanSummary` with the edits) and "Tips for a good plan": band B shows
/// both in the context pane, lent by this page (a loading preview while the
/// plan loads, nothing when it fails); band A has a Preview header action
/// that opens the preview in a dialog and the tips inline at the top of the
/// form, collapsed. Phones and desktop keep today's form (ruling R-1), but
/// for the meeting point's privacy note, which shows at every width as on
/// the create form (owner, 2026-11-11).
class EditBeaconScreen extends StatefulWidget {
  const EditBeaconScreen({
    super.key,
    required this.beaconId,
    this.now,
    this.pickDate = platformPickPlanDate,
    this.pickTime = platformPickPlanTime,
  });

  final String beaconId;
  final DateTime Function()? now;
  final BeaconPickDate pickDate;
  final BeaconPickTime pickTime;

  @override
  State<EditBeaconScreen> createState() => _EditBeaconScreenState();
}

class _EditBeaconScreenState extends State<EditBeaconScreen> {
  late final EditBeaconCubit _cubit = EditBeaconCubit(
    repository: context.read<BeaconsRepository>(),
    beaconId: widget.beaconId,
  )..load();
  final _title = TextEditingController();
  final _details = TextEditingController();
  final _venue = TextEditingController();
  int? _openSpots;

  /// F28: the start (local), duration and cost as the form has them.
  DateTime? _start;
  int? _duration;
  pb.BeaconCost? _cost;
  bool _filled = false;

  /// Whether the schedule fields are on the form, decided once when it fills
  /// (a live plan that has not started). Not re-read per build: a start that
  /// passes while the form is open must not remove the fields and drop an
  /// unsaved time change; the server's `started` error explains instead.
  bool _scheduleOpen = false;
  bool _discarded = false;

  /// The plan with the edits, for the preview; null until it is loaded.
  final _draft = ValueNotifier<pb.Beacon?>(null);
  final _paneLease = ContextPaneLease();

  /// Band A's inline tips, open or closed; kept across resizes.
  var _tipsOpen = false;

  /// Band A's open Preview dialog, if any.
  ModalRoute<void>? _previewRoute;

  @override
  void initState() {
    super.initState();
    for (final c in [_title, _details, _venue]) {
      c.addListener(_changed);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _paneLease.attach(context, AppRouter.planEditPath(widget.beaconId), {
      // The loading look while the plan loads; nothing once it failed.
      ContextSectionKind.planPreview: (context) =>
          BlocBuilder<EditBeaconCubit, EditBeaconState>(
            bloc: _cubit,
            buildWhen: (a, b) => (a.error == null) != (b.error == null),
            builder: (context, state) => state.error != null
                ? const SizedBox.shrink()
                : ValueListenableBuilder<pb.Beacon?>(
                    valueListenable: _draft,
                    builder: (context, draft, _) =>
                        PlanPreviewCard(beacon: draft),
                  ),
          ),
      // Only beside a loaded plan.
      ContextSectionKind.planTips: (context) =>
          ValueListenableBuilder<pb.Beacon?>(
            valueListenable: _draft,
            builder: (context, draft, _) =>
                draft == null ? const SizedBox.shrink() : const PlanTipsCard(),
          ),
    });
  }

  @override
  void dispose() {
    _paneLease.dispose();
    _draft.dispose();
    _title.dispose();
    _details.dispose();
    _venue.dispose();
    _cubit.close();
    super.dispose();
  }

  void _changed() => _update(() {});

  /// Every change to the form goes through here, so the preview follows it.
  void _update(VoidCallback change) {
    setState(change);
    _syncDraft();
  }

  void _syncDraft() {
    final b = _filled ? _cubit.state.view?.beacon : null;
    if (b == null) {
      _draft.value = null;
      return;
    }
    final schedule = _scheduleEditable(b);
    _draft.value = editedPlan(
      b,
      title: _title.text,
      details: _details.text,
      venue: _venue.text,
      openSpots: _openSpots ?? b.openSpots,
      startAt: schedule && _startChanged(b) ? _start : null,
      durationMinutes: schedule ? _duration : null,
      cost: schedule ? _cost : null,
    );
  }

  void _fill(pb.Beacon b) {
    if (_filled) return;
    _filled = true;
    _scheduleOpen = _live(b) && _now().isBefore(_storedStart(b));
    _title.text = b.title;
    _details.text = b.details;
    _venue.text = b.venue;
    _openSpots = b.openSpots;
    _start = _storedStart(b);
    _duration = b.durationMinutes;
    _cost = b.cost;
  }

  /// The duration chips. A stored length that is not one of them (another
  /// client set it) is shown, selected, in its place rather than leaving
  /// nothing selected.
  List<int> _durationChoices() {
    final d = _duration;
    if (d == null || kBeaconDurations.contains(d)) return kBeaconDurations;
    return ([...kBeaconDurations, d]..sort());
  }

  DateTime _now() => (widget.now ?? DateTime.now)();

  static DateTime _storedStart(pb.Beacon b) => b.startAt.toDateTime().toLocal();

  static bool _live(pb.Beacon b) =>
      b.status == pb.BeaconStatus.BEACON_STATUS_OPEN ||
      b.status == pb.BeaconStatus.BEACON_STATUS_FULL;

  /// F28: start, duration and cost change only on a live plan that has not
  /// started (the server refuses them after the stored start, "started").
  bool _scheduleEditable(pb.Beacon b) => _scheduleOpen;

  /// Whether the form's start is another minute than the stored one (the
  /// pickers set minutes; a stored start's seconds are not a change).
  bool _startChanged(pb.Beacon b) {
    final start = _start;
    if (start == null) return false;
    final stored = _storedStart(b);
    return DateTime(
          start.year,
          start.month,
          start.day,
          start.hour,
          start.minute,
        ) !=
        DateTime(
          stored.year,
          stored.month,
          stored.day,
          stored.hour,
          stored.minute,
        );
  }

  /// A new start is checked as on the create form; the stored one is not
  /// (a title edit of a plan starting in 3 minutes still saves).
  BeaconTimeIssue? _timeIssue(pb.Beacon b) =>
      _scheduleEditable(b) && _startChanged(b)
      ? beaconStartIssue(_start!, _now())
      : null;

  Future<void> _pickDate() async {
    final now = _now();
    final start = _start ?? now;
    final picked = await widget.pickDate(
      context,
      initial: start.isBefore(now) ? now : start,
      first: now,
      last: now.add(kBeaconMaxLead),
    );
    if (picked == null || !mounted) return;
    _update(() {
      _start = DateTime(
        picked.year,
        picked.month,
        picked.day,
        start.hour,
        start.minute,
      );
    });
  }

  Future<void> _pickTime() async {
    final start = _start ?? _now();
    final picked = await widget.pickTime(
      context,
      initial: TimeOfDay.fromDateTime(start),
    );
    if (picked == null || !mounted) return;
    _update(() {
      _start = DateTime(
        start.year,
        start.month,
        start.day,
        picked.hour,
        picked.minute,
      );
    });
  }

  /// Band A's Preview (tablet plan section 4.1: "header action that opens a
  /// Preview dialog"): a D 560 dialog on the content area that follows the
  /// form.
  void _openPreview() => showAppDialog<void>(
    context: context,
    maxWidth: AppSize.dialogMax,
    builder: (dialogContext) {
      _previewRoute = ModalRoute.of(dialogContext);
      return AppDialog(
        title: kPlanPreviewTitle,
        body: ValueListenableBuilder<pb.Beacon?>(
          valueListenable: _draft,
          // The dialog pads its title and body already: the preview's lines
          // start where the title does.
          builder: (context, draft, _) => draft == null
              ? const SizedBox.shrink()
              : PlanPreview(beacon: draft, inset: 0),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
        ],
      );
    },
  ).whenComplete(() => _previewRoute = null);

  /// Band A's Preview dialog belongs to band A: past 840 the pane shows the
  /// preview (it would show twice, once behind the scrim), and at 1200 or
  /// under 600 there is no preview. When the header action goes away with
  /// the dialog open, the dialog is popped after that frame.
  void _closePreviewOffBandA(bool previewAction) {
    final route = _previewRoute;
    if (previewAction || route == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Once per dialog, however many builds asked.
      if (!identical(_previewRoute, route) || !route.isActive) return;
      _previewRoute = null;
      final navigator = route.navigator;
      if (navigator == null) return;
      if (route.isCurrent) {
        navigator.maybePop();
      } else {
        navigator.removeRoute(route);
      }
    });
  }

  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRouter.planPath(widget.beaconId));
    }
  }

  /// Toolbar Cancel, platform back and the back gesture. Asks first when
  /// there are unsaved edits; no exit while the save is in flight.
  Future<void> _requestExit() async {
    final state = _cubit.state;
    final b = _filled ? state.view?.beacon : null;
    if (state.busy) return;
    if (b != null && _dirty(b)) {
      final discard = await confirmDiscardPlan(
        context,
        title: 'Discard your changes?',
        body: 'Your edits to this plan will not be saved.',
      );
      if (!discard || !mounted) return;
      setState(() => _discarded = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _back();
      });
      return;
    }
    _back();
  }

  bool _dirty(pb.Beacon b) =>
      normalizeListText(_title.text) != b.title ||
      normalizeListText(_details.text) != b.details ||
      normalizeListText(_venue.text) != b.venue ||
      _openSpots != b.openSpots ||
      (_scheduleEditable(b) &&
          (_startChanged(b) ||
              _duration != b.durationMinutes ||
              _cost != b.cost));

  bool _valid(pb.Beacon b) =>
      beaconTitleIssue(_title.text) == null &&
      beaconDetailsIssue(_details.text) == null &&
      beaconVenueIssue(_venue.text) == null &&
      _timeIssue(b) == null &&
      (_openSpots ?? 0) >=
          b.acceptedCount.clamp(kBeaconMinSpots, kBeaconMaxSpots);

  void _save() {
    final b = _cubit.state.view!.beacon;
    final schedule = _scheduleEditable(b);
    _cubit.save(
      title: normalizeListText(_title.text),
      details: normalizeListText(_details.text),
      venue: normalizeListText(_venue.text),
      openSpots: _openSpots!,
      startAt: schedule && _startChanged(b) ? _start : null,
      durationMinutes: schedule ? _duration : null,
      cost: schedule ? _cost : null,
    );
  }

  Widget _counter(TextEditingController c, int max) =>
      CharacterCounter(remaining: max - beaconTextLength(c.text));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The tablet layout: band A gets the Preview header action and the
    // inline tips once the plan is loaded; band B shows both in the context
    // pane instead. Phones and desktop keep today's form (ruling R-1).
    final tablet = ShellGeometry.maybeOf(context)?.tablet ?? false;
    final previewInPane = ContextPaneScope.shows(
      context,
      ContextSectionKind.planPreview,
    );
    final tipsInPane = ContextPaneScope.shows(
      context,
      ContextSectionKind.planTips,
    );
    return Scaffold(
      body: SafeArea(
        child: AppMainColumn(
          child: BlocConsumer<EditBeaconCubit, EditBeaconState>(
            bloc: _cubit,
            listenWhen: (a, b) =>
                (a.saved != b.saved && b.saved != null) ||
                (a.view == null && b.view != null),
            listener: (context, state) {
              // The controllers are filled here, outside build (their listeners
              // call setState).
              if (state.view != null && !_filled) {
                _update(() => _fill(state.view!.beacon));
              }
              if (state.saved != null) _back();
            },
            builder: (context, state) {
              final b = _filled ? state.view?.beacon : null;
              final busy = state.busy;
              final previewAction = tablet && !previewInPane && b != null;
              final tipsInline = tablet && !tipsInPane && b != null;
              _closePreviewOffBandA(previewAction);
              final minSpots = b == null
                  ? kBeaconMinSpots
                  : b.acceptedCount.clamp(kBeaconMinSpots, kBeaconMaxSpots);
              return PopScope(
                canPop:
                    state.saved != null ||
                    _discarded ||
                    (!busy && (b == null || !_dirty(b))),
                onPopInvokedWithResult: (didPop, _) {
                  if (!didPop) _requestExit();
                },
                child: Column(
                  children: [
                    AppFormHeader(
                      title: 'Edit plan',
                      actionLabel: 'Save',
                      busy: busy,
                      busySemanticsLabel: 'Saving plan',
                      onCancel: _requestExit,
                      onAction: b != null && !busy && _dirty(b) && _valid(b)
                          ? _save
                          : null,
                      secondaryLabel: previewAction ? kPlanPreviewTitle : null,
                      onSecondary: previewAction ? _openPreview : null,
                    ),
                    Expanded(
                      child: state.loading
                          ? const UserListSkeleton(
                              rows: 2,
                              semanticsLabel: 'Loading plan',
                            )
                          : state.error != null
                          ? Center(
                              child: AppEmptyView(
                                icon: Icons.error_outline,
                                title: beaconsErrorMessage(state.error!),
                                action: TextButton(
                                  onPressed: _cubit.load,
                                  child: const Text('Try again'),
                                ),
                              ),
                            )
                          : SingleChildScrollView(
                              padding: const EdgeInsets.all(AppSpacing.md),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  // Always one child here, so the fields keep
                                  // their place when the tips move to the
                                  // pane at 840.
                                  if (tipsInline)
                                    PlanTipsSection(
                                      expanded: _tipsOpen,
                                      onToggle: () => setState(
                                        () => _tipsOpen = !_tipsOpen,
                                      ),
                                    )
                                  else
                                    const SizedBox.shrink(),
                                  TextField(
                                    controller: _title,
                                    enabled: !busy,
                                    textInputAction: TextInputAction.next,
                                    decoration: InputDecoration(
                                      labelText: 'Title',
                                      errorText: beaconFieldError(
                                        beaconTitleIssue(_title.text),
                                        max: kBeaconTitleMaxLength,
                                      ),
                                      counter: _counter(
                                        _title,
                                        kBeaconTitleMaxLength,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: AppSpacing.md),
                                  TextField(
                                    controller: _details,
                                    enabled: !busy,
                                    minLines: 2,
                                    maxLines: 4,
                                    decoration: InputDecoration(
                                      labelText: 'Details',
                                      errorText: beaconFieldError(
                                        beaconDetailsIssue(_details.text),
                                        max: kBeaconDetailsMaxLength,
                                      ),
                                      counter: _counter(
                                        _details,
                                        kBeaconDetailsMaxLength,
                                      ),
                                    ),
                                  ),
                                  if (b != null && _scheduleEditable(b)) ...[
                                    PlanWhenFields(
                                      start: _start!,
                                      enabled: !busy,
                                      onPickDate: _pickDate,
                                      onPickTime: _pickTime,
                                      helper: kPlanEditNotifyHelper,
                                      error: beaconTimeError(_timeIssue(b)),
                                    ),
                                    PlanFormSection(
                                      title: 'Duration',
                                      child: PlanChoiceChips<int>(
                                        values: _durationChoices(),
                                        selected: _duration!,
                                        label: (m) => '$m min',
                                        enabled: !busy,
                                        onSelected: (m) =>
                                            _update(() => _duration = m),
                                      ),
                                    ),
                                  ],
                                  const SizedBox(height: AppSpacing.md),
                                  TextField(
                                    controller: _venue,
                                    enabled: !busy,
                                    textInputAction: TextInputAction.done,
                                    decoration: InputDecoration(
                                      labelText: 'Meeting point',
                                      // The privacy note, as on the create
                                      // form, at every width (ruling 3,
                                      // owner 2026-11-11).
                                      helperText: kMeetingPointNote,
                                      errorText: beaconFieldError(
                                        beaconVenueIssue(_venue.text),
                                        max: kBeaconVenueMaxLength,
                                      ),
                                      counter: _counter(
                                        _venue,
                                        kBeaconVenueMaxLength,
                                      ),
                                    ),
                                  ),
                                  if (b != null && _scheduleEditable(b))
                                    PlanFormSection(
                                      title: 'Cost',
                                      child: PlanChoiceChips<pb.BeaconCost>(
                                        values: kPlanCosts,
                                        selected: _cost!,
                                        label: costLabel,
                                        enabled: !busy,
                                        onSelected: (c) =>
                                            _update(() => _cost = c),
                                      ),
                                    ),
                                  PlanSpotsStepper(
                                    value: _openSpots ?? 0,
                                    min: minSpots,
                                    max: kBeaconMaxSpots,
                                    enabled: !busy,
                                    onChanged: (n) =>
                                        _update(() => _openSpots = n),
                                    helper: b != null && b.acceptedCount > 0
                                        ? '${b.acceptedCount} already going; '
                                              'the spots cannot go below that.'
                                        : null,
                                  ),
                                  if (b != null) ...[
                                    const SizedBox(height: AppSpacing.lg),
                                    _ReadOnly(
                                      beacon: b,
                                      started: !_scheduleEditable(b),
                                    ),
                                  ],
                                  if (state.saveError != null) ...[
                                    const SizedBox(height: AppSpacing.md),
                                    Semantics(
                                      liveRegion: true,
                                      child: Text(
                                        state.saveError!,
                                        style: theme.textTheme.bodyMedium
                                            ?.copyWith(
                                              color: theme.colorScheme.error,
                                            ),
                                      ),
                                    ),
                                  ],
                                  const SizedBox(height: AppSpacing.lg),
                                ],
                              ),
                            ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// What the form does not change, shown as it is (the designs' "Set when
/// the plan was created"): the activity and chat, and the audience. Once
/// the plan has started ([started]), the start and the cost too, with why.
class _ReadOnly extends StatelessWidget {
  const _ReadOnly({required this.beacon, required this.started});

  final pb.Beacon beacon;
  final bool started;

  @override
  Widget build(BuildContext context) {
    final b = beacon;
    final audience = b.communityId.isEmpty ? 'Public' : 'Community';
    return PlanReadOnlyBox(
      title: started ? kPlanFixedNow : kPlanSetAtCreation,
      lines: [
        if (started) ...[
          'Starts ${beaconWhenText(b)}',
          'Cost: ${costLabel(b.cost)}',
        ],
        '${activityLabel(b.activity)} · Chat: '
            '${chatPreferenceLabel(b.chatPreference)}',
        'Who can see it: $audience',
      ],
      note: started ? kPlanStartedNote : null,
    );
  }
}
