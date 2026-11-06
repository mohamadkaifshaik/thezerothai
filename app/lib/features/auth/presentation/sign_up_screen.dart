import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/privacy_policy_link.dart';
import '../domain/auth_failure.dart';
import 'bloc/auth_bloc.dart';
import 'bloc/auth_event.dart';
import 'bloc/auth_state.dart';
import 'widgets/auth_form_layout.dart';
import 'widgets/email_password_form.dart';
import 'widgets/social_sign_in_buttons.dart';

class SignUpScreen extends StatelessWidget {
  const SignUpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: BlocConsumer<AuthBloc, AuthState>(
          listenWhen: (previous, current) => current.failure != null,
          listener: (context, state) {
            final failure = state.failure;
            if (failure == null || failure.message.isEmpty) return;
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(SnackBar(content: Text(failure.message)));
            context.read<AuthBloc>().add(const AuthFailureDismissed());
          },
          builder: (context, state) {
            return AuthFormLayout(
              title: 'Create your account',
              subtitle: 'Start something nearby.',
              children: [
                SocialSignInButtons(
                  isSubmitting: state.isSubmitting,
                  onGoogleTap: () => context.read<AuthBloc>().add(
                    const AuthGoogleSignInRequested(),
                  ),
                  onAppleTap: () => context.read<AuthBloc>().add(
                    const AuthAppleSignInRequested(),
                  ),
                ),
                const AuthEmailDivider(),
                EmailPasswordForm(
                  submitLabel: 'Create account',
                  isSubmitting: state.isSubmitting,
                  confirmPassword: true,
                  onSubmit: (email, password) => context.read<AuthBloc>().add(
                    AuthEmailSignUpRequested(email: email, password: password),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                const PrivacyPolicyLink(
                  leadingText:
                      "By signing up you confirm you're 18 or older "
                      'and agree to our ',
                ),
                const SizedBox(height: AppSpacing.sm),
                TextButton(
                  onPressed: () => context.go('/sign-in'),
                  child: const Text('Already have an account? Log in'),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
