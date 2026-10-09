import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/theme/app_theme.dart';
import '../../account/presentation/widgets/delete_account_link.dart';
import '../../auth/presentation/bloc/auth_bloc.dart';
import '../../auth/presentation/bloc/auth_event.dart';
import '../../auth/presentation/widgets/verify_email_view.dart';
import 'bloc/onboarding_bloc.dart';
import 'bloc/onboarding_event.dart';
import 'bloc/onboarding_state.dart';

/// Shown as [OnboardingStatus.emailVerificationRequired]'s banner when the
/// server's error message is empty — kept friendly and specific to this
/// screen rather than a generic fallback (`_handleTakenMessage`-style
/// constant, see the `onboarding_bloc` file).
const _emailNotVerifiedBanner =
    "Verify your email before we can create your profile.";

class CreateProfileScreen extends StatefulWidget {
  const CreateProfileScreen({super.key});

  @override
  State<CreateProfileScreen> createState() => _CreateProfileScreenState();
}

class _CreateProfileScreenState extends State<CreateProfileScreen> {
  final _handleController = TextEditingController();
  final _displayNameController = TextEditingController();

  @override
  void dispose() {
    _handleController.dispose();
    _displayNameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final onboardingStatus = context.select(
      (OnboardingBloc bloc) => bloc.state.status,
    );
    if (onboardingStatus == OnboardingStatus.emailVerificationRequired) {
      final message = context.select(
        (OnboardingBloc bloc) => bloc.state.error?.message,
      );
      return VerifyEmailView(
        banner: (message == null || message.isEmpty)
            ? _emailNotVerifiedBanner
            : message,
        onBack: () => context.read<OnboardingBloc>().add(
          const OnboardingEmailVerificationDismissed(),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Create your profile'),
        actions: [
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: () =>
                context.read<AuthBloc>().add(const AuthSignOutRequested()),
          ),
        ],
      ),
      body: BlocConsumer<OnboardingBloc, OnboardingState>(
        // Excludes emailVerificationRequired: that error is already shown as
        // VerifyEmailView's banner (see the early return above) rather than
        // a redundant snackbar.
        listenWhen: (previous, current) =>
            current.error != null &&
            previous.error != current.error &&
            current.status != OnboardingStatus.emailVerificationRequired,
        listener: (context, state) {
          final error = state.error;
          if (error == null) return;
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(content: Text(error.message)));
        },
        builder: (context, state) {
          return Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Pick a handle and a name. You can change these later.',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    TextField(
                      controller: _handleController,
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(
                        labelText: 'Handle',
                        prefixText: '@',
                        helperText: state.handleCheckMessage.isEmpty
                            ? '3-20 characters: lowercase letters, numbers, underscore.'
                            : state.handleCheckMessage,
                        helperMaxLines: 2,
                        errorText:
                            state.handleCheckStatus ==
                                HandleCheckStatus.unavailable
                            ? (state.handleCheckMessage.isEmpty
                                  ? 'That handle is taken.'
                                  : null)
                            : null,
                        suffixIcon: switch (state.handleCheckStatus) {
                          HandleCheckStatus.checking => const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                          HandleCheckStatus.available => const Icon(
                            Icons.check_circle,
                            color: Colors.green,
                          ),
                          HandleCheckStatus.unavailable => const Icon(
                            Icons.error,
                            color: Colors.red,
                          ),
                          HandleCheckStatus.unknown => const Icon(
                            Icons.help_outline,
                          ),
                          HandleCheckStatus.idle => null,
                        },
                      ),
                      onChanged: (value) => context.read<OnboardingBloc>().add(
                        OnboardingHandleChanged(value),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    TextField(
                      controller: _displayNameController,
                      textInputAction: TextInputAction.done,
                      decoration: const InputDecoration(
                        labelText: 'Display name',
                      ),
                      onChanged: (value) => context.read<OnboardingBloc>().add(
                        OnboardingDisplayNameChanged(value),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    FilledButton(
                      onPressed: state.canSubmit
                          ? () => context.read<OnboardingBloc>().add(
                              const OnboardingProfileSubmitted(),
                            )
                          : null,
                      child: state.isSubmitting
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Continue'),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    const DeleteAccountLink(),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
