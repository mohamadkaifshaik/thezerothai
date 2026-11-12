import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../shared/widgets/primitives/app_pill_button.dart';
import '../../auth/presentation/bloc/auth_bloc.dart';
import '../../auth/presentation/bloc/auth_event.dart';
import '../../auth/presentation/widgets/auth_page_layout.dart' show AuthFrame;

/// Final page after DeleteAccount was accepted. Reachable signed out, so it
/// takes the auth pages' frame (AccountDeleted.html): the "Account status"
/// eyebrow, the headline, what happens next, and the way back to log in.
class AccountDeletedScreen extends StatelessWidget {
  const AccountDeletedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return AuthFrame(
      eyebrow: 'Account status',
      headline: 'A fresh ',
      accent: 'start',
      heroEyebrow: 'Good things start with a plan',
      heroHeadline: 'Your plans\ndeserve ',
      heroAccent: 'company',

      actions: AppPillButton(
        label: 'Back to log in',
        size: AppButtonSize.large,
        onPressed: () {
          // Idempotent: makes sure the session is gone even if the first
          // sign-out has not landed yet.
          final auth = context.read<AuthBloc>();
          if (auth.state.isAuthenticated) {
            auth.add(const AuthSignOutRequested());
          }
          context.go(AppRouter.signInPath);
        },
      ),
      children: [
        Text(
          'Your account is being deleted. You have been signed out. Deletion '
          'can take a little while to finish. You do not need to do anything '
          'else.',
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: muted),
        ),
      ],
    );
  }
}
