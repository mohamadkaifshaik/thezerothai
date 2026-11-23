import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../domain/auth_failure.dart';
import 'bloc/auth_bloc.dart';
import 'bloc/auth_event.dart';
import 'bloc/auth_state.dart';
import 'widgets/auth_page_layout.dart';
import 'widgets/email_password_form.dart';
import 'widgets/session_ended_notice.dart';
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

  // "An account with this email already exists": shown inline, with a way
  // to sign in, instead of a snackbar that is gone before it is read. Cleared
  // by the next submit.
  bool _accountExists = false;

  bool get signUp => widget.signUp;

  void _switchMode(BuildContext context) =>
      context.go(signUp ? AppRouter.signInPath : AppRouter.signUpPath);

  @override
  Widget build(BuildContext context) => BlocConsumer<AuthBloc, AuthState>(
    listenWhen: (previous, current) => current.failure != null,
    listener: (context, state) {
      final failure = state.failure;
      if (failure == null || failure.message.isEmpty) return;
      if (signUp && failure is AuthEmailAlreadyInUse) {
        setState(() => _accountExists = true);
        context.read<AuthBloc>().add(const AuthFailureDismissed());
        return;
      }
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
        onBack: state.isSubmitting
            ? null
            : () => context.go(AppRouter.welcomePath),
        form: ({required fieldIcons, required dense, required builder}) =>
            EmailPasswordForm(
              key: _formKey,
              submitLabel: copy.submitLabel,
              isSubmitting: state.isSubmitting,
              confirmPassword: signUp,
              fieldIcons: fieldIcons,
              dense: dense,
              builder: builder,
              notice: signUp && _accountExists
                  ? _AccountExistsNotice(
                      onSignIn: state.isSubmitting
                          ? null
                          : () => _switchMode(context),
                    )
                  : !signUp && state.signedOutByDeviceRemoval
                  ? const SessionEndedNotice()
                  : null,
              onSubmit: (email, password) {
                if (_accountExists) setState(() => _accountExists = false);
                bloc.add(
                  signUp
                      ? AuthEmailSignUpRequested(
                          email: email,
                          password: password,
                        )
                      : AuthEmailSignInRequested(
                          email: email,
                          password: password,
                        ),
                );
              },
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

/// The sign-up note for an address that already has an account.
class _AccountExistsNotice extends StatelessWidget {
  const _AccountExistsNotice({required this.onSignIn});

  final VoidCallback? onSignIn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'An account with this email already exists.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: context.appColors.accentText,
              padding: EdgeInsets.zero,
              alignment: AlignmentDirectional.centerStart,
            ),
            onPressed: onSignIn,
            child: const Text('Log in instead'),
          ),
        ],
      ),
    );
  }
}
