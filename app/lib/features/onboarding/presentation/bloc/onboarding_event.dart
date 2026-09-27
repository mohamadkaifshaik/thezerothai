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

final class OnboardingProfileSubmitted extends OnboardingEvent {
  const OnboardingProfileSubmitted();
}
