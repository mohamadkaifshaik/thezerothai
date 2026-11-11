import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/feature_flags/feature_flags.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as beacons;
import '../../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../../../shared/format/scheduled_time.dart';
import '../../../../shared/widgets/post/unavailable_post_box.dart';
import '../../../../shared/widgets/primitives/app_card.dart';
import '../../data/beacons_repository.dart';
import '../../domain/beacon_labels.dart';
import '../../domain/beacons_feature_flag.dart';
import '../beacon_icons.dart';
import '../beacons_error_messages.dart';
import '../bloc/beacon_detail_cubit.dart';
import '../bloc/beacon_detail_state.dart';
import 'join_note_sheet.dart';

/// The text of the placeholder a viewer sees for a plan they cannot see
/// (`BeaconPreview.unavailable`): hidden, deleted, blocked, or a community
/// plan of a community they are not in. One text for every cause.
const kPlanUnavailable = 'Plan unavailable';

/// The trailing label once the viewer has asked to join from this card.
const kPlanRequested = 'Requested';

/// The join action's label: joining is a request the organiser answers, so
/// it reads like the plan page's button.
const kPlanAskToJoin = 'Ask to join';

/// Whether a post's plan card is drawn: the `post_beacon_embed` flag of the
/// caller (false when no session is above, as in some tests).
bool postBeaconEmbedEnabled(BuildContext context) {
  try {
    return isFeatureEnabled(context, kFeaturePostBeaconEmbed);
  } on ProviderNotFoundException {
    return false;
  }
}

/// The plan a post shares (`Post.beacon`, F5), as the navy plan strip of the
/// designs: the activity eyebrow, the title over its start time, the status
/// when the plan is not open, and "Ask to join".
///
/// - The server decides the preview for this viewer: an `unavailable` one
///   shows only [kPlanUnavailable], with nothing of the plan.
/// - With `beacons` on, the strip opens the plan page and an OPEN plan
///   offers "Ask to join" to anyone but the post's author (only an organiser
///   can share their plan, so the author is the organiser). With `beacons`
///   off it is display only: no tap, no Join.
/// - 0 RPCs to draw it. Join runs the plan page's flow through
///   [BeaconDetailCubit]: one GetBeacon for the viewer's state (a viewer who
///   cannot ask, because they already asked or joined, gets the plan page
///   instead), the join note sheet, then RequestToJoin. A failure shows the
///   plans error copy in a snackbar.
class PostBeaconEmbed extends StatefulWidget {
  const PostBeaconEmbed({
    super.key,
    required this.beacon,
    required this.authorIsViewer,
  });

  final pb.BeaconPreview beacon;

  /// The post is the viewer's own: their own plan, so no Join.
  final bool authorIsViewer;

  @override
  State<PostBeaconEmbed> createState() => _PostBeaconEmbedState();
}

class _PostBeaconEmbedState extends State<PostBeaconEmbed> {
  bool _busy = false;
  bool _requested = false;

  pb.BeaconPreview get _beacon => widget.beacon;

  @override
  void didUpdateWidget(PostBeaconEmbed oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.beacon.beaconId != widget.beacon.beaconId) {
      _requested = false;
    }
  }

  bool _beaconsOn(BuildContext context) {
    try {
      return isFeatureEnabled(context, kFeatureBeacons);
    } on ProviderNotFoundException {
      return false;
    }
  }

  BeaconsRepository? _repository() {
    try {
      return context.read<BeaconsRepository>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  void _openPlan() =>
      unawaited(context.push(AppRouter.planPath(_beacon.beaconId)));

  void _say(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _join() async {
    final repository = _repository();
    if (repository == null || _busy) return;
    setState(() => _busy = true);
    final cubit = BeaconDetailCubit(
      repository: repository,
      beaconId: _beacon.beaconId,
    );
    try {
      await cubit.load();
      if (!mounted) return;
      final loaded = cubit.state;
      final view = loaded.view;
      if (loaded.status == BeaconDetailStatus.error || view == null) {
        final error = loaded.error;
        _say(
          error == null
              ? 'Something went wrong. Please try again.'
              : beaconsErrorMessage(error),
        );
        return;
      }
      if (!view.viewer.canRequest) {
        // Already asked, already going, or the plan stopped taking people
        // since this page was loaded: the plan page says which.
        _openPlan();
        return;
      }
      setState(() => _busy = false);
      final note = await showJoinNoteSheet(context, title: view.beacon.title);
      if (note == null || !mounted) return;
      setState(() => _busy = true);
      final ok = await cubit.request(note);
      if (!mounted) return;
      if (ok) {
        setState(() => _requested = true);
      } else {
        _say(
          cubit.state.actionError ?? 'Something went wrong. Please try again.',
        );
      }
    } finally {
      unawaited(cubit.close());
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_beacon.unavailable) {
      return const UnavailablePostBox(message: kPlanUnavailable);
    }
    final theme = Theme.of(context);
    final beaconsOn = _beaconsOn(context);
    final status = _beacon.status;
    final open = status == beacons.BeaconStatus.BEACON_STATUS_OPEN;
    final canJoin =
        beaconsOn &&
        open &&
        !widget.authorIsViewer &&
        !_requested &&
        _repository() != null;
    final activity = activityLabel(_beacon.activity);
    final when = _beacon.hasStartAt()
        ? formatScheduledTime(_beacon.startAt.toDateTime())
        : '';
    // An unknown status (UNSPECIFIED, or a value this build lacks) draws
    // nothing and, like every status but OPEN, offers no Join.
    final statusText =
        open ||
            status == beacons.BeaconStatus.BEACON_STATUS_UNSPECIFIED ||
            !beacons.BeaconStatus.values.contains(status)
        ? null
        : statusLabel(status);
    final muted = AppPalette.mutedOnDark;
    final eyebrow = AppTextStyles.eyebrow(theme)
        .copyWith(color: AppPlanStrip.accent);

    // The strip is one node (its label, and the strip's tap with `beacons`
    // on); Join is a separate button inside it, never merged into the label.
    final label = [
      'Plan, $activity',
      if (_beacon.title.isNotEmpty) _beacon.title,
      if (when.isNotEmpty) when,
      ?statusText,
      if (_requested) kPlanRequested,
    ].join(', ');
    final summary = ExcludeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                activityIcon(_beacon.activity),
                size: AppIconSize.sm,
                color: AppPlanStrip.accent,
              ),
              const SizedBox(width: AppSpacing.sm),
              Flexible(
                child: Text(
                  'Plan · $activity'.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: eyebrow,
                ),
              ),
              if (statusText != null) ...[
                const SizedBox(width: AppSpacing.sm),
                Text(
                  statusText,
                  key: const ValueKey('post-plan-status'),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: AppPalette.pearl,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: AppSpacing.xs + 2),
          if (_beacon.title.isNotEmpty)
            Text(
              _beacon.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: AppPalette.pearl,
                fontWeight: FontWeight.w600,
              ),
            ),
          if (when.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                when,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: muted,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
        ],
      ),
    );

    final Widget? trailing = _requested
        ? ExcludeSemantics(
            child: Text(
              kPlanRequested,
              style: theme.textTheme.labelMedium?.copyWith(
                color: AppPlanStrip.accent,
                fontWeight: FontWeight.w700,
              ),
            ),
          )
        : canJoin
        ? _JoinButton(busy: _busy, onPressed: _join)
        : null;

    return Semantics(
      key: ValueKey('post-plan-${_beacon.beaconId}'),
      container: true,
      button: beaconsOn,
      label: label,
      child: AppPlanStrip(
        onTap: beaconsOn ? _openPlan : null,
        child: Row(
          children: [
            Expanded(child: summary),
            if (trailing != null) ...[
              const SizedBox(width: AppSpacing.smd),
              trailing,
            ],
          ],
        ),
      ),
    );
  }
}

/// "Ask to join" on the strip: the electric accent on navy, a 48 dp target,
/// never ellipsised (it wraps at large text instead).
class _JoinButton extends StatelessWidget {
  const _JoinButton({required this.busy, required this.onPressed});

  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 140),
      child: TextButton(
        onPressed: busy ? null : onPressed,
        style:
            TextButton.styleFrom(
              foregroundColor: AppPlanStrip.accent,
              disabledForegroundColor: AppPalette.mutedOnDark,
              minimumSize: const Size(
                AppSpacing.minTapTarget,
                AppSpacing.minTapTarget,
              ),
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.smd),
              textStyle: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
              side: const BorderSide(
                color: AppPlanStrip.accent,
                width: AppSize.componentBorder,
              ),
              shape: const StadiumBorder(),
            ).copyWith(
              // Pearl overlays: the default teal-on-navy focus would barely show.
              overlayColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.focused)
                    ? AppPlanStrip.focusOverlay
                    : states.contains(WidgetState.pressed)
                    ? AppPlanStrip.pressOverlay
                    : states.contains(WidgetState.hovered)
                    ? AppPlanStrip.hoverOverlay
                    : null,
              ),
            ),
        child: busy
            ? const SizedBox.square(
                dimension: AppIconSize.sm,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  semanticsLabel: 'Sending request',
                ),
              )
            : const Text(kPlanAskToJoin, textAlign: TextAlign.center),
      ),
    );
  }
}
