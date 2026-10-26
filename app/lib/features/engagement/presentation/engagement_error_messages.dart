import '../../../core/network/app_exception.dart';
import '../../../core/widgets/app_error_view.dart';
import '../domain/bookmarks_feature_flag.dart';
import 'bloc/engagement_state.dart';

/// Friendly, typed messages for a failed like / unlike / repost / undo
/// repost / bookmark / remove bookmark, shown in a snackbar (never the raw
/// server text). Callers must never auto-retry after [DegradedModeException].
/// The server answers NOT_FOUND with one text for missing, deleted, hidden and
/// blocked posts, so the wording never says which.
String engagementErrorMessage(
  AppException error, {
  EngagementAction action = EngagementAction.like,
}) {
  final reposting =
      action == EngagementAction.repost ||
      action == EngagementAction.undoRepost;
  final bookmarking =
      action == EngagementAction.bookmark ||
      action == EngagementAction.unbookmark;
  return switch (error) {
    // Bookmarks: the 1,000-post cap (`limit=bookmarks`, ADR-0023 D4) and the
    // daily quota (`quota=bookmarks`).
    LimitReachedException(quota: kBookmarksLimitName) =>
      'You can save up to 1,000 posts.',
    QuotaExceededException(quota: kBookmarksLimitName) =>
      "You've reached today's limit for saving posts. It resets tomorrow.",
    // Likes and reposts have separate daily quotas (`likes` / `posts`).
    QuotaExceededException(quota: 'posts') =>
      "You've reached today's limit for posting, so you can't repost more. "
          'It resets tomorrow.',
    QuotaExceededException() =>
      "You've reached today's limit for ${bookmarking
              ? 'saving posts'
              : reposting
              ? 'reposts'
              : 'likes'}. "
          'It resets tomorrow.',
    final RateLimitedException e => rateLimitedMessage(e),
    EmailNotVerifiedException() =>
      'Please verify your email address to continue.',
    DegradedModeException() =>
      'Dzeroth is in a limited mode right now, so this is paused. '
          'Please try again shortly.',
    FeatureDisabledException(feature: kFeatureBookmarks) =>
      "Bookmarks aren't available yet.",
    FeatureDisabledException() =>
      bookmarking
          ? "Bookmarks aren't available yet."
          : "Likes and reposts aren't available yet.",
    NotFoundException() => "This post isn't available any more.",
    NetworkException() => 'No connection. Check your network and try again.',
    _ =>
      bookmarking
          ? "Couldn't update your bookmark. Please try again."
          : reposting
          ? "Couldn't update your repost. Please try again."
          : "Couldn't update your like. Please try again.",
  };
}
