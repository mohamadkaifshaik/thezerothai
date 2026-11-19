import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/auth_repository.dart';
import '../../domain/app_user.dart';
import '../../domain/auth_failure.dart';
import 'auth_event.dart';
import 'auth_state.dart';

/// How long sign-out waits for the `beforeSignOut` hook.
const kBeforeSignOutTimeout = Duration(seconds: 3);

/// How long the app waits for the auth SDK's first event before falling back
/// to its current user (web can stall on persistence or a wrong emulator).
const kAuthUnknownTimeout = Duration(seconds: 10);

class AuthBloc extends Bloc<AuthEvent, AuthState> {
  /// Provider configuration (Google web client id, Apple service id and
  /// redirect URI) lives on [AuthRepository], the single source shared with
  /// re-authentication.
  AuthBloc({
    required AuthRepository authRepository,
    Future<void> Function()? beforeSignOut,
    Future<void> Function(String uid)? beforeExplicitSignOut,
    void Function(String uid)? onSignOutFailed,
    Duration? unknownTimeout,
  }) : _authRepository = authRepository,
       _unknownTimeout = unknownTimeout,
       _beforeSignOut = beforeSignOut,
       _beforeExplicitSignOut = beforeExplicitSignOut,
       _onSignOutFailed = onSignOutFailed,
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
  /// device), run before the Firebase sign-out. Bounded by
  /// [kBeforeSignOutTimeout]; a failure or a timeout never blocks sign-out.
  final Future<void> Function()? _beforeSignOut;

  /// Runs beside [_beforeSignOut], in the same budget, only when an intent
  /// was armed for the signed-in uid (the vault records the explicit end
  /// and removes the device from the key directory). Never for an event
  /// expressed for another account.
  final Future<void> Function(String uid)? _beforeExplicitSignOut;

  /// The sign-out failed and that user is still signed in: the armed intent
  /// was dropped (the vault forgets its pending end).
  final void Function(String uid)? _onSignOutFailed;
  StreamSubscription<AppUser?>? _userSubscription;

  /// When set, a first auth event that has not arrived by then settles the
  /// status from the SDK's current user (null: signed out), so the app never
  /// sits on the splash for good. A later real event still wins.
  final Duration? _unknownTimeout;
  Timer? _unknownTimer;

  void _onSubscriptionRequested(
    AuthSubscriptionRequested event,
    Emitter<AuthState> emit,
  ) {
    _userSubscription?.cancel();
    final timeout = _unknownTimeout;
    if (timeout != null) {
      _unknownTimer?.cancel();
      _unknownTimer = Timer(timeout, () {
        if (!isClosed && state.status == AuthStatus.unknown) {
          add(AuthUserChanged(_authRepository.currentUser));
        }
      });
    }
    _userSubscription = _authRepository.authStateChanges().listen(
      (user) => add(AuthUserChanged(user)),
      // A failing auth stream must not leave the app on the splash screen
      // (status unknown) for good: fall back to signed out.
      // A stream error is a lost session (never an explicit sign-out).
      onError: (Object _, StackTrace _) =>
          add(const AuthUserChanged(null, fromStreamError: true)),
    );
  }

  /// The explicit sign-out intent, bound to the uid signed in when it was
  /// expressed. Consumed by the next end of that uid's session; dropped by
  /// a failed sign-out and by any change of user.
  ({String uid, SessionEnd reason})? _intent;

  void _onUserChanged(AuthUserChanged event, Emitter<AuthState> emit) {
    _unknownTimer?.cancel();
    final user = event.user;
    final status = switch (user) {
      null => AuthStatus.unauthenticated,
      AppUser(:final isPasswordProvider, :final emailVerified)
          when isPasswordProvider && !emailVerified =>
        AuthStatus.needsEmailVerification,
      _ => AuthStatus.authenticated,
    };
    final previous = state.user;
    var lastSessionEnd = state.lastSessionEnd;
    if (user?.uid != previous?.uid) {
      final intent = _intent;
      _intent = null;
      if (user == null) {
        lastSessionEnd = _endOf(previous?.uid, intent, event.fromStreamError);
      }
    } else if (event.fromStreamError) {
      lastSessionEnd = SessionEnd.sessionLost;
    }
    emit(
      state.copyWith(
        status: status,
        user: user,
        isSubmitting: false,
        lastSessionEnd: lastSessionEnd,
      ),
    );
  }

  /// Why the session of [uid] ended: the explicit intent for that uid, the
  /// account flow's record ([AuthRepository.takeSessionEndIntent]), else
  /// lost. A stream error is always lost.
  SessionEnd _endOf(
    String? uid,
    ({String uid, SessionEnd reason})? intent,
    bool fromStreamError,
  ) {
    if (uid == null) return SessionEnd.sessionLost;
    // Consumed whatever the outcome, so it cannot apply to a later end.
    final recorded = _authRepository.takeSessionEndIntent(uid);
    if (fromStreamError) return SessionEnd.sessionLost;
    if (intent != null && intent.uid == uid) return intent.reason;
    return recorded ?? SessionEnd.sessionLost;
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
    // The request belongs to the account it was expressed for. When another
    // account is signed in now (the tab switched users meanwhile), it is
    // dropped entirely: that account is not signed out, nothing is armed.
    // With NOBODY signed in it still runs (push unregister, Firebase and
    // Google sign-out, as before the vault): e.g. the account-deletion
    // screen's request after Firebase already emitted the null user. Nothing
    // is armed then (`uid == null`).
    final uid = state.user?.uid;
    if (uid != null && event.uid != null && event.uid != uid) return;
    // An intent is armed only for a signed-in user and an arming request; a
    // non-arming one ([AuthSignOutRequested.arm] false) signs out without
    // making the end explicit. An intent already armed is never cleared
    // here (only replaced by a new armed one).
    final armed = uid != null && event.arm;
    final intent = armed ? (uid: uid, reason: event.reason) : null;
    if (intent != null) _intent = intent;
    final before = _beforeSignOut;
    final explicit = _beforeExplicitSignOut;
    final steps = <Future<void>>[
      if (before != null) _guarded(before),
      if (explicit != null && intent != null)
        _guarded(() => explicit(intent.uid)),
    ];
    if (steps.isNotEmpty) {
      try {
        await Future.wait(steps).timeout(kBeforeSignOutTimeout);
      } catch (_) {
        // Never block sign-out on bookkeeping.
      }
    }
    try {
      await _authRepository.signOut();
    } catch (_) {
      // Disarm only when the user is still signed in: a partial failure
      // (Firebase signed out, the Google sign-out failed) is still the
      // explicit end, and its null user must read so.
      if (intent != null &&
          _intent == intent &&
          _authRepository.currentUser?.uid == intent.uid) {
        _intent = null;
        _onSignOutFailed?.call(intent.uid);
      }
      rethrow;
    }
  }

  static Future<void> _guarded(Future<void> Function() step) async {
    try {
      await step();
    } catch (_) {
      // Best effort: one failing step never cancels the other.
    }
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
    _unknownTimer?.cancel();
    _userSubscription?.cancel();
    return super.close();
  }
}
