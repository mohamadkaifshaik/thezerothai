import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/feature_flags/feature_flags.dart';
import '../../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import '../../../../shared/widgets/primitives/app_pill_button.dart';
import '../../data/beacons_repository.dart';
import '../../domain/beacons_feature_flag.dart';
import '../bloc/beacon_detail_cubit.dart';
import '../bloc/plans_session.dart';
import 'join_note_sheet.dart';

/// The label of the one-tap join.
const kPlanImIn = "I'm in";

/// Whether one-tap join is on for the caller: `beacons` and
/// `beacon_quick_join` both listed (false when no session is above, as in
/// some tests).
///
/// [listen] false is for event handlers (a non-reactive read).
bool quickJoinEnabled(BuildContext context, {bool listen = true}) {
  final read = listen ? isFeatureEnabled : featureEnabledSnapshot;
  try {
    return read(context, kFeatureBeacons) &&
        read(context, kFeatureBeaconQuickJoin);
  } on ProviderNotFoundException {
    return false;
  }
}

/// Whether [viewer] gets "I'm in": the flag is on and the server said so.
bool showsQuickJoin(BuildContext context, pb.ViewerState viewer) =>
    viewer.quickJoinAllowed && quickJoinEnabled(context);

/// One tap: RequestToJoin with an empty note through [cubit] (same key,
/// pending state and error copy as the sheet path). When the server answers
/// `note_required` (the organiser's follow was undone since the list was
/// read), opens the note sheet for [title] with the note required, and sends
/// from there. True when a request went through; false when refused or the
/// sheet was dismissed ([BeaconDetailState.actionError] has the copy).
Future<bool> quickJoin(
  BuildContext context,
  BeaconDetailCubit cubit, {
  required String title,
  ValueChanged<bool>? onBusy,
}) async {
  if (await cubit.request('')) return true;
  if (!cubit.state.noteRequired || !context.mounted) return false;
  // Not busy while the sheet is open; busy again while its note is sent.
  onBusy?.call(false);
  final note = await showJoinNoteSheet(
    context,
    title: title,
    noteRequired: true,
  );
  if (note == null || !context.mounted) return false;
  onBusy?.call(true);
  return cubit.request(note);
}

/// "I'm in" on a plan card: a compact pill under the card's text. Owns one
/// [BeaconDetailCubit] seeded with the card's view, so a retry after a
/// failure reuses the idempotency key. Once sent, the card says "Requested".
class PlanQuickJoinPill extends StatefulWidget {
  const PlanQuickJoinPill({super.key, required this.view});

  final pb.BeaconView view;

  @override
  State<PlanQuickJoinPill> createState() => _PlanQuickJoinPillState();
}

class _PlanQuickJoinPillState extends State<PlanQuickJoinPill> {
  BeaconDetailCubit? _cubit;
  bool _busy = false;
  bool _requested = false;

  @override
  void dispose() {
    unawaited(_cubit?.close());
    super.dispose();
  }

  Future<void> _tap() async {
    if (_busy) return;
    final repository = context.read<BeaconsRepository>();
    final cubit = _cubit ??= BeaconDetailCubit(
      repository: repository,
      beaconId: widget.view.beacon.beaconId,
      initialView: widget.view,
    );
    final messenger = ScaffoldMessenger.of(context);
    PlansSession? session;
    try {
      session = context.read<PlansSession?>();
    } on ProviderNotFoundException {
      session = null;
    }
    setState(() => _busy = true);
    final ok = await quickJoin(
      context,
      cubit,
      title: widget.view.beacon.title,
      onBusy: (busy) {
        if (mounted) setState(() => _busy = busy);
      },
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _requested = ok;
    });
    if (ok) {
      session?.refreshAfterWrite();
    } else if (cubit.state.actionError case final message?) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_requested) {
      final theme = Theme.of(context);
      return Text(
        'Requested',
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
        ),
      );
    }
    return AppPillButton(
      label: kPlanImIn,
      compact: true,
      busy: _busy,
      busySemanticsLabel: 'Sending request',
      onPressed: _busy ? null : _tap,
    );
  }
}
