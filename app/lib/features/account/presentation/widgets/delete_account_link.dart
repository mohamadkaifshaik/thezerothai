import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_router.dart';

/// "Delete account" action for callers who have no profile yet or have not
/// verified their email (P8 L-5). Those callers cannot reach Settings, and the
/// server cannot delete them, so the delete page removes the Firebase Auth user
/// from the device. Shown without the `account_lifecycle` flag check because
/// `GetMe` (the flag source) is not available to these callers; store rules
/// (5.1.1(v)) require the action to exist.
class DeleteAccountLink extends StatelessWidget {
  const DeleteAccountLink({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return TextButton(
      style: TextButton.styleFrom(
        foregroundColor: theme.colorScheme.error,
        minimumSize: const Size(48, 48),
      ),
      onPressed: () => context.push(AppRouter.onboardingDeletePath),
      child: const Text('Delete account'),
    );
  }
}
