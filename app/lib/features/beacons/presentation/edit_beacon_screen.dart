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
import 'widgets/discard_plan_dialog.dart';
import 'widgets/plan_preview.dart';
import 'widgets/plan_tips.dart';

/// `/plans/:id/edit` (R34): title, details, meeting point and open spots, the
/// fields `UpdateBeacon` accepts. Start, duration, cost and audience are shown
/// read-only. Save is enabled when something changed, the text rules pass and
/// open spots cover the people already going.
///
/// On the tablet layout (T8d, tablet plan section 4.1 PlanEdit), once the
/// plan is loaded, the form has a live preview (the plan page's own
/// `PlanSummary` with the edits) and "Tips for a good plan": band B shows
/// both in the context pane, lent by this page (a loading preview while the
/// plan loads, nothing when it fails); band A has a Preview header action
/// that opens the preview in a dialog and the tips inline at the top of the
/// form, collapsed. The meeting point carries its privacy note there.
/// Phones and desktop keep today's form (ruling R-1).
class EditBeaconScreen extends StatefulWidget {
  const EditBeaconScreen({super.key, required this.beaconId});

  final String beaconId;

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
  bool _filled = false;
  bool _discarded = false;

  /// The plan with the edits, for the preview; null until it is loaded.
  final _draft = ValueNotifier<pb.Beacon?>(null);
  final _paneLease = ContextPaneLease();

  /// Band A's inline tips, open or closed; kept across resizes.
  var _tipsOpen = false;

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
    _draft.value = b == null
        ? null
        : editedPlan(
            b,
            title: _title.text,
            details: _details.text,
            venue: _venue.text,
            openSpots: _openSpots ?? b.openSpots,
          );
  }

  void _fill(pb.Beacon b) {
    if (_filled) return;
    _filled = true;
    _title.text = b.title;
    _details.text = b.details;
    _venue.text = b.venue;
    _openSpots = b.openSpots;
  }

  /// Band A's Preview (tablet plan section 4.1: "header action that opens a
  /// Preview dialog"): a D 560 dialog on the content area that follows the
  /// form.
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
            : PlanPreview(beacon: draft, inset: 0),
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
      _openSpots != b.openSpots;

  bool _valid(pb.Beacon b) =>
      beaconTitleIssue(_title.text) == null &&
      beaconDetailsIssue(_details.text) == null &&
      beaconVenueIssue(_venue.text) == null &&
      (_openSpots ?? 0) >=
          b.acceptedCount.clamp(kBeaconMinSpots, kBeaconMaxSpots);

  void _save() => _cubit.save(
    title: normalizeListText(_title.text),
    details: normalizeListText(_details.text),
    venue: normalizeListText(_venue.text),
    openSpots: _openSpots!,
  );

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
                                  const SizedBox(height: AppSpacing.md),
                                  TextField(
                                    controller: _venue,
                                    enabled: !busy,
                                    textInputAction: TextInputAction.done,
                                    decoration: InputDecoration(
                                      labelText: 'Meeting point',
                                      // The privacy note, as on the create
                                      // form; tablet only (ruling R-1).
                                      helperText: tablet
                                          ? kMeetingPointNote
                                          : null,
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
                                  const SizedBox(height: AppSpacing.md),
                                  Semantics(
                                    header: true,
                                    child: Text(
                                      'Open spots',
                                      style: theme.textTheme.titleMedium,
                                    ),
                                  ),
                                  Row(
                                    children: [
                                      IconButton(
                                        tooltip: 'Fewer spots',
                                        icon: const Icon(
                                          Icons.remove_circle_outline,
                                        ),
                                        onPressed:
                                            busy ||
                                                (_openSpots ?? 0) <= minSpots
                                            ? null
                                            : () => _update(
                                                () => _openSpots =
                                                    _openSpots! - 1,
                                              ),
                                      ),
                                      Semantics(
                                        label: '${_openSpots ?? 0} open spots',
                                        excludeSemantics: true,
                                        child: Text(
                                          '${_openSpots ?? 0}',
                                          style: theme.textTheme.titleMedium,
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: 'More spots',
                                        icon: const Icon(
                                          Icons.add_circle_outline,
                                        ),
                                        onPressed:
                                            busy ||
                                                (_openSpots ?? 0) >=
                                                    kBeaconMaxSpots
                                            ? null
                                            : () => _update(
                                                () => _openSpots =
                                                    _openSpots! + 1,
                                              ),
                                      ),
                                    ],
                                  ),
                                  if (b != null && b.acceptedCount > 0)
                                    Text(
                                      '${b.acceptedCount} already going; the '
                                      'spots cannot go below that.',
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                  if (b != null) ...[
                                    const SizedBox(height: AppSpacing.lg),
                                    _ReadOnly(beacon: b),
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

/// The fields `UpdateBeacon` does not take, shown as they are.
class _ReadOnly extends StatelessWidget {
  const _ReadOnly({required this.beacon});

  final pb.Beacon beacon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final b = beacon;
    final audience = b.communityId.isEmpty ? 'Public' : 'Community';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Starts ${beaconWhenText(b)}', style: theme.textTheme.bodyMedium),
        Text('Cost: ${costLabel(b.cost)}', style: theme.textTheme.bodyMedium),
        Text('Who can see it: $audience', style: theme.textTheme.bodyMedium),
        const SizedBox(height: AppSpacing.xs),
        Text(
          "Start, duration, cost and audience can't be changed. Cancel the "
          'plan and create a new one instead.',
          style: theme.textTheme.bodySmall?.copyWith(color: muted),
        ),
      ],
    );
  }
}
