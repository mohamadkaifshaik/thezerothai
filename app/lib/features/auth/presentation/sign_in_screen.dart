import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../domain/auth_failure.dart';
import 'bloc/auth_bloc.dart';
import 'bloc/auth_event.dart';
import 'bloc/auth_state.dart';
import 'widgets/email_password_form.dart';
import 'widgets/social_sign_in_buttons.dart';

class SignInScreen extends StatelessWidget {
  const SignInScreen({super.key});

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
            return Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 400),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Welcome back',
                        style: Theme.of(context).textTheme.headlineMedium,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: AppSpacing.xl),
                      EmailPasswordForm(
                        submitLabel: 'Sign in',
                        isSubmitting: state.isSubmitting,
                        onSubmit: (email, password) => context
                            .read<AuthBloc>()
                            .add(
                              AuthEmailSignInRequested(
                                email: email,
                                password: password,
                              ),
                            ),
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      const Row(
                        children: [
                          Expanded(child: Divider()),
                          Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: AppSpacing.sm,
                            ),
                            child: Text('or'),
                          ),
                          Expanded(child: Divider()),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      SocialSignInButtons(
                        isSubmitting: state.isSubmitting,
                        onGoogleTap: () => context.read<AuthBloc>().add(
                          const AuthGoogleSignInRequested(),
                        ),
                        onAppleTap: () => context.read<AuthBloc>().add(
                          const AuthAppleSignInRequested(),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      TextButton(
                        onPressed: () => context.go('/sign-up'),
                        child: const Text("Don't have an account? Sign up"),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
