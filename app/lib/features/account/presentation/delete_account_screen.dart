import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../auth/data/auth_repository.dart';
import '../../auth/domain/auth_failure.dart';
import '../../auth/presentation/bloc/auth_bloc.dart';
import '../../auth/presentation/bloc/auth_event.dart';
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../../app/session_wiring.dart' show UnexpectedErrorReporter;
import '../data/account_repository.dart';
import 'bloc/account_cubit.dart';
import 'widgets/password_prompt_dialog.dart';

/// Friendly text for a failed DeleteAccount (never the raw server message).
String deleteAccountErrorMessage(AppException error) {
  return switch (error) {
    ReauthRequiredException() =>
      "We couldn't confirm it's you. Please sign in again, then retry.",
    final RateLimitedException e => rateLimitedMessage(e),
    QuotaExceededException() =>
      "You've hit today's limit for this action. It resets tomorrow.",
    DegradedModeException() =>
      'dZeroth is in a limited mode right now. Please try again shortly.',
    FeatureDisabledException() => "This feature isn't available yet.",
    NetworkException() => 'No connection. Check your network and try again.',
    AccountRestrictedException() =>
      "This account can't be changed right now. If you already asked to "
          'delete it, deletion is in progress; sign out and check back later.',
    UnauthenticatedException() =>
      'Your session expired. Please sign in again, then retry.',
    EmailNotVerifiedException() =>
      'Please verify your email address to continue.',
    // Unreachable in practice (the cubit maps every unexpected error to
    // UnknownApiException); kept so no raw server text can ever show.
    _ => 'Something went wrong. Please try again.',
  };
}

/// True when [typed] is the caller's handle (case-insensitive, optional
/// leading "@", surrounding spaces ignored). An empty [handle] never matches.
bool handleMatches(String typed, String handle) {
  final t = typed.trim().replaceFirst(RegExp('^@'), '').toLowerCase();
  return handle.isNotEmpty && t == handle.toLowerCase();
}

/// Settings -> Delete account (`/settings/delete-account`, only reachable
/// with the `account_lifecycle` flag on). Explains the consequences, asks for
/// the handle, then re-authenticates and calls DeleteAccount through
/// [AccountCubit] (one request per completed intent).
class DeleteAccountScreen extends StatefulWidget {
  const DeleteAccountScreen({super.key});

  @override
  State<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends State<DeleteAccountScreen> {
  late final AccountCubit _cubit;
  final _handleController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _cubit = AccountCubit(
      accountRepository: context.read<AccountRepository>(),
      authRepository: context.read<AuthRepository>(),
      onUnexpectedError: context.read<UnexpectedErrorReporter>(),
    );
  }

  @override
  void dispose() {
    // Abandon a flow stuck behind a provider UI (no-op once the RPC is sent).
    _cubit.reset();
    _cubit.close();
    _handleController.dispose();
    super.dispose();
  }

  Future<String?> _promptPassword() => showPasswordPromptDialog(context);

  void _onState(BuildContext context, AccountState state) {
    if (state.status != AccountStatus.deleted) return;
    // Show the final page first (it is reachable signed out), then sign out;
    // the session-wiring listener wipes the drift caches.
    context.go(AppRouter.accountDeletedPath);
    context.read<AuthBloc>().add(const AuthSignOutRequested());
  }

  @override
  Widget build(BuildContext context) {
    final handle = context.select(
      (OnboardingBloc b) => b.state.profile?.handle ?? '',
    );
    final theme = Theme.of(context);
    return BlocConsumer<AccountCubit, AccountState>(
      bloc: _cubit,
      listener: _onState,
      builder: (context, state) {
        final working = state.status == AccountStatus.working;
        final enabled =
            !working &&
            handleMatches(_handleController.text, handle) &&
            state.status != AccountStatus.deleted;
        return Scaffold(
          appBar: AppBar(title: const Text('Delete account')),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600),
              child: ListView(
                padding: const EdgeInsets.all(AppSpacing.md),
                children: [
                  Text(
                    'Delete your account?',
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  const Text(
                    'This is permanent and cannot be undone. We delete your '
                    'profile, your posts and media, and your follows, '
                    'blocks and mutes.',
                  ),
                  const SizedBox(height: AppSpacing.md),
                  const Text(
                    "What remains: mentions of you in other people's posts, "
                    'and backups, which expire within 14 days.',
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton.icon(
                      onPressed: working
                          ? null
                          : () => context.push(AppRouter.exportDataPath),
                      icon: const Icon(Icons.download_outlined),
                      label: const Text('Download my data first'),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  TextField(
                    controller: _handleController,
                    enabled: !working,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: handle.isEmpty
                          ? 'Type your handle to confirm'
                          : 'Type your handle ($handle) to confirm',
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: theme.colorScheme.error,
                      foregroundColor: theme.colorScheme.onError,
                    ),
                    // Straight from the tap: the web re-auth popup must open
                    // inside the user gesture.
                    onPressed: enabled
                        ? () => _cubit.deleteAccount(
                            promptPassword: _promptPassword,
                          )
                        : null,
                    child: working
                        ? const SizedBox.square(
                            dimension: AppSpacing.lg - AppSpacing.xs,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              semanticsLabel: 'Deleting account',
                            ),
                          )
                        : const Text('Delete my account'),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _StatusMessage(state: state),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _StatusMessage extends StatelessWidget {
  const _StatusMessage({required this.state});

  final AccountState state;

  @override
  Widget build(BuildContext context) {
    final text = switch (state.status) {
      AccountStatus.cancelled =>
        'Confirmation cancelled. Nothing was changed or deleted.',
      AccountStatus.failed =>
        state.authFailure != null
            ? state.authFailure!.message
            : deleteAccountErrorMessage(
                state.error ?? const UnknownApiException(''),
              ),
      _ => null,
    };
    if (text == null) return const SizedBox.shrink();
    final isError = state.status == AccountStatus.failed;
    return Semantics(
      liveRegion: true,
      child: Text(
        text,
        style: TextStyle(
          color: isError ? Theme.of(context).colorScheme.error : null,
        ),
      ),
    );
  }
}

/// Final page after DeleteAccount was accepted. Reachable signed out.
class AccountDeletedScreen extends StatelessWidget {
  const AccountDeletedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.check_circle_outline, size: 48),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    'Your account is being deleted',
                    style: Theme.of(context).textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  const Text(
                    'You have been signed out. Deletion can take a little while '
                    'to finish. You do not need to do anything else.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(160, AppSpacing.minTapTarget),
                    ),
                    onPressed: () {
                      // Idempotent: makes sure the session is gone even if the
                      // first sign-out has not landed yet.
                      final auth = context.read<AuthBloc>();
                      if (auth.state.isAuthenticated) {
                        auth.add(const AuthSignOutRequested());
                      }
                      context.go(AppRouter.signInPath);
                    },
                    child: const Text('Done'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
