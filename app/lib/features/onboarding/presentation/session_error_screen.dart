import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/network/app_exception.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../auth/presentation/request_sign_out.dart';
import 'bloc/onboarding_bloc.dart';
import 'bloc/onboarding_event.dart';
import 'bloc/onboarding_state.dart';

/// Full-screen state for a session whose `GetMe` failed with nothing usable to
/// show ([OnboardingStatus.error]): no cached profile, or right after this
/// session's CreateProfile before any `GetMe` answered. Opening Home then
/// would show every flagged feature as "coming soon", so the router parks the
/// user here instead. (With a cached profile the app stays usable and the
/// shell shows a non-blocking Retry banner instead.)
///
/// Retry always shows (whatever the error) and dispatches
/// [OnboardingRefreshRequested]; while that `GetMe` runs a spinner replaces
/// the error, and the router leaves this page as soon as onboarding settles.
/// Sign out is the way out when retrying cannot help (an expired session).
class SessionErrorScreen extends StatelessWidget {
  const SessionErrorScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final error = context.select<OnboardingBloc, AppException?>(
      (bloc) =>
          bloc.state.status == OnboardingStatus.error ? bloc.state.error : null,
    );
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: AppBreakpoints.mobile),
            child: error == null
                ? const CircularProgressIndicator()
                : _ErrorBody(error: error),
          ),
        ),
      ),
    );
  }
}

/// The copy for a PROFILE_REQUIRED right after this session's CreateProfile.
const kProfileSettingUpMessage =
    'Your profile is still being set up. Try again in a moment.';

class _Message extends StatelessWidget {
  const _Message(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyLarge,
        ),
      ),
    );
  }
}

class _ErrorBody extends StatelessWidget {
  const _ErrorBody({required this.error});

  final AppException error;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // No onRetry: the one Retry below shows for every error type.
          if (error is ProfileRequiredException)
            // Only reached right after this session's CreateProfile: the
            // server has not caught up yet. Never the raw server text.
            const _Message(kProfileSettingUpMessage)
          else
            AppErrorView(error: error),
          FilledButton(
            key: const Key('session-error-retry'),
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, AppSpacing.minTapTarget),
            ),
            onPressed: () => context.read<OnboardingBloc>().add(
              const OnboardingRefreshRequested(),
            ),
            child: const Text('Retry'),
          ),
          const SizedBox(height: AppSpacing.sm),
          TextButton(
            style: TextButton.styleFrom(
              minimumSize: const Size(0, AppSpacing.minTapTarget),
            ),
            onPressed: () => unawaited(requestSignOut(context)),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
  }
}
