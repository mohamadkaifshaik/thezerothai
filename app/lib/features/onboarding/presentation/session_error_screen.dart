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
/// show ([OnboardingStatus.error]): no profile, or a cached profile without
/// this session's feature flags. Opening Home then would show every flagged
/// feature as "coming soon", so the router parks the user here instead.
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
