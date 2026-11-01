import '../../../core/network/app_exception.dart';
import '../../../core/widgets/app_error_view.dart';
import '../domain/communities_feature_flag.dart';

/// Friendly, typed text for a failed Communities action (W5-30; W5-31 to
/// W5-35 reuse it). Never the raw server message, and one fixed text for
/// [NotFoundException] whatever the cause (missing, suspended, hidden). An
/// error this build does not know reads as the generic last line, never as
/// "restricted" or as a missing profile.
///
/// [CommunityForbiddenException] `notMember` is "Only members of this
/// community can do that."; a reply surface that knows the community's name
/// shows its own "Only members of the community can reply" (with its name) instead.
String communitiesErrorMessage(AppException error) {
  return switch (error) {
    final CommunityForbiddenException e => e.reason.userMessage,
    final CommunityStateException e => e.reason.userMessage,
    LimitReachedException(quota: kCommunitiesOwnedLimit) =>
      'You can own up to $kMaxCommunitiesOwned communities.',
    LimitReachedException(quota: kCommunitiesJoinedLimit) =>
      'You can join up to $kMaxCommunitiesJoined communities. Leave one '
          'to join another.',
    LimitReachedException(quota: kCommunityModeratorsLimit) =>
      'This community has the most moderators it can have '
          '($kMaxCommunityModerators). Remove one first.',
    LimitReachedException() => "You've reached the limit for this action.",
    QuotaExceededException(quota: kCommunityJoinsQuota) =>
      "You've joined a lot of communities today. You can join more "
          'tomorrow.',
    QuotaExceededException(quota: kCommunityPostsQuota) =>
      "You've posted a lot in communities today. You can post more "
          'tomorrow.',
    QuotaExceededException() =>
      "You've hit today's limit for this action. It resets tomorrow.",
    final RateLimitedException e => rateLimitedMessage(e),
    ProtectedAccountException() =>
      "Protected accounts can't post in communities.",
    FeatureDisabledException() => "Communities aren't available yet.",
    DegradedModeException() =>
      'Dzeroth is in a limited mode right now. Please try again shortly.',
    NetworkException() => 'No connection. Check your network and try again.',
    NotFoundException() => 'This community is unavailable.',
    ValidationException() =>
      'Check the name, description and rules, then try again.',
    EmailNotVerifiedException() =>
      'Please verify your email address to continue.',
    _ => 'Something went wrong. Please try again.',
  };
}
