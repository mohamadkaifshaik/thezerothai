import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/feature_flags/ui_shell_feature_flag.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/theme_mode_cubit.dart';
import '../../../core/widgets/privacy_policy_link.dart';
import '../../../shared/widgets/settings_group.dart';
import '../../account/presentation/account_feature_flags.dart';
import '../../auth/presentation/bloc/auth_bloc.dart';
import '../../auth/presentation/bloc/auth_event.dart';
import '../../graph/presentation/graph_feature_flags.dart';
import '../../messages/domain/messaging_feature_flag.dart';
import '../../onboarding/data/identity_repository.dart';
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../onboarding/presentation/bloc/onboarding_event.dart';
import '../../posts/domain/posts_feature_flag.dart';
import '../../profile/domain/profile_edit_feature_flag.dart';
import '../domain/private_accounts_feature_flag.dart';
import 'bloc/protect_posts_cubit.dart';
import 'widgets/appearance_sheet.dart';
import 'widgets/protect_posts_row.dart';

/// Phase 0 settings: account info + sign out. Notification, privacy and
/// data-export settings (RequestAccountExport, DeleteAccount) land with the
/// account-settings feature. "Blocked accounts"/"Muted accounts" (graph
/// plan) only appear when the graph feature flag is on (ADR-0008 D6) —
/// "Protect your posts" (W3-33b, ADR-0025) shows with `private_accounts` on,
/// and for an already protected account whatever the flag (the undo rule).
///
/// The rows are grouped into sections; a section whose rows are all gated
/// off is not shown at all.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      // The same ~600 dp column as the Home feed on wide screens.
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppBreakpoints.mobile),
          child: const SettingsList(),
        ),
      ),
    );
  }
}

/// The empty detail pane of the master-detail layout (>= 1200dp, no page
/// chosen yet).
class SettingsDetailPlaceholder extends StatelessWidget {
  const SettingsDetailPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text('Select a setting', textAlign: TextAlign.center),
    );
  }
}

/// The grouped Settings rows. On phones and tablets a row pushes its page; in
/// the master-detail layout ([AppBreakpoints.tablet] and up, where the shell
/// shows this list beside the page) it replaces the detail pane instead, and
/// the row of the open page ([selectedPath]) is highlighted.
class SettingsList extends StatelessWidget {
  const SettingsList({super.key, this.selectedPath});

  final String? selectedPath;

  @override
  Widget build(BuildContext context) {
    // The protect switch's cubit exists only when the row can show, so a
    // caller without the flag reads no IdentityRepository here.
    final isPrivate = context.select(
      (OnboardingBloc bloc) => bloc.state.profile?.isPrivate ?? false,
    );
    final candidate =
        isPrivate || isFeatureEnabled(context, kFeaturePrivateAccounts);
    if (!candidate) return _buildList(context, showProtect: false);
    return BlocProvider<ProtectPostsCubit>(
      create: (context) => ProtectPostsCubit(
        identityRepository: context.read<IdentityRepository>(),
        onProfileUpdated: (profile) => context.read<OnboardingBloc>().add(
          OnboardingProfileUpdated(profile),
        ),
      ),
      child: Builder(
        builder: (context) => _buildList(
          context,
          showProtect:
              isPrivate ||
              !context.select((ProtectPostsCubit c) => c.state.refused),
        ),
      ),
    );
  }

  Widget _buildList(BuildContext context, {required bool showProtect}) {
    final masterDetail =
        MediaQuery.sizeOf(context).width >= AppBreakpoints.tablet;
    void open(String path) =>
        masterDetail ? context.go(path) : context.push(path);
    bool selected(String path) => masterDetail && selectedPath == path;

    final user = context.select((AuthBloc bloc) => bloc.state.user);
    final graphEnabled = isGraphEnabled(context);
    final profileEnabled = isFeatureEnabled(context, kFeatureProfileSnapshot);
    final lifecycleEnabled = isAccountLifecycleEnabled(context);
    // CMP-D6: the ROUTE needs only `posts` (a user dropped from the allowlist
    // may still list and cancel, ADR-0021 L-A option b), but this ENTRY shows
    // only with both flags for now: the client cannot tell "globally off" from
    // "not in the allowlist" (both just leave `scheduled_posts` out of
    // `enabled_features`). Whether every posts user gets the row is a product
    // decision still open.
    final scheduledEnabled =
        isFeatureEnabled(context, kFeaturePosts) &&
        isFeatureEnabled(context, kFeatureScheduledPosts);

    // W7-19: the legacy chrome (no `ui_shell`) has no Messages tab, so Settings
    // carries the only entry. The new shell has the bar / rail destination.
    final messagesEntry =
        isFeatureEnabled(context, kFeatureMessaging) &&
        !isFeatureEnabled(context, kFeatureUiShell);

    final groups = <(String, List<Widget>)>[
      (
        'Messaging',
        [
          if (messagesEntry)
            SettingsRow(
              icon: Icons.mail_outline,
              title: 'Messages',
              subtitle: 'Your inbox and message requests',
              onTap: () => context.push(AppRouter.messagesPath),
            ),
        ],
      ),
      (
        'Account',
        [
          if (user?.email != null)
            SettingsRow(
              icon: Icons.email_outlined,
              title: 'Email',
              subtitle: user!.email!,
            ),
          if (profileEnabled) ...[
            SettingsRow(
              icon: Icons.person_outline,
              title: 'Edit profile',
              selected: selected(AppRouter.editProfilePath),
              onTap: () => open(AppRouter.editProfilePath),
            ),
            SettingsRow(
              icon: Icons.alternate_email,
              title: 'Change handle',
              selected: selected(AppRouter.changeHandlePath),
              onTap: () => open(AppRouter.changeHandlePath),
            ),
          ],
        ],
      ),
      (
        'Posts',
        [
          if (scheduledEnabled)
            SettingsRow(
              icon: Icons.schedule_send_outlined,
              title: 'Scheduled posts',
              // A full-screen page over the shell, also in master-detail.
              onTap: () => context.push(AppRouter.scheduledPostsPath),
            ),
        ],
      ),
      (
        'Display',
        [
          SettingsRow(
            icon: Icons.brightness_6_outlined,
            title: 'Appearance',
            subtitle: themeModeLabel(
              context.select((ThemeModeCubit cubit) => cubit.state),
            ),
            onTap: () => AppearanceSheet.show(context),
          ),
        ],
      ),
      (
        'Privacy & safety',
        [
          if (showProtect) const ProtectPostsRow(),
          if (graphEnabled) ...[
            SettingsRow(
              icon: Icons.block_outlined,
              title: 'Blocked accounts',
              selected: selected(AppRouter.blockedAccountsPath),
              onTap: () => open(AppRouter.blockedAccountsPath),
            ),
            SettingsRow(
              icon: Icons.volume_off_outlined,
              title: 'Muted accounts',
              selected: selected(AppRouter.mutedAccountsPath),
              onTap: () => open(AppRouter.mutedAccountsPath),
            ),
          ],
        ],
      ),
      (
        'Your data',
        [
          if (lifecycleEnabled)
            SettingsRow(
              icon: Icons.download_outlined,
              title: 'Download my data',
              selected: selected(AppRouter.exportDataPath),
              onTap: () => open(AppRouter.exportDataPath),
            ),
        ],
      ),
      (
        'About',
        [
          SettingsRow(
            icon: Icons.privacy_tip_outlined,
            title: 'Privacy Policy',
            trailing: Icon(
              Icons.open_in_new,
              size: AppIconSize.md,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            onTap: () => launchPrivacyPolicy(context),
          ),
        ],
      ),
      (
        'Session',
        [
          if (lifecycleEnabled)
            SettingsRow(
              icon: Icons.delete_forever_outlined,
              title: 'Delete account',
              destructive: true,
              selected: selected(AppRouter.deleteAccountPath),
              onTap: () => open(AppRouter.deleteAccountPath),
            ),
          SettingsRow(
            icon: Icons.logout,
            title: 'Sign out',
            showChevron: false,
            onTap: () =>
                context.read<AuthBloc>().add(const AuthSignOutRequested()),
          ),
        ],
      ),
    ];

    return ListView(
      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
      children: [
        for (final (title, rows) in groups)
          if (rows.isNotEmpty) SettingsGroup(title: title, rows: rows),
      ],
    );
  }
}
