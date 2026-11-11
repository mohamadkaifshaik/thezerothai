import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/feature_flags/feature_flags.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_drawer.dart'
    show followRequestBadgeSpoken, followRequestBadgeText;
import '../../../../core/widgets/context_pane.dart';
import '../../../../core/widgets/context_pane_slots.dart';
import '../../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../../../shared/widgets/primitives/app_badge.dart';
import '../../../../shared/widgets/primitives/app_pill_button.dart';
import '../../../../shared/widgets/user/user_list_skeleton.dart';
import '../../../graph/data/graph_repository.dart';
import '../../../graph/domain/follow_requests_entry.dart';
import '../../../graph/presentation/widgets/user_list_row.dart';
import '../../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../domain/notifications_feature_flag.dart';
import '../bloc/follow_requests_preview_cubit.dart';

/// The card's title (dz.css `.box h3`), also the inline row's.
const kFollowRequestsTitle = 'Follow requests';

/// The card's link to `/follow-requests`.
const kSeeAllRequestsLabel = 'See all requests';

/// Whether the follow-requests card (F16) may show at all for the caller:
/// `notifications` on (the page that lends it), the follow-requests rule of
/// the server's gate (`graph`, then `private_accounts` or a protected
/// caller: `followRequestsAllowed`), pending requests in `GetMe`, and
/// `ListFollowRequests` not backed off this session.
///
/// The checks run in that order, so a caller without the flags or without
/// pending requests never reaches the repository. Reads only what is loaded:
/// 0 RPCs. The one rule of the tablet pane's section, the desktop side
/// column's slot and the page's inline row, so the three cannot drift.
bool followRequestsCardAllowed(BuildContext context) {
  if (!isFeatureEnabled(context, kFeatureNotifications)) return false;
  final features = context.select(
    (OnboardingBloc bloc) => bloc.state.enabledFeatures,
  );
  final protected = context.select(
    (OnboardingBloc bloc) => bloc.state.profile?.isPrivate ?? false,
  );
  if (!followRequestsAllowed(
    enabledFeatures: features,
    isProtected: protected,
  )) {
    return false;
  }
  final count = context.select(
    (OnboardingBloc bloc) => bloc.state.pendingFollowRequestCount,
  );
  if (count <= 0) return false;
  return !context.read<GraphRepository>().followRequestsUnavailable;
}

/// Whether the follow-requests card shows beside the Notifications page at
/// [context] (the page asks; then its inline row steps aside and it loads
/// the card):
/// - tablet band B: the context pane lists the card ([ContextPaneScope]);
/// - desktop (1200 dp and up): `MainShell`'s side column holds its slot
///   whenever [followRequestsCardAllowed] holds on `/notifications`.
///
/// Never outside a shell (no [ContextPaneSlots]): nothing would draw it.
bool followRequestsCardBeside(BuildContext context) {
  if (ContextPaneSlots.maybeOf(context) == null) return false;
  if (ContextPaneScope.shows(context, ContextSectionKind.followRequests)) {
    return true;
  }
  return MediaQuery.sizeOf(context).width >= AppBreakpoints.tablet &&
      followRequestsCardAllowed(context);
}

/// The card's slot in the tablet pane and the desktop side column: what the
/// Notifications page lends, or [FollowRequestsCardPlaceholder] until it
/// does.
class FollowRequestsCardSlot extends StatelessWidget {
  const FollowRequestsCardSlot({super.key});

  @override
  Widget build(BuildContext context) => const ContextPaneSlot(
    kind: ContextSectionKind.followRequests,
    location: AppRouter.notificationsPath,
    placeholder: FollowRequestsCardPlaceholder(),
  );
}

/// The card while its requests load, and the slot until the page has lent
/// it: the same title, count, skeleton rows (as many as will show) and link,
/// so the pane does not jump when the rows arrive.
class FollowRequestsCardPlaceholder extends StatelessWidget {
  const FollowRequestsCardPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    final count = context.select(
      (OnboardingBloc bloc) => bloc.state.pendingFollowRequestCount,
    );
    if (count <= 0) return const SizedBox.shrink();
    return _CardFrame(
      count: count,
      children: [
        UserListSkeleton(
          rows: math.min(count, kFollowRequestsPreviewLimit),
          semanticsLabel: 'Loading follow requests',
        ),
        const _SeeAll(),
      ],
    );
  }
}

/// F16, the Notifications follow-requests card (dz.css `.box`, desktop and
/// tablet Notifications): "Follow requests" with the pending count of
/// `GetMe`, the first [kFollowRequestsPreviewLimit] requests, each with
/// Accept, and "See all requests" to `/follow-requests`.
///
/// Presentational: the Notifications page lends it over its own
/// [FollowRequestsPreviewCubit] (`ContextPaneSlots`), so the pane makes no
/// call of its own. Draws nothing without pending requests or when the
/// requests are unavailable; never a banner.
class FollowRequestsCard extends StatelessWidget {
  const FollowRequestsCard({
    super.key,
    required this.state,
    required this.onAccept,
    required this.onRetry,
  });

  final FollowRequestsPreviewState state;
  final ValueChanged<graph.UserListItem> onAccept;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final count = context.select(
      (OnboardingBloc bloc) => bloc.state.pendingFollowRequestCount,
    );
    if (count <= 0 || state.status == FollowRequestsPreviewStatus.unavailable) {
      return const SizedBox.shrink();
    }
    final items = state.items;
    final waiting =
        state.status == FollowRequestsPreviewStatus.idle ||
        state.status == FollowRequestsPreviewStatus.loading;
    if (waiting && items.isEmpty) return const FollowRequestsCardPlaceholder();
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final failed = state.status == FollowRequestsPreviewStatus.failed;
    return _CardFrame(
      count: count,
      children: [
        for (final item in items)
          UserListRow(
            key: ValueKey('follow-request-card-${item.user.userId}'),
            item: item,
            onProfileTap: item.user.userId.isEmpty
                ? null
                : () =>
                      context.push(AppRouter.profileByIdPath(item.user.userId)),
            trailing: _AcceptButton(
              handle: item.user.handle,
              onPressed: () => onAccept(item),
            ),
          ),
        if (failed && items.isEmpty)
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(
              AppSpacing.md,
              AppSpacing.xs,
              AppSpacing.sm,
              0,
            ),
            child: Row(
              children: [
                Expanded(child: Text("Couldn't load requests.", style: muted)),
                TextButton(
                  style: TextButton.styleFrom(
                    minimumSize: const Size(
                      AppSpacing.minTapTarget,
                      AppSpacing.minTapTarget,
                    ),
                  ),
                  onPressed: onRetry,
                  child: const Text('Retry'),
                ),
              ],
            ),
          )
        else if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.xs,
              AppSpacing.md,
              0,
            ),
            // The page's own empty line: GetMe's count was ahead of the list.
            child: Text('No follow requests', style: muted),
          ),
        const _SeeAll(),
      ],
    );
  }
}

/// The card's surface and heading ("Follow requests" and the count badge,
/// spoken once as "Follow requests, N pending").
class _CardFrame extends StatelessWidget {
  const _CardFrame({required this.count, required this.children});

  final int count;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => ContextPaneCard(
    key: const ValueKey('follow-requests-card'),
    title: kFollowRequestsTitle,
    titleSemanticsLabel:
        '$kFollowRequestsTitle, ${followRequestBadgeSpoken(count)}',
    titleTrailing: AppTintBadge(
      label: followRequestBadgeText(count),
      excludeSemantics: true,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  );
}

/// Accept (dz.css `.btn.sm.primary`): a compact pill in a 48 dp target,
/// spoken with the requester's handle.
class _AcceptButton extends StatelessWidget {
  const _AcceptButton({required this.handle, required this.onPressed});

  final String handle;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'Accept follow request from @$handle',
    excludeSemantics: true,
    onTap: onPressed,
    child: AppPillButton(label: 'Accept', compact: true, onPressed: onPressed),
  );
}

/// "See all requests" (dz.css `.box .more`): a 48 dp link row to
/// `/follow-requests`.
class _SeeAll extends StatelessWidget {
  const _SeeAll();

  @override
  Widget build(BuildContext context) => Align(
    alignment: AlignmentDirectional.centerStart,
    child: Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      child: TextButton(
        style: TextButton.styleFrom(
          minimumSize: const Size(0, AppSpacing.minTapTarget),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
        ),
        onPressed: () => context.go(AppRouter.followRequestsPath),
        child: const Text(kSeeAllRequestsLabel),
      ),
    ),
  );
}
