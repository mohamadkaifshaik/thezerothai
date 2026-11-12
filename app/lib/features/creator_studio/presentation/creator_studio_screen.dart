import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import '../../../shared/format/joined_date.dart';
import '../../../shared/widgets/primitives/app_back_header.dart';
import '../../../shared/widgets/primitives/app_card.dart';
import '../../../shared/widgets/primitives/app_main_column.dart';
import '../../../shared/widgets/primitives/settings_group.dart';
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../onboarding/presentation/bloc/onboarding_state.dart';
import 'widgets/creator_insights_group.dart';
import 'widgets/creator_programs_group.dart';

/// Creator Studio (`/creator-studio`, a shell of plan W8): an at-a-glance view
/// of the account from the profile already in memory, plus "Coming soon" rows
/// for insights and programs. No RPC, no repository, no refresh, no button
/// but Back, no link out.
///
/// The phone is raised cards on a 20 dp page; the tablet and desktop share the
/// flat boxes of the Settings pages.
class CreatorStudioScreen extends StatelessWidget {
  const CreatorStudioScreen({super.key});

  static const title = 'Creator Studio';
  static const intro =
      'Creator Studio is coming soon. For now this shows your account at a '
      'glance.';
  static const footnote = 'Counts are as of your last refresh.';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final phone = MediaQuery.sizeOf(context).width < AppBreakpoints.mobile;
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final side = EdgeInsets.symmetric(
      horizontal: phone
          ? AppStudioLayout.pagePaddingPhone
          : AppStudioLayout.pagePaddingWide,
    );
    return AppMainColumn(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppBackHeader(
            title: title,
            subtitle: phone ? null : 'Your account',
            onBack: () => context.canPop()
                ? context.pop()
                : context.go(AppRouter.homePath),
          ),
          Expanded(
            child: SingleChildScrollView(
              // The floating bar's inset (`ui_shell`); 0 under the docked bar.
              padding: EdgeInsets.only(
                top: AppSpacing.md,
                bottom: AppSpacing.lg + MediaQuery.paddingOf(context).bottom,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: side,
                    child: _Headline(phone: phone),
                  ),
                  Padding(
                    padding: side.copyWith(top: AppSpacing.sm),
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
                        : Padding(
                            padding: side.copyWith(
                              top: AppSpacing.md,
                              bottom: AppSpacing.md,
                            ),
                            child: _AccountStats(
                              profile: profile,
                              phone: phone,
                            ),
                          ),
                  ),
                  // The flat boxes bring their own side margin; the raised
                  // cards take the page's.
                  Padding(
                    padding: phone ? side : EdgeInsets.zero,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        CreatorInsightsGroup(style: _groupStyle(phone)),
                        CreatorProgramsGroup(style: _groupStyle(phone)),
                      ],
                    ),
                  ),
                  Padding(
                    padding: side,
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

  static SettingsGroupStyle _groupStyle(bool phone) =>
      phone ? SettingsGroupStyle.raised : SettingsGroupStyle.flat;
}

/// The eyebrow and the "Your reach." headline, "reach" in the accent colour.
class _Headline extends StatelessWidget {
  const _Headline({required this.phone});

  final bool phone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = AppTextStyles.displayAccent(
      theme,
      size: phone
          ? AppStudioLayout.headlinePhone
          : AppStudioLayout.headlineWide,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          (phone ? 'Your account' : 'Creator tools').toUpperCase(),
          style: AppTextStyles.eyebrow(theme)
              .copyWith(color: context.appColors.accentText),
        ),
        const SizedBox(height: AppSpacing.sm),
        Semantics(
          header: true,
          child: Text.rich(
            TextSpan(
              style: accent.copyWith(color: theme.colorScheme.onSurface),
              children: [
                const TextSpan(text: 'Your '),
                TextSpan(text: 'reach', style: accent),
                const TextSpan(text: '.'),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Followers, Following, Posts and Joined as a 2 x 2 grid of raised cards.
/// Counts are plain integers, exactly as the profile header prints them. The
/// Joined card is left out when `created_at` is unset (never a 1970 date).
class _AccountStats extends StatelessWidget {
  const _AccountStats({required this.profile, required this.phone});

  final identity.Profile profile;
  final bool phone;

  static String _count(Int64 n) => '$n';

  @override
  Widget build(BuildContext context) {
    final created = profile.hasCreatedAt() && profile.createdAt.seconds > 0
        ? profile.createdAt.toDateTime()
        : null;
    final cards = [
      _StatCard(
        label: 'Followers',
        value: _count(profile.followersCount),
        phone: phone,
        accent: true,
      ),
      _StatCard(
        label: 'Following',
        value: _count(profile.followingCount),
        phone: phone,
      ),
      _StatCard(
        label: 'Posts',
        value: _count(profile.postsCount),
        phone: phone,
      ),
      if (created != null)
        _StatCard(
          label: 'Joined',
          value: formatJoinedMonth(created),
          phone: phone,
        ),
    ];
    return Column(
      children: [
        for (var i = 0; i < cards.length; i += 2) ...[
          if (i > 0) const SizedBox(height: AppStudioLayout.statGap),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: cards[i]),
                const SizedBox(width: AppStudioLayout.statGap),
                Expanded(
                  child: i + 1 < cards.length ? cards[i + 1] : const SizedBox(),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.label,
    required this.value,
    required this.phone,
    this.accent = false,
  });

  final String label;
  final String value;
  final bool phone;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Read as one line ("Followers, 12"), not as two loose texts.
    return Semantics(
      container: true,
      label: '$label, $value',
      excludeSemantics: true,
      child: AppCard(
        padding: phone
            ? const EdgeInsets.all(AppStudioLayout.statPaddingPhone)
            : const EdgeInsets.symmetric(
                horizontal: AppStudioLayout.statPaddingHWide,
                vertical: AppStudioLayout.statPaddingVWide,
              ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // A long count or "September 2026" shrinks instead of wrapping.
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontSize: phone
                      ? AppStudioLayout.statValuePhone
                      : AppStudioLayout.statValueWide,
                  fontWeight: AppTypeTokens.weightDisplay,
                  color: accent
                      ? context.appColors.accentText
                      : theme.colorScheme.onSurface,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              label,
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
