import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import '../../../shared/widgets/primitives/app_dialog.dart';
import '../../../shared/widgets/primitives/app_empty_view.dart';
import '../../../shared/widgets/primitives/app_form_header.dart';
import '../../../shared/widgets/primitives/app_main_column.dart';
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
/// Once the plan is loaded, at every width the header has a Preview action
/// that opens the plan page's own `PlanSummary` with the edits in a dialog,
/// and the tips ("Tips for a good plan") sit inline at the top of the form,
/// collapsed. Cost and Open spots share a row where the column has room for
/// both. The meeting point's privacy note shows at every width as on the
/// create form (owner, 2026-11-11). The date and time pickers are dialogs on
/// the content area on the tablet layout.
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

  /// The inline tips, open or closed.
  var _tipsOpen = false;

  @override
  void initState() {
    super.initState();
    for (final c in [_title, _details, _venue]) {
      c.addListener(_changed);
    }
  }

  @override
  void dispose() {
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

  /// The Preview dialog: it follows the form while it is open.
  void _openPreview() => showAppDialog<void>(
    context: context,
    maxWidth: AppSize.dialogMax,
    builder: (dialogContext) => AppDialog(
      title: kPlanPreviewTitle,
      body: ValueListenableBuilder<pb.Beacon?>(
        valueListenable: _draft,
        // The dialog pads its title and body already: the preview's lines
        // start where the title does.
        builder: (context, draft, _) => draft == null
            ? const SizedBox.shrink()
            : PlanPreview(beacon: draft),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );

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

  int _left(TextEditingController c, int max) => max - beaconTextLength(c.text);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
              final minSpots = b == null
                  ? kBeaconMinSpots
                  : b.acceptedCount.clamp(kBeaconMinSpots, kBeaconMaxSpots);
              final spots = PlanSpotsStepper(
                value: _openSpots ?? 0,
                min: minSpots,
                max: kBeaconMaxSpots,
                enabled: !busy,
                onChanged: (n) => _update(() => _openSpots = n),
                helper: b != null && b.acceptedCount > 0
                    ? '${b.acceptedCount} already going; '
                          'the spots cannot go below that.'
                    : null,
              );
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
                      secondaryLabel: b == null ? null : kPlanPreviewTitle,
                      onSecondary: b == null ? null : _openPreview,
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
                                  if (b != null)
                                    PlanTipsSection(
                                      expanded: _tipsOpen,
                                      onToggle: () => setState(
                                        () => _tipsOpen = !_tipsOpen,
                                      ),
                                    ),
                                  PlanTextField(
                                    label: 'Title',
                                    controller: _title,
                                    enabled: !busy,
                                    textInputAction: TextInputAction.next,
                                    remaining: _left(
                                      _title,
                                      kBeaconTitleMaxLength,
                                    ),
                                    error: beaconFieldError(
                                      beaconTitleIssue(_title.text),
                                      max: kBeaconTitleMaxLength,
                                    ),
                                  ),
                                  PlanTextField(
                                    label: 'Details',
                                    controller: _details,
                                    enabled: !busy,
                                    minLines: 2,
                                    maxLines: 4,
                                    remaining: _left(
                                      _details,
                                      kBeaconDetailsMaxLength,
                                    ),
                                    error: beaconFieldError(
                                      beaconDetailsIssue(_details.text),
                                      max: kBeaconDetailsMaxLength,
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
                                  PlanTextField(
                                    label: 'Meeting point',
                                    controller: _venue,
                                    enabled: !busy,
                                    textInputAction: TextInputAction.done,
                                    remaining: _left(
                                      _venue,
                                      kBeaconVenueMaxLength,
                                    ),
                                    helper: kMeetingPointNote,
                                    error: beaconFieldError(
                                      beaconVenueIssue(_venue.text),
                                      max: kBeaconVenueMaxLength,
                                    ),
                                  ),
                                  if (b != null && _scheduleEditable(b))
                                    PlanPair(
                                      first: PlanFormSection(
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
                                      second: spots,
                                    )
                                  else
                                    spots,
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
