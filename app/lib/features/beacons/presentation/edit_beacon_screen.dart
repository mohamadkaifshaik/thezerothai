import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
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
import 'beacons_error_messages.dart';
import 'bloc/edit_beacon_cubit.dart';

/// `/plans/:id/edit` (R34): title, details, meeting point and open spots, the
/// fields `UpdateBeacon` accepts. Start, duration, cost and audience are shown
/// read-only. Save is enabled when something changed, the text rules pass and
/// open spots cover the people already going.
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

  @override
  void initState() {
    super.initState();
    for (final c in [_title, _details, _venue]) {
      c.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _details.dispose();
    _venue.dispose();
    _cubit.close();
    super.dispose();
  }

  void _changed() => setState(() {});

  void _fill(pb.Beacon b) {
    if (_filled) return;
    _filled = true;
    _title.text = b.title;
    _details.text = b.details;
    _venue.text = b.venue;
    _openSpots = b.openSpots;
  }

  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRouter.planPath(widget.beaconId));
    }
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
                setState(() => _fill(state.view!.beacon));
              }
              if (state.saved != null) _back();
            },
            builder: (context, state) {
              final b = _filled ? state.view?.beacon : null;
              final busy = state.busy;
              final minSpots = b == null
                  ? kBeaconMinSpots
                  : b.acceptedCount.clamp(kBeaconMinSpots, kBeaconMaxSpots);
              return Column(
                children: [
                  AppFormHeader(
                    title: 'Edit plan',
                    actionLabel: 'Save',
                    busy: busy,
                    busySemanticsLabel: 'Saving plan',
                    onCancel: _back,
                    onAction: b != null && !busy && _dirty(b) && _valid(b)
                        ? _save
                        : null,
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
                                          busy || (_openSpots ?? 0) <= minSpots
                                          ? null
                                          : () => setState(
                                              () =>
                                                  _openSpots = _openSpots! - 1,
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
                                          : () => setState(
                                              () =>
                                                  _openSpots = _openSpots! + 1,
                                            ),
                                    ),
                                  ],
                                ),
                                if (b != null && b.acceptedCount > 0)
                                  Text(
                                    '${b.acceptedCount} already going; the '
                                    'spots cannot go below that.',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
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
