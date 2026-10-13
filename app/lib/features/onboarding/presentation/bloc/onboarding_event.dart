import '../../../../gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import '../../../auth/domain/app_user.dart';

sealed class OnboardingEvent {
  const OnboardingEvent();
}

/// Dispatched (from `app/bootstrap.dart`'s `AuthBloc` listener) once the user
/// is fully signed in (verified, or a non-password provider). Triggers
/// `GetMe`.
final class OnboardingUserAuthenticated extends OnboardingEvent {
  const OnboardingUserAuthenticated(this.user);
  final AppUser user;
}

/// Dispatched on sign-out so a new user never sees the previous one's state.
final class OnboardingUserSignedOut extends OnboardingEvent {
  const OnboardingUserSignedOut();
}

/// Retry after a transient error loading `GetMe`.
final class OnboardingRefreshRequested extends OnboardingEvent {
  const OnboardingRefreshRequested();
}

final class OnboardingHandleChanged extends OnboardingEvent {
  const OnboardingHandleChanged(this.handle);
  final String handle;
}

final class OnboardingDisplayNameChanged extends OnboardingEvent {
  const OnboardingDisplayNameChanged(this.displayName);
  final String displayName;
}

/// The caller's own profile was edited (UpdateProfile / ChangeHandle
/// succeeded): swap in the server's copy. Ignored for any other user id.
final class OnboardingProfileUpdated extends OnboardingEvent {
  const OnboardingProfileUpdated(this.profile);
  final identity.Profile profile;
}

final class OnboardingProfileSubmitted extends OnboardingEvent {
  const OnboardingProfileSubmitted();
}

/// Dispatched when the user taps back on the email-verification prompt shown
/// after `CreateProfile` returns `ERROR_REASON_EMAIL_NOT_VERIFIED` (see
/// `OnboardingStatus.emailVerificationRequired`). Returns to the
/// create-profile form — the handle and display name the user already typed
/// are kept — so they can retry once their email is verified.
final class OnboardingEmailVerificationDismissed extends OnboardingEvent {
  const OnboardingEmailVerificationDismissed();
}
