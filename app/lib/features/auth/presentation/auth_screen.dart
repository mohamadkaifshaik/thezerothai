import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../domain/auth_failure.dart';
import 'bloc/auth_bloc.dart';
import 'bloc/auth_event.dart';
import 'bloc/auth_state.dart';
import 'widgets/auth_page_layout.dart';
import 'widgets/email_password_form.dart';
import 'widgets/social_sign_in_buttons.dart';

/// Sign-in and sign-up (one screen, two modes) on the real auth BLoC. The
/// phone, tablet and desktop looks share the form, providers and routes.
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, required this.signUp});
  final bool signUp;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  // One form state across the three looks, so typed input survives a
  // window resize that moves the form to another subtree.
  final _formKey = GlobalKey(debugLabel: 'auth-email-form');

  bool get signUp => widget.signUp;

  void _switchMode(BuildContext context) =>
      context.go(signUp ? '/sign-in' : '/sign-up');

  @override
  Widget build(BuildContext context) => BlocConsumer<AuthBloc, AuthState>(
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
      final copy = signUp ? AuthCopy.signUp : AuthCopy.signIn;
      final bloc = context.read<AuthBloc>();
      return AuthPageLayout(
        copy: copy,
        signUp: signUp,
        onSwitchMode: state.isSubmitting ? null : () => _switchMode(context),
        form: ({required fieldIcons, required dense, required builder}) =>
            EmailPasswordForm(
              key: _formKey,
              submitLabel: copy.submitLabel,
              isSubmitting: state.isSubmitting,
              confirmPassword: signUp,
              fieldIcons: fieldIcons,
              dense: dense,
              builder: builder,
              onSubmit: (email, password) => bloc.add(
                signUp
                    ? AuthEmailSignUpRequested(email: email, password: password)
                    : AuthEmailSignInRequested(
                        email: email,
                        password: password,
                      ),
              ),
            ),
        social: SocialSignInButtons(
          isSubmitting: state.isSubmitting,
          onGoogleTap: () => bloc.add(const AuthGoogleSignInRequested()),
          onAppleTap: () => bloc.add(const AuthAppleSignInRequested()),
        ),
      );
    },
  );
}
