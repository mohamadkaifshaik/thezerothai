import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/auth_bloc.dart';
import '../bloc/auth_state.dart';
import 'verify_email_view.dart';

/// Wraps every protected route. Shows the email-verification prompt in place
/// of [child] when the signed-in user hasn't verified their email yet, so
/// the prompt works without a dedicated route (see [VerifyEmailView]).
class AuthGate extends StatelessWidget {
  const AuthGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final status = context.select((AuthBloc bloc) => bloc.state.status);
    if (status == AuthStatus.needsEmailVerification) {
      return const VerifyEmailView();
    }
    return child;
  }
}
