import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/auth_repository.dart';
import '../../domain/app_user.dart';
import '../../domain/auth_failure.dart';
import 'auth_event.dart';
import 'auth_state.dart';

/// How long sign-out waits for the `beforeSignOut` hook.
const kBeforeSignOutTimeout = Duration(seconds: 3);

class AuthBloc extends Bloc<AuthEvent, AuthState> {
  /// Provider configuration (Google web client id, Apple service id and
  /// redirect URI) lives on [AuthRepository], the single source shared with
  /// re-authentication.
  AuthBloc({
    required AuthRepository authRepository,
    Future<void> Function()? beforeSignOut,
  }) : _authRepository = authRepository,
       _beforeSignOut = beforeSignOut,
       super(const AuthState()) {
    on<AuthSubscriptionRequested>(_onSubscriptionRequested);
    on<AuthUserChanged>(_onUserChanged);
    on<AuthEmailSignUpRequested>(_onEmailSignUpRequested);
    on<AuthEmailSignInRequested>(_onEmailSignInRequested);
    on<AuthGoogleSignInRequested>(_onGoogleSignInRequested);
    on<AuthAppleSignInRequested>(_onAppleSignInRequested);
    on<AuthEmailVerificationResendRequested>(_onVerificationResendRequested);
    on<AuthEmailVerificationCheckRequested>(_onVerificationCheckRequested);
    on<AuthSignOutRequested>(_onSignOutRequested);
    on<AuthFailureDismissed>((event, emit) {
      emit(state.copyWith(failure: null));
    });
  }

  final AuthRepository _authRepository;

  /// Best-effort work that needs the ID token (unregistering the push
  /// device, ADR-0017), run before the Firebase sign-out. Bounded by
  /// [kBeforeSignOutTimeout]; a failure or a timeout never blocks sign-out.
  final Future<void> Function()? _beforeSignOut;
  StreamSubscription<AppUser?>? _userSubscription;

  void _onSubscriptionRequested(
    AuthSubscriptionRequested event,
    Emitter<AuthState> emit,
  ) {
    _userSubscription?.cancel();
    _userSubscription = _authRepository.authStateChanges().listen(
      (user) => add(AuthUserChanged(user)),
    );
  }

  void _onUserChanged(AuthUserChanged event, Emitter<AuthState> emit) {
    final user = event.user;
    final status = switch (user) {
      null => AuthStatus.unauthenticated,
      AppUser(:final isPasswordProvider, :final emailVerified)
          when isPasswordProvider && !emailVerified =>
        AuthStatus.needsEmailVerification,
      _ => AuthStatus.authenticated,
    };
    emit(state.copyWith(status: status, user: user, isSubmitting: false));
  }

  Future<void> _onEmailSignUpRequested(
    AuthEmailSignUpRequested event,
    Emitter<AuthState> emit,
  ) async {
    emit(state.copyWith(isSubmitting: true, failure: null));
    await _run(
      emit,
      () => _authRepository.signUpWithEmail(
        email: event.email,
        password: event.password,
      ),
    );
  }

  Future<void> _onEmailSignInRequested(
    AuthEmailSignInRequested event,
    Emitter<AuthState> emit,
  ) async {
    emit(state.copyWith(isSubmitting: true, failure: null));
    await _run(
      emit,
      () => _authRepository.signInWithEmail(
        email: event.email,
        password: event.password,
      ),
    );
  }

  Future<void> _onGoogleSignInRequested(
    AuthGoogleSignInRequested event,
    Emitter<AuthState> emit,
  ) async {
    emit(state.copyWith(isSubmitting: true, failure: null));
    await _run(emit, _authRepository.signInWithGoogle);
  }

  Future<void> _onAppleSignInRequested(
    AuthAppleSignInRequested event,
    Emitter<AuthState> emit,
  ) async {
    emit(state.copyWith(isSubmitting: true, failure: null));
    await _run(emit, _authRepository.signInWithApple);
  }

  Future<void> _onVerificationResendRequested(
    AuthEmailVerificationResendRequested event,
    Emitter<AuthState> emit,
  ) async {
    emit(state.copyWith(isSubmitting: true, failure: null));
    await _run(emit, () => _authRepository.sendEmailVerification());
  }

  Future<void> _onVerificationCheckRequested(
    AuthEmailVerificationCheckRequested event,
    Emitter<AuthState> emit,
  ) async {
    emit(state.copyWith(isSubmitting: true, failure: null));
    await _run(emit, () => _authRepository.reloadUser());
    // Force-refresh the ID token so its `email_verified` claim is current:
    // Firebase only re-mints claims on refresh, and a cached token can be up
    // to an hour stale, which would make the server reject actions that
    // require a verified email right after the user just verified it. Best
    // effort: a transient failure here shouldn't block the UI from moving
    // past the verification prompt (the token will refresh again on the next
    // API call regardless).
    try {
      await _authRepository.getIdToken(forceRefresh: true);
    } catch (_) {
      // Ignored: see comment above.
    }
    // `reload()` updates the cached FirebaseAuth.currentUser but does not
    // reliably re-emit on `userChanges()` on every platform; refresh
    // explicitly so the UI doesn't get stuck on the verification prompt.
    add(AuthUserChanged(_authRepository.currentUser));
  }

  Future<void> _onSignOutRequested(
    AuthSignOutRequested event,
    Emitter<AuthState> emit,
  ) async {
    final before = _beforeSignOut;
    if (before != null) {
      try {
        await before().timeout(kBeforeSignOutTimeout);
      } catch (_) {
        // Never block sign-out on bookkeeping.
      }
    }
    await _authRepository.signOut();
  }

  /// Runs [action], turning a thrown [AuthFailure] into `state.failure` and
  /// always clearing `isSubmitting` afterwards. Successful sign-in state
  /// changes arrive separately via the `authStateChanges()` subscription.
  Future<void> _run(
    Emitter<AuthState> emit,
    Future<void> Function() action,
  ) async {
    try {
      await action();
      emit(state.copyWith(isSubmitting: false));
    } on AuthFailure catch (failure) {
      emit(state.copyWith(isSubmitting: false, failure: failure));
    } catch (error) {
      emit(
        state.copyWith(
          isSubmitting: false,
          failure: AuthFailure.unknown(error.toString()),
        ),
      );
    }
  }

  @override
  Future<void> close() {
    _userSubscription?.cancel();
    return super.close();
  }
}
