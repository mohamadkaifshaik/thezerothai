import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/identity/v1/identity.pb.dart' as identity;

part 'onboarding_state.freezed.dart';

enum OnboardingStatus {
  /// No signed-in user yet, or we haven't asked `GetMe` yet.
  unknown,
  loading,

  /// `GetMe` returned `ERROR_REASON_PROFILE_REQUIRED` — show create-profile.
  profileRequired,

  /// `CreateProfile` returned `ERROR_REASON_EMAIL_NOT_VERIFIED` — the client
  /// thought the address was verified (it gated the form on `AuthBloc`'s
  /// cached Firebase user), but the ID token the server checked was stale.
  /// `CreateProfileScreen` shows `VerifyEmailView` in place so the user can
  /// force a fresh token, then go back and retry.
  emailVerificationRequired,

  /// The caller has a profile. Onboarding is done.
  ready,
  error,
}

/// [unknown]: the availability check was rate limited (ADR-0010 D5 A8 / N1).
/// Submit stays enabled; `CreateProfile` validates the handle again.
enum HandleCheckStatus { idle, checking, available, unavailable, unknown }

@freezed
abstract class OnboardingState with _$OnboardingState {
  const factory OnboardingState({
    @Default(OnboardingStatus.unknown) OnboardingStatus status,
    identity.Profile? profile,
    @Default('') String handle,
    @Default('') String displayName,
    @Default(HandleCheckStatus.idle) HandleCheckStatus handleCheckStatus,
    @Default('') String handleCheckMessage,
    @Default(false) bool isSubmitting,
    AppException? error,
    // Server feature flags enabled for the caller (ADR-0008 D6), e.g.
    // "graph". Populated from `GetMe.enabled_features`, which costs 0 extra
    // Firestore reads. A cached-profile render (before `GetMe` resolves)
    // keeps whatever was known from the previous fetch this session; a name
    // this set doesn't contain is treated as off.
    @Default(<String>{}) Set<String> enabledFeatures,
  }) = _OnboardingState;

  const OnboardingState._();

  bool get canSubmit =>
      !isSubmitting &&
      (handleCheckStatus == HandleCheckStatus.available ||
          handleCheckStatus == HandleCheckStatus.unknown) &&
      displayName.trim().isNotEmpty;
}
