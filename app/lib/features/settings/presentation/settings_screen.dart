import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/widgets/privacy_policy_link.dart';
import '../../account/presentation/account_feature_flags.dart';
import '../../auth/presentation/bloc/auth_bloc.dart';
import '../../auth/presentation/bloc/auth_event.dart';
import '../../graph/presentation/graph_feature_flags.dart';

/// Phase 0 settings: account info + sign out. Notification, privacy and
/// data-export settings (RequestAccountExport, DeleteAccount) land with the
/// account-settings feature. "Blocked accounts"/"Muted accounts" (graph
/// plan) only appear when the graph feature flag is on (ADR-0008 D6) —
/// there is deliberately no "private account" toggle: private accounts are
/// deferred (ADR-0008 D1).
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final user = context.select((AuthBloc bloc) => bloc.state.user);
    final graphEnabled = isGraphEnabled(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          if (user?.email != null)
            ListTile(
              leading: const Icon(Icons.email_outlined),
              title: const Text('Email'),
              subtitle: Text(user!.email!),
            ),
          const Divider(height: 1),
          if (graphEnabled) ...[
            ListTile(
              leading: const Icon(Icons.block_outlined),
              title: const Text('Blocked accounts'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push(AppRouter.blockedAccountsPath),
            ),
            ListTile(
              leading: const Icon(Icons.volume_off_outlined),
              title: const Text('Muted accounts'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push(AppRouter.mutedAccountsPath),
            ),
            const Divider(height: 1),
          ],
          ListTile(
            leading: const Icon(Icons.privacy_tip_outlined),
            title: const Text('Privacy Policy'),
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: () => launchPrivacyPolicy(context),
          ),
          const Divider(height: 1),
          if (isAccountLifecycleEnabled(context)) ...[
            ListTile(
              leading: const Icon(Icons.delete_forever_outlined),
              title: const Text('Delete account'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push(AppRouter.deleteAccountPath),
            ),
            const Divider(height: 1),
          ],
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Sign out'),
            onTap: () =>
                context.read<AuthBloc>().add(const AuthSignOutRequested()),
          ),
        ],
      ),
    );
  }
}
