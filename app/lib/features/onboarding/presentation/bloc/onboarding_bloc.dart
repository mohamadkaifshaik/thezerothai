import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:stream_transform/stream_transform.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../data/identity_repository.dart';
import 'onboarding_event.dart';
import 'onboarding_state.dart';

/// Mirrors `handleRe` in `backend/internal/identity/validate.go`
/// (`^[A-Za-z0-9_]{3,15}$`); the client lowercases before validating, so the
/// charset only needs to cover lowercase here. The server is always the
/// source of truth (`CheckHandleAvailability`/`CreateProfile` validate
/// again) — this is just fast client-side feedback.
final _handlePattern = RegExp(r'^[a-z0-9_]{3,15}$');

/// Mirrors `reservedHandles` in `backend/internal/identity/validate.go`, kept
/// in sync manually (small, rarely-changed list) so the common case of a
/// reserved handle gets an instant message instead of a round trip.
const _reservedHandles = {
  'admin',
  'administrator',
  'api',
  'www',
  'root',
  'dzeroth',
  'support',
  'help',
  'about',
  'settings',
  'null',
  'undefined',
  'moderator',
  'official',
};

const _handleFormatMessage =
    '3-15 characters: lowercase letters, numbers, underscore.';
const _handleReservedMessage = 'That handle is reserved.';
const _handleTakenMessage = 'That handle is taken.';

/// Maps the machine-readable `reason` from `CheckHandleAvailabilityResponse`
/// (see `identity.proto`: "invalid_format", "reserved", or "" when merely
/// taken) to user-facing text — never show the raw code in the UI.
String _handleUnavailableMessage(String reason) {
  return switch (reason) {
    'invalid_format' => _handleFormatMessage,
    'reserved' => _handleReservedMessage,
    _ => _handleTakenMessage,
  };
}

EventTransformer<E> _debounceRestartable<E>(Duration duration) {
  return (events, mapper) => events.debounce(duration).switchMap(mapper);
}

class OnboardingBloc extends Bloc<OnboardingEvent, OnboardingState> {
  OnboardingBloc({required IdentityRepository identityRepository, Uuid? uuid})
    : _identityRepository = identityRepository,
      _uuid = uuid ?? const Uuid(),
      super(const OnboardingState()) {
    on<OnboardingUserAuthenticated>(_onUserAuthenticated);
    on<OnboardingUserSignedOut>((event, emit) => emit(const OnboardingState()));
    on<OnboardingRefreshRequested>(_onUserRefreshRequested);
    on<OnboardingHandleChanged>(
      _onHandleChanged,
      transformer: _debounceRestartable(const Duration(milliseconds: 300)),
    );
    on<OnboardingDisplayNameChanged>((event, emit) {
      emit(state.copyWith(displayName: event.displayName));
    });
    on<OnboardingProfileSubmitted>(_onProfileSubmitted);
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

  Future<void> _onUserAuthenticated(
    OnboardingUserAuthenticated event,
    Emitter<OnboardingState> emit,
  ) async {
    _uid = event.user.uid;
    await _loadMe(emit);
  }

  Future<void> _onUserRefreshRequested(
    OnboardingRefreshRequested event,
    Emitter<OnboardingState> emit,
  ) async {
    await _loadMe(emit);
  }

  /// Cache-first: render the locally cached profile instantly (if any) while
  /// `GetMe` refreshes it in the background — the client is our cheapest
  /// cache (CLAUDE.md prime directive), so a warm start never blocks on the
  /// network.
  Future<void> _loadMe(Emitter<OnboardingState> emit) async {
    final uid = _uid;
    final cached = uid == null
        ? null
        : await _identityRepository.cachedOwnProfile(uid);
    if (cached != null) {
      emit(
        state.copyWith(
          status: OnboardingStatus.ready,
          profile: _identityRepository.profileFromCache(cached),
        ),
      );
    } else {
      emit(state.copyWith(status: OnboardingStatus.loading, error: null));
    }

    try {
      final response = await _identityRepository.getMe();
      emit(
        state.copyWith(
          status: OnboardingStatus.ready,
          profile: response.profile,
          enabledFeatures: response.enabledFeatures.toSet(),
        ),
      );
    } on ProfileRequiredException {
      emit(state.copyWith(status: OnboardingStatus.profileRequired));
    } on EmailNotVerifiedException catch (e) {
      // Provider/verification gate (ADR-0010 D5 A2/A10) answered on an exempt
      // RPC: same verify-your-email state as CreateProfile.
      emit(
        state.copyWith(
          status: OnboardingStatus.emailVerificationRequired,
          error: e,
        ),
      );
    } on AppException catch (e) {
      // A cached profile is still good enough to use; only surface the
      // error (and block on it) when we had nothing to show.
      if (cached == null) {
        emit(state.copyWith(status: OnboardingStatus.error, error: e));
      }
    }
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
        ),
      );
      return;
    }
    if (!_handlePattern.hasMatch(handle)) {
      emit(
        state.copyWith(
          handle: handle,
          handleCheckStatus: HandleCheckStatus.unavailable,
          handleCheckMessage: _handleFormatMessage,
        ),
      );
      return;
    }
    if (_reservedHandles.contains(handle)) {
      emit(
        state.copyWith(
          handle: handle,
          handleCheckStatus: HandleCheckStatus.unavailable,
          handleCheckMessage: _handleReservedMessage,
        ),
      );
      return;
    }
    emit(
      state.copyWith(
        handle: handle,
        handleCheckStatus: HandleCheckStatus.checking,
        handleCheckMessage: '',
      ),
    );
    try {
      final response = await _identityRepository.checkHandleAvailability(
        handle,
      );
      if (state.handle != handle) return; // superseded by a newer keystroke
      emit(
        state.copyWith(
          handleCheckStatus: response.available
              ? HandleCheckStatus.available
              : HandleCheckStatus.unavailable,
          handleCheckMessage: response.available
              ? ''
              : _handleUnavailableMessage(response.reason),
        ),
      );
    } on EmailNotVerifiedException catch (e) {
      // Not "handle unavailable": the account itself must verify first
      // (A2/A10 gate). CreateProfileScreen renders VerifyEmailView.
      if (state.handle != handle) return;
      emit(
        state.copyWith(
          handleCheckStatus: HandleCheckStatus.idle,
          handleCheckMessage: '',
          status: OnboardingStatus.emailVerificationRequired,
          error: e,
        ),
      );
    } on RateLimitedException {
      // N1: a rate-limited probe says nothing about the handle. Treat it as
      // unknown and let the user submit; CreateProfile validates again.
      if (state.handle != handle) return;
      emit(
        state.copyWith(
          handleCheckStatus: HandleCheckStatus.unknown,
          handleCheckMessage:
              "Couldn't check this handle right now. We'll confirm it when "
              'you continue.',
        ),
      );
    } on AppException catch (e) {
      if (state.handle != handle) return;
      emit(
        state.copyWith(
          handleCheckStatus: HandleCheckStatus.unavailable,
          handleCheckMessage: e.message,
        ),
      );
    }
  }

  Future<void> _onProfileSubmitted(
    OnboardingProfileSubmitted event,
    Emitter<OnboardingState> emit,
  ) async {
    if (!state.canSubmit) return;
    // Stable per attempt so a retried request after a dropped response is
    // deduplicated server-side instead of creating a second profile
    // (CLAUDE.md rule 4).
    _idempotencyKey ??= _uuid.v4();
    emit(state.copyWith(isSubmitting: true, error: null));
    try {
      final profile = await _identityRepository.createProfile(
        handle: state.handle,
        displayName: state.displayName.trim(),
        idempotencyKey: _idempotencyKey!,
      );
      _idempotencyKey = null;
      emit(
        state.copyWith(
          isSubmitting: false,
          status: OnboardingStatus.ready,
          profile: profile,
        ),
      );
    } on HandleTakenException catch (e) {
      emit(
        state.copyWith(
          isSubmitting: false,
          handleCheckStatus: HandleCheckStatus.unavailable,
          handleCheckMessage: e.message,
        ),
      );
    } on EmailNotVerifiedException catch (e) {
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
      emit(state.copyWith(isSubmitting: false, error: e));
    }
  }
}
