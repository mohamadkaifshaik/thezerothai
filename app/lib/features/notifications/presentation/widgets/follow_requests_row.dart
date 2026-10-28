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
import '../../../onboarding/presentation/bloc/onboarding_bloc.dart';

/// "Follow requests · N" at the top of the Notifications list (W3-34b): the
/// entry to `/follow-requests` that works at every width (the drawer is a
/// phone surface). Drawn only under the shared rule
/// (`followRequestsEntryVisible`) and with a pending count above 0; the count
/// is `GetMe.pending_follow_request_count` and nothing else (0 RPCs).
class FollowRequestsRow extends StatelessWidget {
  const FollowRequestsRow({super.key});

  @override
  Widget build(BuildContext context) {
    final count = context.select(
      (OnboardingBloc bloc) => bloc.state.pendingFollowRequestCount,
    );
    if (count <= 0 || !followRequestsEntryVisible(context)) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label: 'Follow requests, ${followRequestBadgeSpoken(count)}',
      excludeSemantics: true,
      onTap: () => context.go(AppRouter.followRequestsPath),
      child: InkWell(
        key: const ValueKey('notifications-follow-requests'),
        onTap: () => context.go(AppRouter.followRequestsPath),
        child: Container(
          constraints: const BoxConstraints(minHeight: AppSpacing.minTapTarget),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: theme.colorScheme.outlineVariant),
            ),
          ),
          child: Row(
            children: [
              const Icon(Icons.person_add_alt_outlined, size: AppIconSize.lg),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  'Follow requests · ${followRequestBadgeText(count)}',
                  style: theme.textTheme.titleMedium,
                ),
              ),
              const Icon(Icons.chevron_right, size: AppIconSize.md),
            ],
          ),
        ),
      ),
    );
  }
}
