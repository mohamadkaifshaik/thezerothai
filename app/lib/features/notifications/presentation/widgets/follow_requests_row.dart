import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_router.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_drawer.dart'
    show
        followRequestBadgeSpoken,
        followRequestBadgeText,
        followRequestsEntryVisible;
import '../../../../shared/widgets/primitives/app_badge.dart';
import '../../../../shared/widgets/primitives/app_tile_icon.dart';
import '../../../onboarding/presentation/bloc/onboarding_bloc.dart';
import 'follow_requests_card.dart';

/// "Follow requests" with its count at the top of the Notifications list:
/// the entry to `/follow-requests` that works at every width (the drawer is
/// a phone surface). Drawn only under the shared rule
/// (`followRequestsEntryVisible`) and with a pending count above 0; the count
/// is `GetMe.pending_follow_request_count` and nothing else (0 RPCs).
///
/// It steps aside while the follow-requests card (F16) shows beside the page
/// (tablet band B's pane, the desktop side column): one entry per place.
/// The same look as the card's heading: a teal tile, the title, the count
/// in a tint badge, and a chevron.
class FollowRequestsRow extends StatelessWidget {
  const FollowRequestsRow({super.key});

  @override
  Widget build(BuildContext context) {
    final count = context.select(
      (OnboardingBloc bloc) => bloc.state.pendingFollowRequestCount,
    );
    if (count <= 0 ||
        !followRequestsEntryVisible(context) ||
        followRequestsCardBeside(context)) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label: '$kFollowRequestsTitle, ${followRequestBadgeSpoken(count)}',
      excludeSemantics: true,
      onTap: () => context.go(AppRouter.followRequestsPath),
      child: InkWell(
        key: const ValueKey('notifications-follow-requests'),
        onTap: () => context.go(AppRouter.followRequestsPath),
        child: Container(
          constraints: const BoxConstraints(minHeight: AppSpacing.minTapTarget),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.smd,
          ),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: context.appColors.hairline),
            ),
          ),
          child: Row(
            children: [
              const AppTileIcon(
                icon: Icons.person_add_alt_outlined,
                size: AppIconSize.xl,
              ),
              const SizedBox(width: AppSpacing.smd),
              Expanded(
                child: Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.xs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      kFollowRequestsTitle,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    AppTintBadge(
                      label: followRequestBadgeText(count),
                      excludeSemantics: true,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Icon(
                Icons.chevron_right,
                size: AppIconSize.md,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
