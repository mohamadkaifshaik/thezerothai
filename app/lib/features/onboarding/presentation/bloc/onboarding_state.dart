import 'package:freezed_annotation/freezed_annotation.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import '../../domain/handle_rules.dart' show HandleCheckStatus;

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
    // Server feature flags enabled for the caller, e.g.
    // "graph". Populated from `GetMe.enabled_features`, which costs 0 extra
    // Firestore reads. A cached-profile render (before `GetMe` resolves)
    // keeps whatever was known from the previous fetch this session; a name
    // this set doesn't contain is treated as off.
    @Default(<String>{}) Set<String> enabledFeatures,
    // `GetMe.unread_notification_count` (capped server-side at 100), seeded
    // into the unread badge on every fresh GetMe; 0 extra reads.
    @Default(0) int unreadNotificationCount,
    // `GetMe.unread_conversation_count` (0 unless `messaging` is on for the caller, capped at 100 server-side),
    // seeded into
    // the Messages badge on every fresh GetMe; 0 extra reads.
    @Default(0) int unreadConversationCount,
    // `GetMe.pending_follow_request_count`: set for a protected caller
    // only, capped at 1,000 and cached 30 s server-side. Drives the drawer
    // badge; an answered request lowers it locally (no GetMe refetch).
    @Default(0) int pendingFollowRequestCount,
    // The caller's account is suspended or being deleted: every RPC but
    // DeleteAccount answers ACCOUNT_RESTRICTED, including GetMe.
    // Cleared by the next successful GetMe.
    @Default(false) bool accountRestricted,
    // The last GetMe failed while a cached profile kept the app usable: the
    // shell shows a non-blocking "couldn't refresh" banner with Retry. The
    // flags stay whatever this session loaded (none on a cold start; flags
    // are never persisted). Cleared by the next successful GetMe.
    @Default(false) bool refreshFailed,
    // A cached profile is showing (status ready) but this session's first
    // GetMe has not answered, so `enabledFeatures` is not known yet: the shell
    // keeps the splash instead of drawing the flags-off placeholder and the
    // legacy chrome. Cleared by any GetMe outcome.
    @Default(false) bool flagsPending,
  }) = _OnboardingState;

  const OnboardingState._();

  /// The caller is signed in but the server's flag set is not known yet (no
  /// answer from `GetMe`, cached or otherwise), so no flagged UI may draw.
  bool get featuresPending =>
      flagsPending ||
      status == OnboardingStatus.unknown ||
      status == OnboardingStatus.loading;

  bool get canSubmit =>
      !isSubmitting &&
      (handleCheckStatus == HandleCheckStatus.available ||
          handleCheckStatus == HandleCheckStatus.unknown) &&
      displayName.trim().isNotEmpty;
}
