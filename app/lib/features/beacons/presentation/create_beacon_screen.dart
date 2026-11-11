import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart'
    as ts;

import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/context_pane.dart';
import '../../../core/widgets/context_pane_slots.dart';
import '../../../core/widgets/shell_geometry.dart';
import '../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import '../../../gen/dzeroth/common/v1/common.pb.dart' as common;
import '../../../shared/format/scheduled_time.dart';
import '../../../shared/widgets/primitives/app_dialog.dart';
import '../../../shared/widgets/primitives/app_form_header.dart';
import '../../../shared/widgets/primitives/app_main_column.dart';
import '../../../shared/widgets/primitives/app_pickers.dart';
import '../../../shared/widgets/primitives/character_counter.dart';
import '../../communities/data/communities_repository.dart';
import '../../lists/domain/list_text_rules.dart' show normalizeListText;
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../data/beacons_repository.dart';
import '../domain/beacon_labels.dart';
import '../domain/beacon_text_rules.dart';
import '../domain/beacons_feature_flag.dart';
import '../domain/plan_preview.dart';
import 'bloc/beacons_state.dart' show BeaconsAudience;
import 'bloc/create_beacon_cubit.dart';
import 'widgets/discard_plan_dialog.dart';
import 'widgets/plan_preview.dart';
import 'widgets/plan_tips.dart';

/// Shows the date picker; null when dismissed. A seam so tests need not drive
/// the platform dial.
typedef BeaconPickDate = Future<DateTime?> Function(
  BuildContext context, {
  required DateTime initial,
  required DateTime first,
  required DateTime last,
});

/// Shows the time picker; null when dismissed.
typedef BeaconPickTime = Future<TimeOfDay?> Function(
  BuildContext context, {
  required TimeOfDay initial,
});

Future<DateTime?> _platformPickDate(
  BuildContext context, {
  required DateTime initial,
  required DateTime first,
  required DateTime last,
}) => showAppDatePicker(
  context: context,
  initialDate: initial,
  firstDate: first,
  lastDate: last,
  helpText: 'Date',
);

Future<TimeOfDay?> _platformPickTime(
  BuildContext context, {
  required TimeOfDay initial,
}) =>
    showAppTimePicker(context: context, initialTime: initial, helpText: 'Time');

/// `/plans/new` (R31): the fields of section 3 with the server's rules checked
/// before sending; one CreateBeacon per submit. [now], [pickDate] and
/// [pickTime] are seams for tests.
///
/// On the tablet layout (T8d, tablet plan section 4.1 PlanCreate) the form
/// has a live preview (the plan page's own `PlanSummary` of what it would
/// create) and "Tips for a good plan": band B shows both in the context pane,
/// lent by this page; band A has a Preview header action that opens the
/// preview in a dialog, and the tips inline at the top of the form,
/// collapsed. The date and time pickers are dialogs on the content area
/// there. Phones and desktop keep today's form (ruling R-1).
class CreateBeaconScreen extends StatefulWidget {
  const CreateBeaconScreen({
    super.key,
    this.now,
    this.pickDate = _platformPickDate,
    this.pickTime = _platformPickTime,
  });

  final DateTime Function()? now;
  final BeaconPickDate pickDate;
  final BeaconPickTime pickTime;

  @override
  State<CreateBeaconScreen> createState() => _CreateBeaconScreenState();
}

class _CreateBeaconScreenState extends State<CreateBeaconScreen> {
  late final CreateBeaconCubit _cubit = CreateBeaconCubit(
    repository: context.read<BeaconsRepository>(),
  );
  final _title = TextEditingController();
  final _details = TextEditingController();
  final _venue = TextEditingController();
  var _activity = pb.BeaconActivity.BEACON_ACTIVITY_COFFEE;
  late DateTime _startAt;
  late final DateTime _initialStart;
  var _discarded = false;
  var _durationMinutes = 60;
  var _openSpots = 3;
  var _cost = pb.BeaconCost.BEACON_COST_FREE;
  var _chat = pb.ChatPreference.CHAT_PREFERENCE_QUIET;
  var _audiences = const [BeaconsAudience.public()];
  var _audience = const BeaconsAudience.public();

  /// The plan as typed, for the preview (band B's pane, band A's dialog).
  late final ValueNotifier<pb.Beacon> _draft;
  final _paneLease = ContextPaneLease();

  /// Band A's inline tips, open or closed; kept across resizes.
  var _tipsOpen = false;

  DateTime _now() => (widget.now ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _startAt = _initialStart = _defaultStart(_now());
    _draft = ValueNotifier(_draftPlan());
    _title.addListener(_changed);
    _details.addListener(_changed);
    _venue.addListener(_changed);
    _loadAudiences();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _paneLease.attach(context, AppRouter.planNewPath, {
      ContextSectionKind.planPreview: (context) =>
          ValueListenableBuilder<pb.Beacon>(
            valueListenable: _draft,
            builder: (context, draft, _) => PlanPreviewCard(
              beacon: draft,
              showOrganiser: draft.hasOrganiser(),
            ),
          ),
      ContextSectionKind.planTips: (context) => const PlanTipsCard(),
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

  /// One hour from now, rounded up to the next quarter hour.
  static DateTime _defaultStart(DateTime now) {
    final base = now.add(const Duration(hours: 1));
    final minutes = ((base.minute + 14) ~/ 15) * 15;
    return DateTime(base.year, base.month, base.day, base.hour, minutes);
  }

  Future<void> _loadAudiences() async {
    final communities = context.read<CommunitiesRepository?>();
    if (communities == null || !communities.enabled) return;
    try {
      final mine = await communities.myCommunities();
      if (!mounted) return;
      setState(() {
        _audiences = [
          const BeaconsAudience.public(),
          for (final c in mine.communities)
            BeaconsAudience.community(c.communityId, c.name),
        ];
      });
    } on AppException {
      // Public stays the only audience.
    }
  }

  void _changed() => _update(() {});

  /// Every change to the form goes through here, so the preview follows it.
  void _update(VoidCallback change) {
    setState(change);
    _draft.value = _draftPlan();
  }

  /// The plan the form would create, with the caller as its organiser when
  /// the profile is loaded (nothing is fetched).
  pb.Beacon _draftPlan() {
    final profile = context.read<OnboardingBloc?>()?.state.profile;
    final handle = profile?.handle ?? '';
    return draftPlan(
      activity: _activity,
      title: _title.text,
      details: _details.text,
      venue: _venue.text,
      startAt: _startAt,
      durationMinutes: _durationMinutes,
      openSpots: _openSpots,
      cost: _cost,
      chatPreference: _chat,
      organiser: profile == null || handle.isEmpty
          ? null
          : common.AuthorSnapshot(
              userId: profile.userId,
              handle: handle,
              displayName: profile.displayName,
              avatarUrl: profile.avatarThumbUrl,
            ),
    );
  }

  /// Band A's Preview (tablet plan section 4.1: "header action that opens a
  /// Preview dialog"): a D 560 dialog on the content area that follows the
  /// form.
  void _openPreview() => showAppDialog<void>(
    context: context,
    maxWidth: AppSize.dialogMax,
    builder: (dialogContext) => AppDialog(
      title: kPlanPreviewTitle,
      body: ValueListenableBuilder<pb.Beacon>(
        valueListenable: _draft,
        // The dialog pads its title and body already: the preview's lines
        // start where the title does.
        builder: (context, draft, _) => PlanPreview(
          beacon: draft,
          showOrganiser: draft.hasOrganiser(),
          inset: 0,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );

  void _cancel() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRouter.plansPath);
    }
  }

  /// Anything the user typed or changed from the defaults.
  bool get _isDirty =>
      _title.text.trim().isNotEmpty ||
      _details.text.trim().isNotEmpty ||
      _venue.text.trim().isNotEmpty ||
      _startAt != _initialStart ||
      _activity != pb.BeaconActivity.BEACON_ACTIVITY_COFFEE ||
      _durationMinutes != 60 ||
      _openSpots != 3 ||
      _cost != pb.BeaconCost.BEACON_COST_FREE ||
      _chat != pb.ChatPreference.CHAT_PREFERENCE_QUIET ||
      !_audience.isPublic;

  /// Toolbar Cancel, platform back and the back gesture all end here. A clean
  /// form leaves at once; a dirty one asks first. While the create is in
  /// flight there is no exit.
  Future<void> _requestExit() async {
    if (_cubit.state.busy) return;
    if (_isDirty) {
      final discard = await confirmDiscardPlan(
        context,
        title: 'Discard this plan?',
        body: 'What you entered will not be saved.',
      );
      if (!discard || !mounted) return;
      // canPop is true once _discarded is set, so the route can pop.
      setState(() => _discarded = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _cancel();
      });
      return;
    }
    _cancel();
  }

  BeaconTimeIssue? get _timeIssue => beaconStartIssue(_startAt, _now());

  bool get _canCreate =>
      beaconTitleIssue(_title.text) == null &&
      beaconDetailsIssue(_details.text) == null &&
      beaconVenueIssue(_venue.text) == null &&
      _timeIssue == null;

  Future<void> _pickDate() async {
    final now = _now();
    final picked = await widget.pickDate(
      context,
      initial: _startAt.isBefore(now) ? now : _startAt,
      first: now,
      last: now.add(kBeaconMaxLead),
    );
    if (picked == null || !mounted) return;
    _update(() {
      _startAt = DateTime(
        picked.year,
        picked.month,
        picked.day,
        _startAt.hour,
        _startAt.minute,
      );
    });
  }

  Future<void> _pickTime() async {
    final picked = await widget.pickTime(
      context,
      initial: TimeOfDay.fromDateTime(_startAt),
    );
    if (picked == null || !mounted) return;
    _update(() {
      _startAt = DateTime(
        _startAt.year,
        _startAt.month,
        _startAt.day,
        picked.hour,
        picked.minute,
      );
    });
  }

  void _create() {
    // The clock moved since the button was enabled: re-check with it now so
    // a start that slipped under 5 minutes shows its inline copy, not the
    // server's refusal.
    if (!_canCreate) {
      setState(() {});
      return;
    }
    final request = pb.CreateBeaconRequest(
      activity: _activity,
      title: normalizeListText(_title.text),
      details: normalizeListText(_details.text),
      venue: normalizeListText(_venue.text),
      startAt: ts.Timestamp.fromDateTime(_startAt.toUtc()),
      durationMinutes: _durationMinutes,
      openSpots: _openSpots,
      cost: _cost,
      chatPreference: _chat,
    );
    if (_audience.isPublic) {
      request.public = true;
    } else {
      request.communityId = _audience.id;
    }
    _cubit.create(request);
  }

  Widget _counter(TextEditingController c, int max) =>
      CharacterCounter(remaining: max - beaconTextLength(c.text));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Band A of the tablet layout: Preview in the header opens the dialog,
    // and the tips sit inline at the top of the form. Band B shows both in
    // the context pane instead; phones and desktop keep today's form
    // (ruling R-1).
    final tablet = ShellGeometry.maybeOf(context)?.tablet ?? false;
    final previewAction =
        tablet &&
        !ContextPaneScope.shows(context, ContextSectionKind.planPreview);
    final tipsInline =
        tablet && !ContextPaneScope.shows(context, ContextSectionKind.planTips);
    return Scaffold(
      body: SafeArea(
        child: AppMainColumn(
          child: BlocConsumer<CreateBeaconCubit, CreateBeaconState>(
            bloc: _cubit,
            listenWhen: (a, b) => a.created != b.created && b.created != null,
            listener: (context, state) => context.pushReplacement(
              AppRouter.planPath(state.created!.beacon.beaconId),
            ),
            builder: (context, state) {
              final busy = state.busy;
              return PopScope(
                canPop:
                    state.created != null || _discarded || (!busy && !_isDirty),
                onPopInvokedWithResult: (didPop, _) {
                  if (!didPop) _requestExit();
                },
                child: Column(
                  children: [
                    AppFormHeader(
                      title: 'New plan',
                      actionLabel: 'Create',
                      busy: busy,
                      busySemanticsLabel: 'Creating plan',
                      onCancel: _requestExit,
                      onAction: _canCreate && !busy ? _create : null,
                      secondaryLabel: previewAction ? kPlanPreviewTitle : null,
                      onSecondary: previewAction ? _openPreview : null,
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(AppSpacing.md),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Always one child here, so the fields keep their
                            // place when the tips move to the pane at 840.
                            if (tipsInline)
                              PlanTipsSection(
                                expanded: _tipsOpen,
                                onToggle: () =>
                                    setState(() => _tipsOpen = !_tipsOpen),
                              )
                            else
                              const SizedBox.shrink(),
                            _Section(
                              title: 'What',
                              child: _chips<pb.BeaconActivity>(
                                values: pb.BeaconActivity.values
                                    .where(
                                      (a) =>
                                          a !=
                                          pb
                                              .BeaconActivity
                                              .BEACON_ACTIVITY_UNSPECIFIED,
                                    )
                                    .toList(),
                                selected: _activity,
                                label: activityLabel,
                                enabled: !busy,
                                onSelected: (a) => _update(() => _activity = a),
                              ),
                            ),
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
                            const SizedBox(height: AppSpacing.md),
                            TextField(
                              controller: _venue,
                              enabled: !busy,
                              textInputAction: TextInputAction.done,
                              decoration: InputDecoration(
                                labelText: 'Meeting point',
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
                            _Section(
                              title: 'When',
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Wrap(
                                    spacing: AppSpacing.sm,
                                    runSpacing: AppSpacing.xs,
                                    children: [
                                      Tooltip(
                                        message: 'Pick a date',
                                        child: OutlinedButton.icon(
                                          onPressed: busy ? null : _pickDate,
                                          icon: const Icon(
                                            Icons.calendar_today_outlined,
                                          ),
                                          label: Text(
                                            formatScheduledDate(_startAt),
                                          ),
                                        ),
                                      ),
                                      Tooltip(
                                        message: 'Pick a time',
                                        child: OutlinedButton.icon(
                                          onPressed: busy ? null : _pickTime,
                                          icon: const Icon(
                                            Icons.schedule_outlined,
                                          ),
                                          label: Text(
                                            formatScheduledClock(_startAt),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  if (beaconTimeError(_timeIssue) != null)
                                    Padding(
                                      padding: const EdgeInsets.only(
                                        top: AppSpacing.xs,
                                      ),
                                      child: Text(
                                        beaconTimeError(_timeIssue)!,
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              color: theme.colorScheme.error,
                                            ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            _Section(
                              title: 'Duration',
                              child: _chips<int>(
                                values: kBeaconDurations,
                                selected: _durationMinutes,
                                label: (m) => '$m min',
                                enabled: !busy,
                                onSelected: (m) =>
                                    _update(() => _durationMinutes = m),
                              ),
                            ),
                            _Section(
                              title: 'Open spots',
                              child: Row(
                                children: [
                                  IconButton(
                                    tooltip: 'Fewer spots',
                                    icon: const Icon(
                                      Icons.remove_circle_outline,
                                    ),
                                    onPressed:
                                        busy || _openSpots <= kBeaconMinSpots
                                        ? null
                                        : () => _update(() => _openSpots--),
                                  ),
                                  Semantics(
                                    label: '$_openSpots open spots',
                                    excludeSemantics: true,
                                    child: Text(
                                      '$_openSpots',
                                      style: theme.textTheme.titleMedium,
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'More spots',
                                    icon: const Icon(Icons.add_circle_outline),
                                    onPressed:
                                        busy || _openSpots >= kBeaconMaxSpots
                                        ? null
                                        : () => _update(() => _openSpots++),
                                  ),
                                ],
                              ),
                            ),
                            _Section(
                              title: 'Cost',
                              child: _chips<pb.BeaconCost>(
                                values: const [
                                  pb.BeaconCost.BEACON_COST_FREE,
                                  pb.BeaconCost.BEACON_COST_EVERYONE_PAYS_OWN,
                                  pb.BeaconCost.BEACON_COST_SPLIT_EVENLY,
                                ],
                                selected: _cost,
                                label: costLabel,
                                enabled: !busy,
                                onSelected: (c) => _update(() => _cost = c),
                              ),
                            ),
                            _Section(
                              title: 'Chat',
                              child: _chips<pb.ChatPreference>(
                                values: const [
                                  pb.ChatPreference.CHAT_PREFERENCE_QUIET,
                                  pb
                                      .ChatPreference
                                      .CHAT_PREFERENCE_TASK_FOCUSED,
                                  pb
                                      .ChatPreference
                                      .CHAT_PREFERENCE_OPEN_TO_CHAT,
                                ],
                                selected: _chat,
                                label: chatPreferenceLabel,
                                enabled: !busy,
                                onSelected: (c) => _update(() => _chat = c),
                              ),
                            ),
                            _Section(
                              title: 'Who can see it',
                              child: _chips<BeaconsAudience>(
                                values: _audiences,
                                selected: _audience,
                                label: (a) => a.name,
                                enabled: !busy,
                                onSelected: (a) => _update(() => _audience = a),
                              ),
                            ),
                            if (state.error != null) ...[
                              const SizedBox(height: AppSpacing.md),
                              Semantics(
                                liveRegion: true,
                                child: Text(
                                  state.error!,
                                  style: theme.textTheme.bodyMedium?.copyWith(
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

  Widget _chips<T>({
    required List<T> values,
    required T selected,
    required String Function(T) label,
    required bool enabled,
    required ValueChanged<T> onSelected,
  }) => Wrap(
    spacing: AppSpacing.sm,
    runSpacing: AppSpacing.xs,
    children: [
      for (final v in values)
        ChoiceChip(
          label: Text(label(v)),
          selected: v == selected,
          onSelected: enabled ? (_) => onSelected(v) : null,
        ),
    ],
  );
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.md, bottom: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(title, style: theme.textTheme.titleMedium),
          ),
          const SizedBox(height: AppSpacing.sm),
          child,
        ],
      ),
    );
  }
}
