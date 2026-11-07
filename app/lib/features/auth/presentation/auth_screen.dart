import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/privacy_policy_link.dart';
import '../domain/auth_failure.dart';
import 'bloc/auth_bloc.dart';
import 'bloc/auth_event.dart';
import 'bloc/auth_state.dart';
import 'widgets/auth_design.dart';
import 'widgets/auth_experience_layout.dart';
import 'widgets/email_password_form.dart';
import 'widgets/social_sign_in_buttons.dart';

/// Native port of the approved provider/email states, using the real auth BLoC.
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, required this.signUp});
  final bool signUp;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  bool _email = false;
  final _emailFocus = FocusNode();
  final _optionsFocus = FocusNode();

  @override
  void dispose() {
    _emailFocus.dispose();
    _optionsFocus.dispose();
    super.dispose();
  }

  void _showEmail(bool value) {
    setState(() => _email = value);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) (value ? _emailFocus : _optionsFocus).requestFocus();
    });
  }

  void _mode(bool signup) {
    if (signup != widget.signUp) context.go(signup ? '/sign-up' : '/sign-in');
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: AuthDesign.theme(Theme.of(context)),
    child: Builder(
      builder: (context) => Scaffold(
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
            builder: (context, state) => AuthExperienceLayout(
              signUp: widget.signUp,
              emailActive: _email,
              onModeChanged: state.isSubmitting ? null : _mode,
              children: [
                // Keep the form mounted across provider reveal and theme changes.
                Offstage(
                  key: const ValueKey('auth-email-draft'),
                  offstage: !_email,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: state.isSubmitting
                              ? null
                              : () => _showEmail(false),
                          child: const Text('← All sign-in options'),
                        ),
                      ),
                      EmailPasswordForm(
                        emailFocusNode: _emailFocus,
                        submitLabel: widget.signUp
                            ? 'Create account'
                            : 'Log in',
                        isSubmitting: state.isSubmitting,
                        confirmPassword: widget.signUp,
                        onSubmit: (email, password) =>
                            context.read<AuthBloc>().add(
                              widget.signUp
                                  ? AuthEmailSignUpRequested(
                                      email: email,
                                      password: password,
                                    )
                                  : AuthEmailSignInRequested(
                                      email: email,
                                      password: password,
                                    ),
                            ),
                      ),
                    ],
                  ),
                ),
                if (!_email) ...[
                  SocialSignInButtons(
                    isSubmitting: state.isSubmitting,
                    onGoogleTap: () => context.read<AuthBloc>().add(
                      const AuthGoogleSignInRequested(),
                    ),
                    onAppleTap: () => context.read<AuthBloc>().add(
                      const AuthAppleSignInRequested(),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 23),
                    child: Row(
                      children: [
                        const Expanded(child: Divider(height: 1)),
                        Flexible(
                          flex: 3,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Text(
                              'or keep it classic',
                              textAlign: TextAlign.center,
                              style: AuthDesign.body(
                                10,
                                color: AuthDesign.muted(context),
                              ),
                            ),
                          ),
                        ),
                        const Expanded(child: Divider(height: 1)),
                      ],
                    ),
                  ),
                  AuthActionButton(
                    focusNode: _optionsFocus,
                    label: 'Continue with Email',
                    icon: const Icon(Icons.mail_outline, size: 19),
                    primary: true,
                    busy: state.isSubmitting,
                    onPressed: state.isSubmitting
                        ? null
                        : () => _showEmail(true),
                  ),
                ],
                Padding(
                  padding: EdgeInsets.only(
                    top: _email ? 18 : 20,
                    bottom: _email ? 20 : 28,
                  ),
                  child: DefaultTextStyle(
                    style: AuthDesign.body(
                      10,
                      color: AuthDesign.muted(context),
                    ).copyWith(height: 1.9),
                    child: Theme(
                      data: Theme.of(context).copyWith(
                        textTheme: Theme.of(context).textTheme
                            .copyWith(bodySmall: AuthDesign.body(10)),
                      ),
                      child: PrivacyPolicyLink(
                        leadingText: widget.signUp
                            ? "By signing up you confirm you're 18 or older and agree to our "
                            : null,
                      ),
                    ),
                  ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: EdgeInsets.only(top: _email ? 20 : 25),
                  child: Wrap(
                    alignment: WrapAlignment.center,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        widget.signUp
                            ? 'Already part of the plan?'
                            : 'New around here?',
                        style: AuthDesign.body(
                          11,
                          color: AuthDesign.muted(context),
                        ),
                      ),
                      TextButton(
                        onPressed: state.isSubmitting
                            ? null
                            : () => _mode(!widget.signUp),
                        child: Text(
                          widget.signUp ? 'Log in ↗' : 'Find your people ↗',
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
