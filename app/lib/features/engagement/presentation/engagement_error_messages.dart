import '../../../core/network/app_exception.dart';
import '../../../core/widgets/app_error_view.dart';
import '../domain/bookmarks_feature_flag.dart';
import '../domain/poll_display.dart';
import 'bloc/engagement_state.dart';
import 'bloc/poll_state.dart';

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
    ProtectedAccountException() => ProtectedAccountException.userMessage,
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

/// Why the vote buttons are off when the viewer blocks the author (TARGET_BLOCKED
/// and `viewer_poll_vote_blocked`, ADR-0029 Amendment 1 A1.5).
const kPollBlockedReason = "You blocked this account. Unblock to vote.";

/// Friendly, typed messages for a failed vote or a failed "See final results"
/// read (W6-13, ADR-0029). Fixed text, never the server's; ALREADY_VOTED and
/// POLL_CLOSED are normally resolved by a refresh and only reach here as a
/// snackbar when that refresh failed too.
String pollErrorMessage(
  AppException error, {
  PollAction action = PollAction.vote,
}) {
  return switch (error) {
    FeatureDisabledException() => "Voting isn't available right now.",
    PollClosedException() => PollClosedException.userMessage,
    AlreadyVotedException() when action == PollAction.change =>
      "Your vote didn't change. Showing your current choice.",
    AlreadyVotedException() => AlreadyVotedException.userMessage,
    LimitReachedException(quota: kPollVoteChangesLimit) =>
      "You've changed your vote the most times allowed.",
    TargetBlockedException() => kPollBlockedReason,
    final RateLimitedException e => rateLimitedMessage(e),
    QuotaExceededException() =>
      "You've reached today's limit for votes. It resets tomorrow.",
    DegradedModeException() =>
      'Dzeroth is in a limited mode right now, so voting is paused. '
          'Please try again shortly.',
    NotFoundException() => "This post isn't available any more.",
    NetworkException() => 'No connection. Check your network and try again.',
    _ => switch (action) {
      PollAction.refresh => "Couldn't load the results. Please try again.",
      PollAction.change => "Couldn't change your vote. Please try again.",
      PollAction.vote => "Couldn't register your vote. Please try again.",
    },
  };
}

/// "Bookmarks aren't available right now": ListBookmarks was refused with
/// FEATURE_DISABLED, i.e. bookmarks are switched off for everyone. A state of
/// its own on the Bookmarks screen, not an error with Retry.
const kBookmarksUnavailableTitle = "Bookmarks aren't available right now";

/// The banner over a History list ([noun]: "bookmarks" or "likes") when a
/// refresh or page failed and the rows already loaded stay.
String listNoticeMessage(AppException error, {required String noun}) {
  return switch (error) {
    final RateLimitedException e => rateLimitedMessage(e),
    NetworkException() => "You're offline. Showing the $noun already loaded.",
    DegradedModeException() =>
      'Dzeroth is in a limited mode right now. Please try again shortly.',
    _ => "Couldn't refresh your $noun.",
  };
}

/// The banner over the Bookmarks list (see [listNoticeMessage]).
String bookmarksListNoticeMessage(AppException error) =>
    listNoticeMessage(error, noun: 'bookmarks');
