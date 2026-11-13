import '../../../core/network/app_exception.dart';
import '../../../core/widgets/app_error_view.dart';
import '../domain/beacons_feature_flag.dart';

/// Whether [error] is the server asking for a note: a one-tap join (empty
/// note) the organiser's follow does not cover.
bool isNoteRequired(AppException error) =>
    error is StateConflictException &&
    error.reason == kBeaconNoteRequiredReason;

/// Friendly, typed text for a failed Plans action. Never the raw server
/// message, and one fixed text for [NotFoundException] whatever the cause
/// (missing, hidden, blocked, not visible). A state conflict reads by its
/// reason; one this build does not know asks for a refresh, never for a
/// profile.
String beaconsErrorMessage(AppException error) {
  return switch (error) {
    StateConflictException(reason: 'full') => 'This plan is full.',
    StateConflictException(reason: 'ended') => 'This plan has already ended.',
    StateConflictException(reason: 'cancelled') =>
      'This plan has already been cancelled.',
    StateConflictException(reason: 'already_requested') =>
      "You've already asked to join this plan.",
    StateConflictException(reason: 'not_requested') =>
      "That request isn't open any more.",
    StateConflictException(reason: 'not_participant') =>
      "You're not in this plan any more.",
    StateConflictException(reason: 'organiser') => 'You organise this plan.',
    StateConflictException(reason: 'started') =>
      "This plan has started, so its time and cost can't change.",
    StateConflictException() =>
      "This plan's state has changed. Refresh and try again.",
    CommunityForbiddenException(reason: CommunityForbiddenReason.notMember) =>
      CommunityForbiddenReason.notMember.userMessage,
    CommunityForbiddenException() => "You can't do that with this plan.",
    LimitReachedException(quota: kBeaconsOpenLimit) =>
      'You can have up to $kMaxOpenBeacons open plans. Cancel one to create '
          'another.',
    LimitReachedException(quota: kBeaconRequestsPendingLimit) =>
      'You can have up to $kMaxPendingBeaconRequests open requests. Withdraw '
          'one to ask again.',
    LimitReachedException(quota: kBeaconParticipantsLimit) =>
      'A plan can have up to $kBeaconMaxSpots open spots.',
    LimitReachedException(quota: kBeaconEditRowsLimit) =>
      'This plan has too many requests to change its time. Cancel it and '
          'create a new one instead.',
    LimitReachedException() => "You've reached the limit for this action.",
    QuotaExceededException() =>
      "You've hit today's limit for this action. It resets tomorrow.",
    final RateLimitedException e => rateLimitedMessage(e),
    FeatureDisabledException() => "Plans aren't available yet.",
    DegradedModeException() =>
      'Dzeroth is in a limited mode right now. Please try again shortly.',
    NetworkException() => 'No connection. Check your network and try again.',
    NotFoundException() => 'This plan is unavailable.',
    ValidationException(field: 'details') =>
      'Details must be one line of plain text, up to 300 characters.',
    ValidationException(field: 'open_spots') =>
      "Open spots can't go below the people already going.",
    ValidationException(field: 'start_at') =>
      'Pick a time between 5 minutes and 30 days from now.',
    ValidationException() => 'Check the details of your plan, then try again.',
    EmailNotVerifiedException() =>
      'Please verify your email address to continue.',
    _ => 'Something went wrong. Please try again.',
  };
}
