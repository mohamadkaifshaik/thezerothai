import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../account/presentation/widgets/account_restricted_view.dart';
import '../../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../bloc/auth_bloc.dart';
import '../bloc/auth_state.dart';
import 'verify_email_view.dart';

/// Wraps every protected route. Shows the email-verification prompt in place
/// of [child] when the signed-in user hasn't verified their email yet, so
/// the prompt works without a dedicated route (see [VerifyEmailView]).
///
/// A suspended (restricted) account gets [AccountRestrictedView] instead: its
/// RPCs all answer ACCOUNT_RESTRICTED (ADR-0016), so no screen could work.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final status = context.select((AuthBloc bloc) => bloc.state.status);
    if (status == AuthStatus.needsEmailVerification) {
      return const VerifyEmailView();
    }
    if (_accountRestricted(context)) return const AccountRestrictedView();
    return child;
  }
}

/// Whether the signed-in account is restricted. False when no onboarding flow
/// is provided (screens used standalone).
bool _accountRestricted(BuildContext context) {
  try {
    return context.select(
      (OnboardingBloc bloc) => bloc.state.accountRestricted,
    );
  } on Exception {
    return false;
  }
}
