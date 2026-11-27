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
    on<AuthSessionEndedByServer>(_onSessionEndedByServer);
    on<AuthSignedOutAfterOwnRemoval>(_onSignedOutAfterOwnRemoval);
    on<AuthFailureDismissed>((event, emit) {
      emit(state.copyWith(failure: null));
    });
    // The network layer reports a session the server ended (SESSION_ENDED,
    // and again after one forced refresh) through the repository: the one
    // place both already share, so bootstrap needs no new wiring.
    authRepository.onServerEndedSession = _sessionEndedHook;
    // The same seam for this device's own removal that signed every session
    // out (the Settings removal and the removal queue report it).
    authRepository.onRemovalSignedOutAll = _ownRemovalHook;
    // Fix round 2, F1: the Settings check runs here, so the reason is
    // recorded before its probe.
    authRepository.onCheckOwnRemoval = checkOwnRemoval;
  }

  void _sessionEndedHook(String uid) {
    if (!isClosed) add(AuthSessionEndedByServer(uid));
  }

  void _ownRemovalHook(String uid, SignInProbe? probed) {
    if (!isClosed) add(AuthSignedOutAfterOwnRemoval(uid, probed: probed));
  }

  /// The remover's reason: [uid]'s session is ending because this device's
  /// own removal ended every session. Consumed by the end of that session
  /// (the remover's notice); disarmed by an alive probe or a failed
  /// sign-out. Fix round 2, F1: armed BEFORE any probe.
  String? _endingForOwnRemoval;

  /// The uid whose remover sign-out is running (probe included): dedupes a
  /// burst of reports. Cleared by the end of that session, an alive probe
  /// or a failed sign-out.
  String? _signingOutForOwnRemoval;

  Future<SignInProbe> _probe() async {
    try {
      return await _authRepository.probeSignIn();
    } catch (_) {
      return SignInProbe.unknown;
    }
  }

  /// Fix round 2, F1 (re-review M1, m2): the Settings check after a removal
  /// answered `other_sessions_ended` true (`AuthRepository.checkOwnRemoval`).
  /// 1. The remover's reason is armed for [uid] first, so a sign-out during
  ///    the probe (the SDK signing out on its own) lands with the remover's
  ///    notice.
  /// 2. One probe ([AuthRepository.probeSignIn], never signs out).
  /// 3. [SignInProbe.alive]: the reason is disarmed (when this call armed
  ///    it and no sign-out runs for it).
  /// 4. Dead or unknown: the reason stays armed; the caller shows its result
  ///    and reports with this answer, and the bloc then signs out at once.
  /// [uid] not signed in (or a cut sign-out running for it): unknown, with
  /// nothing armed.
  Future<SignInProbe> checkOwnRemoval(String uid) async {
    if (isClosed || state.user?.uid != uid || _endingForCut == uid) {
      return SignInProbe.unknown;
    }
    final armedHere = _endingForOwnRemoval != uid;
    _endingForOwnRemoval = uid;
    final probe = await _probe();
    if (probe == SignInProbe.alive &&
        armedHere &&
        _endingForOwnRemoval == uid &&
        _signingOutForOwnRemoval != uid) {
      _endingForOwnRemoval = null;
    }
    return probe;
  }

  /// Fix round 2, F1 backstop (mirrors [_upgradeEndedToCut]): a remover
  /// report for [uid] that lands after the user is already null upgrades
  /// that uid's lost session to the remover's notice, when nobody signed in
  /// since and neither notice is set. The vault needs nothing more (the
  /// same [SessionEnd.sessionLost]).
  void _upgradeEndedToOwnRemoval(String uid, Emitter<AuthState> emit) {
    final s = state;
    if (_lastEndedUid != uid ||
        s.status != AuthStatus.unauthenticated ||
        s.lastSessionEnd != SessionEnd.sessionLost ||
        s.signedOutAfterOwnRemoval ||
        s.signedOutByDeviceRemoval) {
      return;
    }
    emit(s.copyWith(signedOutAfterOwnRemoval: true));
  }

  /// Remover copy (controller ruling 2026-11-27, H1 option b): signs
  /// [AuthSignedOutAfterOwnRemoval.uid] out at once, without waiting for the
  /// token refresh H1 makes fail. No vault intent is armed (the end is
  /// [SessionEnd.sessionLost]: the vault is closed and kept, and the same uid
  /// signing back in reopens its keys). The push unregister runs, bounded and
  /// best effort as on a normal sign-out: unlike a SESSION_ENDED device, this
  /// one's ID token is still accepted, and a signed-out device should not
  /// keep getting pushes.
  ///
  /// Fix round 1, R2 (code M2, security M1 and L2): the server's
  /// `other_sessions_ended` means "a cut exists for this removal", not "this
  /// token was revoked" (a replay after a re-sign-in, or a sign-in in the
  /// same second as the cut, keeps a live sign-in). So, one place for the
  /// Settings and outbox paths alike:
  /// 1. the intent is armed (a null user that comes meanwhile, e.g. the SDK
  ///    signing out on its own, still reads as this end);
  /// 2. one forced refresh probes the sign-in ([AuthRepository.probeSignIn],
  ///    which never signs out);
  /// 3. alive: disarmed, nobody is signed out;
  /// 4. dead: signed out with the remover's notice;
  /// 5. unknown (offline, a timeout): signed out all the same, since the
  ///    server said the sessions ended.
  ///
  /// Fix round 2, F1: with [AuthSignedOutAfterOwnRemoval.probed] (the
  /// Settings dialog already ran [checkOwnRemoval]) there is no second
  /// probe: dead or unknown signs out at once. Only the removal queue's
  /// report (no answer) probes here. With the user already null, the
  /// backstop [_upgradeEndedToOwnRemoval] applies.
  Future<void> _onSignedOutAfterOwnRemoval(
    AuthSignedOutAfterOwnRemoval event,
    Emitter<AuthState> emit,
  ) async {
    final uid = state.user?.uid;
    if (uid == null) {
      _upgradeEndedToOwnRemoval(event.uid, emit);
      return;
    }
    if (uid != event.uid ||
        _signingOutForOwnRemoval == uid ||
        _endingForCut == uid) {
      return;
    }
    _signingOutForOwnRemoval = uid;
    _endingForOwnRemoval = uid;
    final probe = event.probed ?? await _probe();
    if (_endingForOwnRemoval != uid || state.user?.uid != uid) {
      return; // ended meanwhile (its end consumed the reason)
    }
    if (probe == SignInProbe.alive) {
      // This sign-in was not revoked: nothing to end.
      _endingForOwnRemoval = null;
      _signingOutForOwnRemoval = null;
      return;
    }
    final before = _beforeSignOut;
    if (before != null) {
      try {
        await _guarded(before).timeout(kBeforeSignOutTimeout);
      } catch (_) {
        // Never block sign-out on bookkeeping.
      }
    }
    try {
      await _authRepository.signOut();
    } catch (_) {
      // Still signed in: a later report (or the failing refresh) ends it.
      if (_authRepository.currentUser?.uid == uid) {
        if (_endingForOwnRemoval == uid) _endingForOwnRemoval = null;
        if (_signingOutForOwnRemoval == uid) _signingOutForOwnRemoval = null;
      }
      rethrow;
    }
  }

  /// The uid being signed out for SESSION_ENDED; cleared by its end (or a
  /// failed sign-out). Deduplicates a burst of reports.
  String? _endingForCut;

  /// The uid whose session ended last, while nobody has signed in since
  /// (null once a user signs in). Read by [_upgradeEndedToCut].
  String? _lastEndedUid;

  /// Fix round 1, R1: the cut report for [uid] landed after the user was
  /// already null (the auth SDK signed out on its own when the cut's revoke
  /// made the refresh fail). When that null user was [uid]'s lost session
  /// and nobody signed in since, the end is upgraded to the cut: the removed
  /// device's notice shows. The vault needs nothing more: the cut path's end
  /// is that same [SessionEnd.sessionLost] (closed and kept), already
  /// handed to the vault. An explicit end, the remover's own end, or
  /// another uid is left as it is.
  void _upgradeEndedToCut(String uid, Emitter<AuthState> emit) {
    final s = state;
    if (_lastEndedUid != uid ||
        s.status != AuthStatus.unauthenticated ||
        s.lastSessionEnd != SessionEnd.sessionLost ||
        s.signedOutAfterOwnRemoval ||
        s.signedOutByDeviceRemoval) {
      return;
    }
    emit(s.copyWith(signedOutByDeviceRemoval: true));
  }

  /// Ruling 1 (lane D PR 4): signs [AuthSessionEndedByServer.uid] out as a
  /// lost session (no intent is armed, so the vault is kept), once per
  /// burst. No push unregister: the server refuses this session's calls.
  Future<void> _onSessionEndedByServer(
    AuthSessionEndedByServer event,
    Emitter<AuthState> emit,
  ) async {
    final uid = state.user?.uid;
    if (uid == null) {
      _upgradeEndedToCut(event.uid, emit);
      return;
    }
    if (uid != event.uid ||
        _endingForCut == uid ||
        _endingForOwnRemoval == uid) {
      return;
    }
    _endingForCut = uid;
    try {
      await _authRepository.signOut();
    } catch (_) {
      // Still signed in: a later report may try again.
      if (_endingForCut == uid && _authRepository.currentUser?.uid == uid) {
        _endingForCut = null;
      }
      rethrow;
    }
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
    var byRemoval = state.signedOutByDeviceRemoval;
    var byOwnRemoval = state.signedOutAfterOwnRemoval;
    if (user?.uid != previous?.uid) {
      final intent = _intent;
      _intent = null;
      final cut = _endingForCut;
      _endingForCut = null;
      final own = _endingForOwnRemoval;
      _endingForOwnRemoval = null;
      _signingOutForOwnRemoval = null;
      if (user == null) {
        lastSessionEnd = _endOf(previous?.uid, intent, event.fromStreamError);
        _lastEndedUid = previous?.uid;
        // Ruling 2: the sign-in copy only for this cause (an explicit
        // sign-out that raced it reads as that sign-out).
        byRemoval =
            cut != null &&
            cut == previous?.uid &&
            lastSessionEnd == SessionEnd.sessionLost;
        // The remover's notice, by the same rule; the two causes never
        // both hold (each handler ignores a uid the other is ending).
        byOwnRemoval =
            !byRemoval &&
            own != null &&
            own == previous?.uid &&
            lastSessionEnd == SessionEnd.sessionLost;
      }
    } else if (event.fromStreamError) {
      lastSessionEnd = SessionEnd.sessionLost;
    }
    if (user != null) {
      byRemoval = false;
      byOwnRemoval = false;
      _lastEndedUid = null;
    }
    emit(
      state.copyWith(
        status: status,
        user: user,
        isSubmitting: false,
        lastSessionEnd: lastSessionEnd,
        signedOutByDeviceRemoval: byRemoval,
        signedOutAfterOwnRemoval: byOwnRemoval,
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
    // Tear-offs of the same method on the same bloc are equal (`==`).
    if (_authRepository.onServerEndedSession == _sessionEndedHook) {
      _authRepository.onServerEndedSession = null;
    }
    if (_authRepository.onRemovalSignedOutAll == _ownRemovalHook) {
      _authRepository.onRemovalSignedOutAll = null;
    }
    if (_authRepository.onCheckOwnRemoval == checkOwnRemoval) {
      _authRepository.onCheckOwnRemoval = null;
    }
    return super.close();
  }
}
