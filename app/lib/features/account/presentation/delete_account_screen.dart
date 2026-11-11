import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/telemetry/telemetry_device_forget.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../shared/widgets/primitives/app_pill_button.dart';
import '../../../shared/widgets/primitives/app_surface.dart';
import '../../../shared/widgets/primitives/settings_group.dart';
import '../../../core/widgets/shell_geometry.dart';
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
    _uid = context.read<AuthBloc>().state.user?.uid;
    _optInStore = context.read<PushOptInStore>();
    _telemetryForget = TelemetryForgetScope.of(context);
    _drafts = context.read<DraftsRepository>();
    _reportUnexpected = context.read<UnexpectedErrorReporter>();
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
          final enabled =
              !working && confirmed && state.status != AccountStatus.deleted;
          return Scaffold(
            appBar: AppBar(
              // The tablet layout with nothing to pop: up to Your account
              // (never at `/onboarding/delete-account`: no shell there).
              leading: settingsUpButton(
                context,
                settingsUpLocation(AppRouter.deleteAccountPath),
              ),
              title: const Text('Delete account'),
            ),
            body: Center(
              child: ConstrainedBox(
                // 680 as a Settings leaf in the tablet shell (the readable
                // column); 600 everywhere else, including
                // `/onboarding/delete-account` (AU: no shell, plan 4.2).
                constraints: BoxConstraints(
                  maxWidth: (ShellGeometry.maybeOf(context)?.tablet ?? false)
                      ? AppSize.readableMax
                      : AppSize.contentMax,
                ),
                child: ListView(
                  // Plus the floating bar's inset (`ui_shell`); 0 under the
                  // docked bar.
                  padding: const EdgeInsets.all(AppSpacing.md).copyWith(
                    bottom:
                        AppSpacing.md + MediaQuery.paddingOf(context).bottom,
                  ),
                  children: [
                    // DeleteAccount.dc.html: the danger eyebrow over the
                    // display headline.
                    Text(
                      "This can't be undone".toUpperCase(),
                      style: AppTextStyles.eyebrow(theme)
                          .copyWith(color: theme.colorScheme.error),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Semantics(
                      header: true,
                      child: Text(
                        'Delete your account?',
                        style: theme.textTheme.headlineMedium?.copyWith(
                          fontWeight: AppTypeTokens.weightDisplay,
                        ),
                      ),
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
                    if (hasProfile) ...[
                      // The design's card row (icon, title, chevron).
                      AppSurface(
                        padding: EdgeInsets.zero,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(
                            AppRadius.cardSmall,
                          ),
                          child: SettingsRow(
                            icon: Icons.download_outlined,
                            title: 'Download my data first',
                            onTap: working
                                ? null
                                : () => context.push(AppRouter.exportDataPath),
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                    ],
                    TextField(
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
                    const SizedBox(height: AppSpacing.md),
                    // The design's 56 dp danger pill.
                    AppPillButton(
                      label: 'Delete my account',
                      variant: AppButtonVariant.danger,
                      size: AppButtonSize.large,
                      busy: working,
                      busySemanticsLabel: 'Deleting account',
                      // Straight from the tap: the web re-auth popup must open
                      // inside the user gesture.
                      onPressed: enabled
                          ? () => _cubit.deleteAccount(
                              promptPassword: _promptPassword,
                            )
                          : null,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    _StatusMessage(state: state),
                  ],
                ),
              ),
            ),
          );
        },
      ),
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
/// AccountDeleted.dc.html: the "Account deleted" header, the "Account
/// status" eyebrow, the headline, the line and the Done pill, start aligned
/// in the content column.
class AccountDeletedScreen extends StatelessWidget {
  const AccountDeletedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('Account deleted'),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppSize.contentMax),
          // Outside the shell (signed out): the guard's reviewed exemption.
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Account status'.toUpperCase(),
                  style: AppTextStyles.eyebrow(theme)
                      .copyWith(color: context.appColors.accentText),
                ),
                const SizedBox(height: AppSpacing.sm),
                Semantics(
                  header: true,
                  child: Text(
                    'Your account is being deleted',
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: AppTypeTokens.weightDisplay,
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                Text(
                  'You have been signed out. Deletion can take a little while '
                  'to finish. You do not need to do anything else.',
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: AppPillButton(
                    label: 'Done',
                    onPressed: () {
                      // Idempotent: makes sure the session is gone even if the
                      // first sign-out has not landed yet.
                      final auth = context.read<AuthBloc>();
                      if (auth.state.isAuthenticated) {
                        auth.add(const AuthSignOutRequested());
                      }
                      context.go(AppRouter.signInPath);
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
