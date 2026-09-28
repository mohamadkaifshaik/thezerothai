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
/// adding a new URL. `CreateProfileScreen` reuses it the same way for
/// `OnboardingStatus.emailVerificationRequired` (passing [banner] and
/// [onBack]), when `CreateProfile` finds the caller's ID token stale.
class VerifyEmailView extends StatelessWidget {
  const VerifyEmailView({super.key, this.banner, this.onBack});

  /// Optional context-specific note shown above the standard instructions,
  /// e.g. why the caller landed here from somewhere other than sign-up.
  final String? banner;

  /// When set, the app bar shows a back action (instead of relying on the
  /// navigator, since this view is swapped in in place, not pushed) that
  /// returns to whatever screen showed this view — sign-out stays available
  /// alongside it.
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AuthBloc>().state;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Verify your email'),
        leading: onBack == null ? null : BackButton(onPressed: onBack),
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
              if (banner != null && banner!.isNotEmpty) ...[
                Text(
                  banner!,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: AppSpacing.sm),
              ],
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
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
