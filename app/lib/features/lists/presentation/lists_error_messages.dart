import '../../../core/network/app_exception.dart';
import '../../../core/widgets/app_error_view.dart';
import '../domain/lists_feature_flag.dart';

/// Friendly, typed text for a failed Lists action (W5-11; W5-12 to W5-14
/// reuse it). Never the raw server message, and one fixed text for
/// [NotFoundException] whatever the cause (private, hidden, blocked, gone).
String listsErrorMessage(AppException error) {
  return switch (error) {
    LimitReachedException(quota: kListsPerUserLimit) =>
      'You can have up to $kMaxListsPerUser Lists. Delete one to make room '
          'for a new one.',
    LimitReachedException(quota: kListMembersLimit) =>
      'This List is full. Remove someone to add another person.',
    LimitReachedException(quota: kHomeTabsLimit) =>
      'You can pin up to $kMaxPinnedHomeTabs timelines to Home. Unpin one '
          'first.',
    LimitReachedException() => "You've reached the limit for this action.",
    QuotaExceededException(quota: kListCreatesQuota) =>
      "You've created a lot of Lists today. You can create more tomorrow.",
    QuotaExceededException(quota: kListAddsQuota) =>
      "You've added a lot of people to Lists today. You can add more "
          'tomorrow.',
    QuotaExceededException() =>
      "You've hit today's limit for this action. It resets tomorrow.",
    final RateLimitedException e => rateLimitedMessage(e),
    ProtectedAccountException() =>
      "This account is protected, so it can't be added to a List.",
    FeatureDisabledException() => "Lists aren't available yet.",
    DegradedModeException() =>
      'Dzeroth is in a limited mode right now. Please try again shortly.',
    NetworkException() => 'No connection. Check your network and try again.',
    NotFoundException() => 'This List is unavailable.',
    ValidationException() => 'Check the name and description, then try again.',
    EmailNotVerifiedException() =>
      'Please verify your email address to continue.',
    _ => 'Something went wrong. Please try again.',
  };
}
