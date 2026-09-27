import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/theme/app_theme.dart';
import '../../domain/auth_failure.dart';
import '../bloc/auth_bloc.dart';
import '../bloc/auth_event.dart';

/// Shown instead of the app once the user has signed up with email/password
/// but not yet verified their address (ADR-0006: posting/following/uploading
/// all require a verified email). Not a separate route — it's rendered by
/// whichever screen is on top of the [AuthBloc] when `status ==
/// AuthStatus.needsEmailVerification`, so it works from sign-up without
/// adding a new URL.
class VerifyEmailView extends StatelessWidget {
  const VerifyEmailView({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AuthBloc>().state;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Verify your email'),
        actions: [
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: () =>
                context.read<AuthBloc>().add(const AuthSignOutRequested()),
          ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.mark_email_unread_outlined, size: 40),
              const SizedBox(height: AppSpacing.md),
              Text(
                'We sent a verification link to ${state.user?.email ?? 'your email'}.\n'
                "Tap the link, then come back and press \"I've verified\".",
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.lg),
              FilledButton(
                onPressed: state.isSubmitting
                    ? null
                    : () => context.read<AuthBloc>().add(
                        const AuthEmailVerificationCheckRequested(),
                      ),
                child: state.isSubmitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text("I've verified"),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextButton(
                onPressed: state.isSubmitting
                    ? null
                    : () => context.read<AuthBloc>().add(
                        const AuthEmailVerificationResendRequested(),
                      ),
                child: const Text('Resend email'),
              ),
              if (state.failure != null && state.failure!.message.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.sm),
                  child: Text(
                    state.failure!.message,
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
