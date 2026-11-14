import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:stream_transform/stream_transform.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import '../../data/identity_repository.dart';
import '../../../media/domain/media_feature_flag.dart' show kFeatureMedia;
import '../../domain/handle_rules.dart';
import 'onboarding_event.dart';
import 'onboarding_state.dart';

EventTransformer<E> _debounceRestartable<E>(Duration duration) {
  return (events, mapper) => events.debounce(duration).switchMap(mapper);
}

class OnboardingBloc extends Bloc<OnboardingEvent, OnboardingState> {
  OnboardingBloc({required IdentityRepository identityRepository, Uuid? uuid})
    : _identityRepository = identityRepository,
      _uuid = uuid ?? const Uuid(),
      super(const OnboardingState()) {
    on<OnboardingUserAuthenticated>(_onUserAuthenticated);
    on<OnboardingUserSignedOut>((event, emit) {
      // Ends the in-flight GetMe of the signed-out user (see _loadMe).
      _uid = null;
      _idempotencyKey = null;
      _flagsLoaded = false;
      _profileCreated = false;
      emit(const OnboardingState());
    });
    on<OnboardingRefreshRequested>(_onUserRefreshRequested);
    on<OnboardingHandleChanged>(
      _onHandleChanged,
      transformer: _debounceRestartable(kHandleCheckDebounce),
    );
    on<OnboardingDisplayNameChanged>((event, emit) {
      emit(state.copyWith(displayName: event.displayName));
    });
    on<OnboardingProfileSubmitted>(_onProfileSubmitted);
    on<OnboardingPhotoStepFinished>((event, emit) {
      if (state.photoStepPending) emit(state.copyWith(photoStepPending: false));
    });
    // Edit profile / change handle: the server's updated profile replaces
    // the one in state so every screen that reads it sees the new name.
    on<OnboardingProfileUpdated>((event, emit) {
      if (event.profile.userId != state.profile?.userId) return;
      emit(state.copyWith(profile: event.profile));
    });
    // A follow request was answered: lower the drawer badge now; the
    // next GetMe (cached 30 s on the server) reconciles it.
    on<OnboardingFollowRequestAnswered>((event, emit) {
      final next = state.pendingFollowRequestCount - 1;
      emit(state.copyWith(pendingFollowRequestCount: next < 0 ? 0 : next));
    });
    on<OnboardingEmailVerificationDismissed>((event, emit) {
      emit(
        state.copyWith(status: OnboardingStatus.profileRequired, error: null),
      );
    });
  }

  final IdentityRepository _identityRepository;
  final Uuid _uuid;
  String? _idempotencyKey;
  String? _uid;

  /// Whether a `GetMe` answered for [_uid] this session, so
  /// `state.enabledFeatures` is the server's flag set rather than the empty
  /// default. The local cache holds the profile only, never the flags.
  bool _flagsLoaded = false;

  /// Whether this session's CreateProfile succeeded for [_uid]. Until a GetMe
  /// confirms it, a PROFILE_REQUIRED (a server instance whose negative
  /// profile cache has not seen the create yet) is a retryable error, never
  /// the form again: a second submit would only collide with the handle the
  /// create already took.
  bool _profileCreated = false;

  Future<void> _onUserAuthenticated(
    OnboardingUserAuthenticated event,
    Emitter<OnboardingState> emit,
  ) async {
    if (_uid != event.user.uid) {
      _flagsLoaded = false;
      _profileCreated = false;
    }
    _uid = event.user.uid;
    await _loadMe(emit);
  }

  Future<void> _onUserRefreshRequested(
    OnboardingRefreshRequested event,
    Emitter<OnboardingState> emit,
  ) async {
    // Signed out (e.g. a FEATURE_DISABLED answer arriving after sign-out): no
    // session-less GetMe and nothing emitted into the signed-out state.
    if (_uid == null) return;
    await _loadMe(emit);
  }

  /// Cache-first: render the locally cached profile instantly (if any) while
  /// `GetMe` refreshes it in the background — the client is our cheapest
  /// cache (the cost-first directive), so a warm start never blocks on the
  /// network.
  Future<void> _loadMe(Emitter<OnboardingState> emit) async {
    final uid = _uid;
    final cached = uid == null
        ? null
        : await _identityRepository.cachedOwnProfile(uid);
    // Handlers run concurrently: a sign-out (or another user's sign-in) while
    // an await below was pending must not be overwritten by this user's data.
    bool stale() => emit.isDone || _uid != uid;
    if (stale()) return;
    // Without a cached profile, or right after this session's CreateProfile
    // before any GetMe answered, a failed GetMe has nothing usable to show:
    // the full-screen error (the router's /session-error). Otherwise a
    // failure keeps the cached profile ready behind a non-blocking banner.
    final blocking = cached == null || (_profileCreated && !_flagsLoaded);
    // A Retry from that error state must not render the cached profile as
    // ready first (the router would open Home with every flag off): it shows
    // loading, the error page's spinner, until GetMe answers.
    final retryFromError =
        state.status == OnboardingStatus.error && !_flagsLoaded;
    if (cached != null && !retryFromError) {
      emit(
        state.copyWith(
          status: OnboardingStatus.ready,
          profile: _identityRepository.profileFromCache(cached),
          flagsPending: !_flagsLoaded,
        ),
      );
    } else {
      emit(state.copyWith(status: OnboardingStatus.loading, error: null));
    }

    try {
      final response = await _identityRepository.getMe();
      if (stale()) return;
      _emitMe(emit, response);
    } on AccountRestrictedException {
      if (stale()) return;
      // Suspended (or pending deletion): a cached profile must not keep the
      // app looking normal. AuthGate shows the account-restricted view.
      emit(state.copyWith(accountRestricted: true, flagsPending: false));
    } on ProfileRequiredException catch (e) {
      if (stale()) return;
      if (_profileCreated) {
        emit(state.copyWith(status: OnboardingStatus.error, error: e));
      } else {
        emit(state.copyWith(status: OnboardingStatus.profileRequired));
      }
    } on EmailNotVerifiedException catch (e) {
      if (stale()) return;
      // Provider/verification gate answered on an exempt
      // RPC: same verify-your-email state as CreateProfile.
      emit(
        state.copyWith(
          status: OnboardingStatus.emailVerificationRequired,
          error: e,
        ),
      );
    } on AppException catch (e) {
      if (stale()) return;
      if (blocking) {
        emit(state.copyWith(status: OnboardingStatus.error, error: e));
      } else {
        // A cached profile keeps the app usable (offline warm start): stay
        // ready with whatever flags this session loaded and let the shell
        // offer Retry.
        emit(
          state.copyWith(
            status: OnboardingStatus.ready,
            refreshFailed: true,
            flagsPending: false,
          ),
        );
      }
    }
  }

  /// A successful `GetMe`: the profile and the server's flag set, in one emit.
  void _emitMe(
    Emitter<OnboardingState> emit,
    identity.GetMeResponse response, {
    bool? isSubmitting,
  }) {
    // The first GetMe after this session's CreateProfile (the create flow or
    // the Retry after it): the optional photo step, when media is on.
    final afterCreate = _profileCreated && !_flagsLoaded;
    _flagsLoaded = true;
    emit(
      state.copyWith(
        status: OnboardingStatus.ready,
        photoStepPending:
            state.photoStepPending ||
            (afterCreate && response.enabledFeatures.contains(kFeatureMedia)),
        profile: response.profile,
        enabledFeatures: response.enabledFeatures.toSet(),
        unreadNotificationCount: response.unreadNotificationCount.toInt(),
        unreadConversationCount: response.unreadConversationCount.toInt(),
        pendingFollowRequestCount: response.pendingFollowRequestCount.toInt(),
        accountRestricted: false,
        refreshFailed: false,
        flagsPending: false,
        isSubmitting: isSubmitting ?? state.isSubmitting,
        error: null,
      ),
    );
  }

  Future<void> _onHandleChanged(
    OnboardingHandleChanged event,
    Emitter<OnboardingState> emit,
  ) async {
    final handle = event.handle.trim().toLowerCase();
    if (handle.isEmpty) {
      emit(
        state.copyWith(
          handle: handle,
          handleCheckStatus: HandleCheckStatus.idle,
          handleCheckMessage: '',
          handleSuggestions: const [],
        ),
      );
      return;
    }
    final issue = localHandleIssue(handle);
    if (issue != null) {
      emit(
        state.copyWith(
          handle: handle,
          handleCheckStatus: HandleCheckStatus.unavailable,
          handleCheckMessage: issue,
          handleSuggestions: const [],
        ),
      );
      return;
    }
    final uid = _uid;
    bool stale() => emit.isDone || _uid != uid;
    emit(
      state.copyWith(
        handle: handle,
        handleCheckStatus: HandleCheckStatus.checking,
        handleCheckMessage: '',
        handleSuggestions: const [],
      ),
    );
    try {
      final response = await _identityRepository.checkHandleAvailability(
        handle,
      );
      if (stale() || state.handle != handle) return; // or a newer keystroke
      final check = handleCheckFromAnswer(response);
      emit(
        state.copyWith(
          handleCheckStatus: check.status,
          handleCheckMessage: check.message,
        ),
      );
      if (isHandleTakenAnswer(response)) await _suggest(handle, emit, stale);
    } on EmailNotVerifiedException catch (e) {
      // Not "handle unavailable": the account itself must verify first
      // (A2/A10 gate). CreateProfileScreen renders VerifyEmailView.
      if (stale() || state.handle != handle) return;
      emit(
        state.copyWith(
          handleCheckStatus: HandleCheckStatus.idle,
          handleCheckMessage: '',
          status: OnboardingStatus.emailVerificationRequired,
          error: e,
        ),
      );
    } on AppException catch (e) {
      // N1: a rate-limited (or otherwise failed) probe says nothing about the
      // handle. `unknown` keeps submit enabled; CreateProfile validates again.
      if (stale() || state.handle != handle) return;
      final check = handleCheckFromError(e, saveVerb: 'continue');
      emit(
        state.copyWith(
          handleCheckStatus: check.status,
          handleCheckMessage: check.message,
        ),
      );
    }
  }

  /// Free handles near the taken [handle] (a SuggestHandles call, only after
  /// a TAKEN answer, never for a format or reserved one). The repository
  /// answers nothing while the server has the feature off.
  Future<void> _suggest(
    String handle,
    Emitter<OnboardingState> emit,
    bool Function() stale,
  ) async {
    final handles = await _identityRepository.suggestHandles(handle);
    if (stale() || state.handle != handle || handles.isEmpty) return;
    emit(state.copyWith(handleSuggestions: handles));
  }

  Future<void> _onProfileSubmitted(
    OnboardingProfileSubmitted event,
    Emitter<OnboardingState> emit,
  ) async {
    if (!state.canSubmit) return;
    // Stable per attempt so a retried request after a dropped response is
    // deduplicated server-side instead of creating a second profile
    // (the idempotency rule).
    _idempotencyKey ??= _uuid.v4();
    final uid = _uid;
    bool stale() => emit.isDone || _uid != uid;
    emit(state.copyWith(isSubmitting: true, error: null));
    try {
      final profile = await _identityRepository.createProfile(
        handle: state.handle,
        displayName: state.displayName.trim(),
        idempotencyKey: _idempotencyKey!,
      );
      if (stale()) return;
      _idempotencyKey = null;
      _profileCreated = true;
      await _loadMeAfterCreate(emit, profile, stale);
    } on HandleTakenException catch (e) {
      if (stale()) return;
      emit(
        state.copyWith(
          isSubmitting: false,
          handleCheckStatus: HandleCheckStatus.unavailable,
          handleCheckMessage: e.message,
        ),
      );
      await _suggest(state.handle, emit, stale);
    } on EmailNotVerifiedException catch (e) {
      if (stale()) return;
      // The client gated the form on AuthBloc's cached Firebase user, but the
      // ID token the server checked was stale (e.g. the force-refresh after
      // "I've verified" failed — see AuthBloc._onVerificationCheckRequested).
      // Send the user back through verification instead of a bare error
      // snackbar: CreateProfileScreen renders VerifyEmailView in place for
      // this status, and its "I've verified" button forces a fresh token.
      emit(
        state.copyWith(
          isSubmitting: false,
          status: OnboardingStatus.emailVerificationRequired,
          error: e,
        ),
      );
    } on AppException catch (e) {
      if (stale()) return;
      emit(state.copyWith(isSubmitting: false, error: e));
    }
  }

  /// The profile exists now; `GetMe` brings the caller's flags. Until it
  /// answers the form stays submitting, so the app never opens with an
  /// empty flag set ("coming soon" everywhere). A failure is the recoverable
  /// error state (Retry runs `GetMe` again), never the form: the create is
  /// done and a second one would only replay it.
  Future<void> _loadMeAfterCreate(
    Emitter<OnboardingState> emit,
    identity.Profile created,
    bool Function() stale,
  ) async {
    try {
      final response = await _identityRepository.getMe();
      if (stale()) return;
      _emitMe(emit, response, isSubmitting: false);
    } on AccountRestrictedException {
      if (stale()) return;
      emit(
        state.copyWith(
          isSubmitting: false,
          profile: created,
          accountRestricted: true,
        ),
      );
    } on AppException catch (e) {
      if (stale()) return;
      // Includes a PROFILE_REQUIRED from a server instance whose negative
      // profile cache has not seen the create yet: retry, not the form.
      emit(
        state.copyWith(
          isSubmitting: false,
          status: OnboardingStatus.error,
          profile: created,
          error: e,
        ),
      );
    }
  }
}
