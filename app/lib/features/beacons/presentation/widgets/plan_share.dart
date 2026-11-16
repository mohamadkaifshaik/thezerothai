import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_router.dart';
import '../../../../core/share/share_links.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import '../../../../gen/dzeroth/posts/v1/posts.pb.dart' as posts;
import '../../../../shared/widgets/post/post_share_menu.dart';
import '../../../communities/domain/communities_feature_flag.dart';
import '../../../messages/domain/messaging_feature_flag.dart';
import '../../../messages/domain/share_post_target.dart';
import '../../../messages/presentation/share_post_picker.dart';
import '../../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../domain/beacons_feature_flag.dart';

/// The title of the plan share menu.
const kSharePlanTitle = 'Share plan';

/// What the plan's Share button offers the caller now.
///
/// - [post]: "Post about this plan": the organiser's own live plan, with
///   `beacons` and `post_beacon_embed` on (the server refuses a plan that is
///   hidden, ended, cancelled or someone else's).
/// - [message]: "Send in a message": `messaging` on. It sends the plan's link
///   as plain text, so `dm_post_share` is not needed.
/// - Copy link (and "Share via..." where the device has it) are always there
///   while the entry is.
@immutable
class PlanShareOptions {
  const PlanShareOptions({required this.post, required this.message});

  final bool post;
  final bool message;
}

/// The options of [view] for the caller, or null when the Share button must
/// not show: `beacons` off, no [ShareLinksScope] above (nothing to build a
/// link from), or a plan hidden by moderation (only its organiser sees it, and
/// a link to it opens nothing).
PlanShareOptions? planShareOptions(BuildContext context, pb.BeaconView view) {
  if (ShareLinksScope.maybeOf(context) == null) return null;
  final enabled =
      context.read<OnboardingBloc?>()?.state.enabledFeatures ??
      const <String>{};
  if (!enabled.contains(kFeatureBeacons) || view.beacon.hidden) return null;
  final b = view.beacon;
  final live =
      b.status == pb.BeaconStatus.BEACON_STATUS_OPEN ||
      b.status == pb.BeaconStatus.BEACON_STATUS_FULL;
  return PlanShareOptions(
    post:
        view.viewer.canManage &&
        live &&
        enabled.contains(kFeaturePostBeaconEmbed) &&
        // A community plan can only go in a post to its own community (the
        // server answers VALIDATION `beacon_id` otherwise), so it needs the
        // community audience.
        (b.communityId.isEmpty || enabled.contains(kFeatureCommunities)),
    message: enabled.contains(kFeatureMessaging),
  );
}

/// The plan as the composer's card shows it (the snapshot the server would
/// embed), for the route's `extra`.
posts.BeaconPreview planPreviewOf(pb.Beacon b) => posts.BeaconPreview(
  beaconId: b.beaconId,
  title: b.title,
  activity: b.activity,
  startAt: b.hasStartAt() ? b.startAt : null,
  status: b.status,
  communityId: b.communityId.isEmpty ? null : b.communityId,
);

/// Opens the plan share menu for [view] at [anchor]: a bottom sheet under
/// 600 dp, a menu anchored at the button from there up. Does nothing when
/// [planShareOptions] says there is nothing to offer.
Future<void> showPlanShareMenu(
  BuildContext context,
  pb.BeaconView view, {
  required Rect anchor,
}) async {
  final links = ShareLinksScope.maybeOf(context);
  final options = planShareOptions(context, view);
  if (links == null || options == null) return;
  final b = view.beacon;
  final url = links.planUrl(b.beaconId);
  await showPostShareMenu(
    context,
    url: url,
    nativeShare: links.nativeShare,
    anchor: anchor,
    title: kSharePlanTitle,
    onPostAbout: options.post
        ? () {
            if (!context.mounted) return;
            unawaited(
              context.push(
                // A community plan goes to its own community (preselected).
                b.communityId.isEmpty
                    ? AppRouter.composePlanPath(b.beaconId)
                    : '${AppRouter.composePlanPath(b.beaconId)}'
                          '&community=${Uri.encodeQueryComponent(b.communityId)}',
                extra: planPreviewOf(b),
              ),
            );
          }
        : null,
    onSendInMessage: options.message
        ? () {
            if (!context.mounted) return;
            unawaited(
              showSharePostPicker(
                context,
                target: SharePostTarget.link(url: url),
              ),
            );
          }
        : null,
  );
}

/// The Share icon on the plan's hero. Draws nothing when
/// [planShareOptions] is null.
class PlanShareButton extends StatelessWidget {
  const PlanShareButton({super.key, required this.view});

  final pb.BeaconView view;

  @override
  Widget build(BuildContext context) {
    if (planShareOptions(context, view) == null) {
      return const SizedBox.shrink();
    }
    return Builder(
      builder: (context) => IconButton(
        tooltip: kSharePlanTitle,
        icon: const Icon(Icons.ios_share, color: AppPalette.pearl),
        style: IconButton.styleFrom(
          minimumSize: const Size.square(AppPlansLayout.heroButton),
        ),
        onPressed: () => unawaited(
          showPlanShareMenu(context, view, anchor: targetRectOf(context)),
        ),
      ),
    );
  }
}
