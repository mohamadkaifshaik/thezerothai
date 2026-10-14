import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../../auth/presentation/bloc/auth_event.dart';

/// Full-screen state for the signed-in account being suspended (or pending
/// deletion): every RPC but DeleteAccount answers ACCOUNT_RESTRICTED, so the
/// app has nothing to show. Offers sign-out only; it never says why or by
/// whom (ADR-0016: no oracle), and other people's suspended or hidden content
/// keeps the ordinary "not available" wording elsewhere.
class AccountRestrictedView extends StatelessWidget {
  const AccountRestrictedView({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: AppBreakpoints.mobile),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Semantics(
                liveRegion: true,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.block_outlined,
                      size: AppIconSize.xl,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Text(
                      'This account is restricted',
                      style: theme.textTheme.titleLarge,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      "You can't use dZeroth with this account right now.",
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, AppSpacing.minTapTarget),
                      ),
                      onPressed: () => context.read<AuthBloc>().add(
                        const AuthSignOutRequested(),
                      ),
                      child: const Text('Sign out'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
