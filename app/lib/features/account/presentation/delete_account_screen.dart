import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/telemetry/telemetry_device_forget.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../shared/widgets/primitives/app_form_page.dart';
import '../../../shared/widgets/primitives/app_pill_button.dart'
    show AppButtonVariant;
import '../../../shared/widgets/primitives/app_surface.dart';
import '../../../shared/widgets/primitives/settings_group.dart';
import '../../auth/data/auth_repository.dart';
import '../../auth/domain/auth_failure.dart';
import '../../auth/presentation/bloc/auth_bloc.dart';
import '../../auth/presentation/bloc/auth_event.dart';
import '../../auth/presentation/bloc/auth_state.dart';
import '../../notifications/data/push_opt_in_store.dart';
import '../../posts/data/drafts_repository.dart';
import '../../settings/presentation/settings_up.dart';
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../../app/session_wiring.dart' show UnexpectedErrorReporter;
import '../data/account_repository.dart';
import 'bloc/account_cubit.dart';

/// Friendly text for a failed DeleteAccount (never the raw server message).
String deleteAccountErrorMessage(AppException error) {
  return switch (error) {
    ReauthRequiredException() =>
      "We couldn't confirm it's you. Please sign in again, then retry.",
    final RateLimitedException e => rateLimitedMessage(e),
    QuotaExceededException() =>
      "You've hit today's limit for this action. It resets tomorrow.",
    DegradedModeException() =>
      'Dzeroth is in a limited mode right now. Please try again shortly.',
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

/// The word typed to confirm when the caller has no handle yet (no profile).
const deleteConfirmWord = 'DELETE';

/// True when [typed] is [deleteConfirmWord] (case-insensitive).
bool confirmWordMatches(String typed) =>
    typed.trim().toLowerCase() == deleteConfirmWord.toLowerCase();

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
  final _passwordController = TextEditingController();

  // Password accounts type the password right here (it feeds the same
  // re-authentication); Google and Apple accounts have none and re-confirm
  // through their provider after the handle gate.
  late final bool _usesPassword;
  late final AuthRepository _auth;

  // The account being deleted, read before anything signs it out (the auth
  // listener below can fire after the user is already gone).
  late final String? _uid;
  late final PushOptInStore _optInStore;
  late final TelemetryDeviceForget _telemetryForget;
  late final DraftsRepository _drafts;
  late final UnexpectedErrorReporter _reportUnexpected;

  @override
  void initState() {
    super.initState();
    final user = context.read<AuthBloc>().state.user;
    _uid = user?.uid;
    _usesPassword = user?.isPasswordProvider ?? false;
    _auth = context.read<AuthRepository>();
    _optInStore = context.read<PushOptInStore>();
    _telemetryForget = TelemetryForgetScope.of(context);
    _drafts = context.read<DraftsRepository>();
    _reportUnexpected = context.read<UnexpectedErrorReporter>();
    _cubit = AccountCubit(
      accountRepository: context.read<AccountRepository>(),
      authRepository: _auth,
      onUnexpectedError: context.read<UnexpectedErrorReporter>(),
    );
  }

  @override
  void dispose() {
    // Abandon a flow stuck behind a provider UI (no-op once the RPC is sent).
    _cubit.reset();
    _cubit.close();
    _handleController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  /// The inline field's text; an empty field (never sendable: the button is
  /// disabled) reads as "cancelled".
  Future<String?> _typedPassword() async => _passwordController.text;

  void _delete() {
    // Straight from the tap: the web re-auth popup must open inside the user
    // gesture, so nothing is awaited before the cubit starts.
    _cubit.deleteAccount(
      promptPassword: _typedPassword,
      skipReauth: !_usesPassword && _auth.canSkipDeleteReauth,
    );
  }

  void _onState(BuildContext context, AccountState state) {
    if (state.status != AccountStatus.deleted) return;
    // Show the final page first (it is reachable signed out), then sign out;
    // the session-wiring listener wipes the drift caches.
    final router = GoRouter.of(context);
    final auth = context.read<AuthBloc>();
    unawaited(
      _forgetAccount().whenComplete(() {
        router.go(AppRouter.accountDeletedPath);
        auth.add(const AuthSignOutRequested());
      }),
    );
  }

  /// The deleted account's "Not now" record goes with it (L-6): the
  /// device setting survives a plain sign-out on purpose, but the uid of a
  /// deleted account must not. A storage failure never blocks the final page.
  Future<void> _forgetAccount() async {
    final uid = _uid;
    if (uid == null) return;
    // Drafts first and apart from the opt-in record, so one failing never
    // keeps the other (the unsent text of a deleted account must not stay).
    try {
      await _drafts.deleteAll(uid);
    } catch (error, stack) {
      _reportUnexpected.call(error, stack);
    }
    try {
      await _optInStore.forget(uid);
    } catch (error, stack) {
      _reportUnexpected.call(error, stack);
    }
    // Consent keys, unsent crash reports and the analytics ID of this
    // device go with the account (never throws).
    await _telemetryForget.call(uid);
  }

  @override
  Widget build(BuildContext context) {
    final handle = context.select(
      (OnboardingBloc b) => b.state.profile?.handle ?? '',
    );
    final theme = Theme.of(context);
    // No handle means no profile (L-5): confirm with a word instead.
    final hasProfile = handle.isNotEmpty;
    return BlocListener<AuthBloc, AuthState>(
      // The client-side Auth user delete signs the user out; Firebase can
      // report that before the cubit emits `deleted`, and the router would
      // then leave this screen with no confirmation page.
      listenWhen: (previous, current) =>
          current.status == AuthStatus.unauthenticated &&
          _cubit.state.status == AccountStatus.working,
      listener: (context, _) {
        final router = GoRouter.of(context);
        unawaited(
          _forgetAccount().whenComplete(
            () => router.go(AppRouter.accountDeletedPath),
          ),
        );
      },
      child: BlocConsumer<AccountCubit, AccountState>(
        bloc: _cubit,
        listener: _onState,
        builder: (context, state) {
          final working = state.status == AccountStatus.working;
          final confirmed = hasProfile
              ? handleMatches(_handleController.text, handle)
              : confirmWordMatches(_handleController.text);
          final passwordOk =
              !_usesPassword || _passwordController.text.isNotEmpty;
          final enabled =
              !working &&
              confirmed &&
              passwordOk &&
              state.status != AccountStatus.deleted;
          // A wrong password belongs under the password field.
          final wrongPassword =
              _usesPassword && state.authFailure is AuthInvalidCredentials;
          return AppFormPage(
            title: 'Delete account',
            // The tablet layout with nothing to pop: up to Your account
            // (never at `/onboarding/delete-account`: no shell there).
            leading: settingsUpButton(
              context,
              settingsUpLocation(AppRouter.deleteAccountPath),
            ),
            // DeleteAccount.html: the danger eyebrow over the display
            // headline.
            eyebrow: "This can't be undone".toUpperCase(),
            eyebrowColor: theme.colorScheme.error,
            headlineLead: 'Leaving DZEROTH?',

            primary: AppFormAction(
              label: 'Delete my account',
              variant: AppButtonVariant.danger,
              busy: working,
              busySemanticsLabel: 'Deleting account',
              onPressed: enabled ? _delete : null,
            ),
            secondary: AppFormAction(
              label: 'Cancel',
              onPressed: working ? null : () => _cancel(context),
            ),
            children: [
              const Text(
                'This is permanent and cannot be undone. We delete your '
                'profile, your posts and media, and your follows, blocks and '
                'mutes.',
              ),
              const Text(
                "What remains: mentions of you in other people's posts, "
                'and backups, which expire within 14 days.',
              ),
              if (hasProfile)
                // The design's card row (icon, title, chevron).
                AppSurface(
                  padding: EdgeInsets.zero,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.cardSmall),
                    child: SettingsRow(
                      icon: Icons.download_outlined,
                      title: 'Download my data first',
                      onTap: working
                          ? null
                          : () => context.push(AppRouter.exportDataPath),
                    ),
                  ),
                ),
              TextField(
                key: const ValueKey('delete-account-handle'),
                controller: _handleController,
                enabled: !working,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: !hasProfile
                      ? 'Type $deleteConfirmWord to confirm'
                      : 'Type your handle ($handle) to confirm',
                ),
                onChanged: (_) => setState(() {}),
              ),
              if (_usesPassword)
                TextField(
                  key: const ValueKey('delete-account-password'),
                  controller: _passwordController,
                  enabled: !working,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  textInputAction: TextInputAction.done,
                  autofillHints: const [AutofillHints.password],
                  decoration: InputDecoration(
                    labelText: 'Enter your password to confirm',
                    errorText: wrongPassword
                        ? 'Incorrect password. Try again.'
                        : null,
                  ),
                  onChanged: (_) {
                    _cubit.dismissMessage();
                    setState(() {});
                  },
                  onSubmitted: (_) {
                    if (enabled) _delete();
                  },
                ),

              _StatusMessage(state: state, hideAuthFailure: wrongPassword),
            ],
          );
        },
      ),
    );
  }

  /// Back to where the page was opened from; with nothing to pop (a typed
  /// URL), to Settings, or its category on the tablet layout.
  void _cancel(BuildContext context) {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(
        settingsLeafExitLocation(context, AppRouter.deleteAccountPath),
      );
    }
  }
}

class _StatusMessage extends StatelessWidget {
  const _StatusMessage({required this.state, this.hideAuthFailure = false});

  final AccountState state;

  /// The failure is shown inline under a field instead.
  final bool hideAuthFailure;

  @override
  Widget build(BuildContext context) {
    if (hideAuthFailure) return const SizedBox.shrink();
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
