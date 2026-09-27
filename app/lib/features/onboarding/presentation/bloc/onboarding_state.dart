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

  /// The caller has a profile. Onboarding is done.
  ready,
  error,
}

enum HandleCheckStatus { idle, checking, available, unavailable }

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
  }) = _OnboardingState;

  const OnboardingState._();

  bool get canSubmit =>
      !isSubmitting &&
      handleCheckStatus == HandleCheckStatus.available &&
      displayName.trim().isNotEmpty;
}
