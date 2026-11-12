import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart'
    as ts;

import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import '../../../gen/dzeroth/common/v1/common.pb.dart' as common;
import '../../../shared/widgets/primitives/app_dialog.dart';
import '../../../shared/widgets/primitives/app_form_header.dart';
import '../../../shared/widgets/primitives/app_labeled_field.dart';
import '../../../shared/widgets/primitives/app_main_column.dart';
import '../../../shared/widgets/primitives/app_pickers.dart';
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
import 'widgets/plan_form_fields.dart';
import 'widgets/plan_preview.dart';
import 'widgets/plan_tips.dart';

export 'widgets/plan_form_fields.dart' show BeaconPickDate, BeaconPickTime;

/// The date picker the plan forms open by default (the [BeaconPickDate]
/// seam): the Material one, on the content area on the tablet layout.
Future<DateTime?> platformPickPlanDate(
  BuildContext context, {
  required DateTime initial,
  required DateTime first,
  required DateTime last,
}) => _platformPickDate(context, initial: initial, first: first, last: last);

/// The time picker the plan forms open by default (the [BeaconPickTime]
/// seam).
Future<TimeOfDay?> platformPickPlanTime(
  BuildContext context, {
  required TimeOfDay initial,
}) => _platformPickTime(context, initial: initial);

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
/// At every width the header has a Preview action that opens the plan page's
/// own `PlanSummary` of what the form would create in a dialog, and the tips
/// ("Tips for a good plan") sit inline at the top of the form, collapsed. Cost
/// and Open spots share a row where the column has room for both. The date and
/// time pickers are dialogs on the content area on the tablet layout.
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

  /// The plan as typed, for the Preview dialog.
  late final ValueNotifier<pb.Beacon> _draft;

  /// The inline tips, open or closed.
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
  void dispose() {
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

  /// The Preview dialog: it follows the form while it is open.
  void _openPreview() => showAppDialog<void>(
    context: context,
    maxWidth: AppSize.dialogMax,
    builder: (dialogContext) => AppDialog(
      title: kPlanPreviewTitle,
      body: ValueListenableBuilder<pb.Beacon>(
        valueListenable: _draft,
        // The dialog pads its title and body already: the preview's lines
        // start where the title does.
        builder: (context, draft, _) =>
            PlanPreview(beacon: draft, showOrganiser: draft.hasOrganiser()),
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

  int _left(TextEditingController c, int max) => max - beaconTextLength(c.text);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
                      secondaryLabel: kPlanPreviewTitle,
                      onSecondary: _openPreview,
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(AppSpacing.md),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            PlanTipsSection(
                              expanded: _tipsOpen,
                              onToggle: () =>
                                  setState(() => _tipsOpen = !_tipsOpen),
                            ),
                            PlanFormSection(
                              title: 'What',
                              child: PlanChoiceChips<pb.BeaconActivity>(
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
                            AppLabeledField(
                              label: 'Title',
                              controller: _title,
                              enabled: !busy,
                              textInputAction: TextInputAction.next,
                              remaining: _left(_title, kBeaconTitleMaxLength),
                              error: beaconFieldError(
                                beaconTitleIssue(_title.text),
                                max: kBeaconTitleMaxLength,
                              ),
                            ),
                            AppLabeledField(
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
                            PlanWhenFields(
                              start: _startAt,
                              enabled: !busy,
                              onPickDate: _pickDate,
                              onPickTime: _pickTime,
                              error: beaconTimeError(_timeIssue),
                            ),
                            // F34: Duration and Chat stay, though the
                            // desktop design dropped them (a regression).
                            PlanFormSection(
                              title: 'Duration',
                              child: PlanChoiceChips<int>(
                                values: kBeaconDurations,
                                selected: _durationMinutes,
                                label: (m) => '$m min',
                                enabled: !busy,
                                onSelected: (m) =>
                                    _update(() => _durationMinutes = m),
                              ),
                            ),
                            AppLabeledField(
                              label: 'Meeting point',
                              controller: _venue,
                              enabled: !busy,
                              textInputAction: TextInputAction.done,
                              remaining: _left(_venue, kBeaconVenueMaxLength),
                              helper: kMeetingPointNote,
                              error: beaconFieldError(
                                beaconVenueIssue(_venue.text),
                                max: kBeaconVenueMaxLength,
                              ),
                            ),
                            PlanPair(
                              first: PlanFormSection(
                                title: 'Cost',
                                child: PlanChoiceChips<pb.BeaconCost>(
                                  values: kPlanCosts,
                                  selected: _cost,
                                  label: costLabel,
                                  enabled: !busy,
                                  onSelected: (c) => _update(() => _cost = c),
                                ),
                              ),
                              second: PlanSpotsStepper(
                                value: _openSpots,
                                min: kBeaconMinSpots,
                                max: kBeaconMaxSpots,
                                enabled: !busy,
                                onChanged: (n) => _update(() => _openSpots = n),
                              ),
                            ),
                            PlanFormSection(
                              title: 'Chat',
                              child: PlanChoiceChips<pb.ChatPreference>(
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
                            PlanFormSection(
                              title: 'Who can see it',
                              child: PlanChoiceChips<BeaconsAudience>(
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
}
