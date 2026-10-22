import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/theme_mode_cubit.dart';
import '../../../core/widgets/privacy_policy_link.dart';
import '../../account/presentation/account_feature_flags.dart';
import '../../auth/presentation/bloc/auth_bloc.dart';
import '../../auth/presentation/bloc/auth_event.dart';
import '../../graph/presentation/graph_feature_flags.dart';
import '../../profile/domain/profile_edit_feature_flag.dart';
import 'widgets/appearance_sheet.dart';
import 'widgets/settings_group.dart';

/// Phase 0 settings: account info + sign out. Notification, privacy and
/// data-export settings (RequestAccountExport, DeleteAccount) land with the
/// account-settings feature. "Blocked accounts"/"Muted accounts" (graph
/// plan) only appear when the graph feature flag is on (ADR-0008 D6) —
/// there is deliberately no "private account" toggle: private accounts are
/// deferred (ADR-0008 D1).
///
/// The rows are grouped into sections; a section whose rows are all gated
/// off is not shown at all.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final user = context.select((AuthBloc bloc) => bloc.state.user);
    final graphEnabled = isGraphEnabled(context);
    final profileEnabled = isFeatureEnabled(context, kFeatureProfileSnapshot);
    final lifecycleEnabled = isAccountLifecycleEnabled(context);

    final groups = <(String, List<Widget>)>[
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
              onTap: () => context.push(AppRouter.editProfilePath),
            ),
            SettingsRow(
              icon: Icons.alternate_email,
              title: 'Change handle',
              onTap: () => context.push(AppRouter.changeHandlePath),
            ),
          ],
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
          if (graphEnabled) ...[
            SettingsRow(
              icon: Icons.block_outlined,
              title: 'Blocked accounts',
              onTap: () => context.push(AppRouter.blockedAccountsPath),
            ),
            SettingsRow(
              icon: Icons.volume_off_outlined,
              title: 'Muted accounts',
              onTap: () => context.push(AppRouter.mutedAccountsPath),
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
              onTap: () => context.push(AppRouter.exportDataPath),
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
              onTap: () => context.push(AppRouter.deleteAccountPath),
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

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      // The same ~600 dp column as the Home feed on wide screens.
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppBreakpoints.mobile),
          child: ListView(
            padding: const EdgeInsets.only(bottom: AppSpacing.lg),
            children: [
              for (final (title, rows) in groups)
                if (rows.isNotEmpty) SettingsGroup(title: title, rows: rows),
            ],
          ),
        ),
      ),
    );
  }
}
