import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import '../../../shared/format/joined_date.dart';
import '../../../shared/widgets/app_back_header.dart';
import '../../../shared/widgets/app_main_column.dart';
import '../../../shared/widgets/settings_group.dart';
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../onboarding/presentation/bloc/onboarding_state.dart';
import 'widgets/creator_insights_group.dart';
import 'widgets/creator_programs_group.dart';

/// Creator tools (`/creator-studio`, a shell of plan W8): an at-a-glance view
/// of the account from the profile already in memory, plus "Coming soon" rows
/// for insights and programs. No RPC, no repository, no refresh, no button
/// but Back, no link out.
class CreatorStudioScreen extends StatelessWidget {
  const CreatorStudioScreen({super.key});

  static const title = 'Creator tools';
  static const intro =
      'Creator tools are coming soon. For now this shows your account at a '
      'glance.';
  static const footnote = 'Counts are as of your last refresh.';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return AppMainColumn(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppBackHeader(
            title: title,
            onBack: () => context.canPop()
                ? context.pop()
                : context.go(AppRouter.homePath),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    child: Text(intro, style: muted),
                  ),
                  BlocSelector<
                    OnboardingBloc,
                    OnboardingState,
                    identity.Profile?
                  >(
                    selector: (state) => state.profile,
                    builder: (context, profile) => profile == null
                        ? const SizedBox.shrink()
                        : _AccountGroup(profile: profile),
                  ),
                  const CreatorInsightsGroup(),
                  const CreatorProgramsGroup(),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md,
                    ),
                    child: Text(footnote, style: muted),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Your account": counts and join month from the profile in memory. Counts
/// are plain integers, exactly as the profile header prints them. The Joined
/// row is left out when `created_at` is unset (never a 1970 date).
class _AccountGroup extends StatelessWidget {
  const _AccountGroup({required this.profile});

  final identity.Profile profile;

  static Widget _count(Int64 n) => Text('$n');

  @override
  Widget build(BuildContext context) {
    final created = profile.hasCreatedAt() && profile.createdAt.seconds > 0
        ? profile.createdAt.toDateTime()
        : null;
    return SettingsGroup(
      title: 'Your account',
      rows: [
        SettingsRow(
          icon: Icons.group_outlined,
          title: 'Followers',
          value: _count(profile.followersCount),
        ),
        SettingsRow(
          icon: Icons.person_add_alt_outlined,
          title: 'Following',
          value: _count(profile.followingCount),
        ),
        SettingsRow(
          icon: Icons.article_outlined,
          title: 'Posts',
          value: _count(profile.postsCount),
        ),
        if (created != null)
          SettingsRow(
            icon: Icons.calendar_month_outlined,
            title: 'Joined',
            value: Text(formatJoinedMonth(created)),
          ),
      ],
    );
  }
}
