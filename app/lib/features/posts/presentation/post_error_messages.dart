import '../../../core/network/app_exception.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../gen/dzeroth/posts/v1/posts.pbenum.dart'
    show ScheduledPostFailure;
import '../domain/schedule_rules.dart';

/// Friendly, typed messages for a failed CreatePost (shown in a snackbar;
/// never the raw server text). [EmailNotVerifiedException] is normally
/// handled by showing `VerifyEmailView` instead; the text is the fallback.
/// Callers must never auto-retry after [DegradedModeException].
String createPostErrorMessage(AppException error) {
  return switch (error) {
    QuotaExceededException() =>
      "You've reached today's limit for posting. It resets tomorrow.",
    final RateLimitedException e => rateLimitedMessage(e),
    EmailNotVerifiedException() => 'Please verify your email address to post.',
    DegradedModeException() =>
      'Dzeroth is in a limited mode right now, so posting is paused. '
          'Please try again shortly.',
    FeatureDisabledException(feature: 'media') =>
      "Photos can't be added to posts right now. Remove them and post "
          'again, or try later.',
    FeatureDisabledException() => "Posting isn't available right now.",
    NetworkException() =>
      'No connection. Your post was not sent; check your network and try '
          'again.',
    ValidationException() =>
      "This post can't be sent. Check the text and try again.",
    MediaNotReadyException() =>
      'One of your photos is no longer available. Remove it and try again.',
    _ => "Couldn't send your post. Please try again.",
  };
}

/// Friendly messages for a failed reply (CreatePost with `reply_to_post_id`),
/// where "reply" wording matters: the parent vanished (NOT_FOUND, one answer
/// for missing/deleted/hidden) or FEATURE_REPLIES is off. Everything else is
/// the shared [createPostErrorMessage].
String replyErrorMessage(AppException error) {
  return switch (error) {
    NotFoundException() =>
      "The post you're replying to isn't available any more.",
    ReplyNotAllowedException() => ReplyNotAllowedException.userMessage,
    FeatureDisabledException() => "Replies aren't available right now.",
    NetworkException() =>
      'No connection. Your reply was not sent; check your network and try '
          'again.',
    DegradedModeException() =>
      'Dzeroth is in a limited mode right now, so replying is paused. '
          'Please try again shortly.',
    ValidationException() =>
      "This reply can't be sent. Check the text and try again.",
    UnknownApiException() => "Couldn't send your reply. Please try again.",
    _ => createPostErrorMessage(error),
  };
}

/// Friendly messages for a failed quote (CreatePost with `quote_of_post_id`,
/// ADR-0018): the quoted post vanished or is not viewable (one NOT_FOUND for
/// every cause), or the quotes sub-feature is off. Everything else is the
/// shared [createPostErrorMessage].
String quoteErrorMessage(AppException error) {
  return switch (error) {
    NotFoundException() => "The post you're quoting isn't available any more.",
    FeatureDisabledException() => "Quotes aren't available right now.",
    NetworkException() =>
      'No connection. Your quote was not sent; check your network and try '
          'again.',
    DegradedModeException() =>
      'Dzeroth is in a limited mode right now, so quoting is paused. '
          'Please try again shortly.',
    ValidationException() =>
      "This quote can't be sent. Check the text and try again.",
    UnknownApiException() => "Couldn't send your quote. Please try again.",
    _ => createPostErrorMessage(error),
  };
}

/// Snackbar text for a failed pull-to-refresh of a thread that stays on
/// screen.
String threadRefreshErrorMessage(AppException error) {
  return switch (error) {
    final RateLimitedException e => rateLimitedMessage(e),
    NetworkException() => 'No connection. Showing the conversation as it was.',
    _ => "Couldn't refresh this conversation. Pull down to try again.",
  };
}

/// Friendly messages for a failed SchedulePost (ADR-0021 D4), shown in a
/// snackbar. The `publish_at` VALIDATION is normally handled by reopening the
/// Schedule dialog; its text is the fallback. Everything not scheduling
/// specific is the shared [createPostErrorMessage]. Callers must keep the SAME
/// idempotency key when the user tries again after a cap error (a near
/// simultaneous duplicate can look like one, review m1).
String scheduleErrorMessage(AppException error) {
  return switch (error) {
    LimitReachedException(quota: 'scheduled_pending') =>
      'You have too many scheduled posts. Cancel one first.',
    LimitReachedException(quota: 'scheduled_window') =>
      'Too many posts are scheduled around that time. Pick another time.',
    LimitReachedException() =>
      "You can't schedule more posts right now. Try again later.",
    QuotaExceededException(quota: 'schedules') =>
      "You've reached today's limit for scheduling posts. It resets "
          'tomorrow.',
    ValidationException(field: 'publish_at') => kScheduleRejectedMessage,
    FeatureDisabledException(feature: 'media') => createPostErrorMessage(error),
    FeatureDisabledException() => "Scheduling isn't available right now.",
    NetworkException() =>
      'No connection. Your post was not scheduled; check your network and '
          'try again.',
    DegradedModeException() =>
      'Dzeroth is in a limited mode right now, so scheduling is paused. '
          'Please try again shortly.',
    ValidationException() =>
      "This post can't be scheduled. Check the text and try again.",
    UnknownApiException() => "Couldn't schedule your post. Please try again.",
    _ => createPostErrorMessage(error),
  };
}

/// Why a scheduled post failed to publish, for a FAILED row of the Scheduled
/// list (ADR-0021 D4). Always a full sentence; never server text.
String scheduledFailureMessage(ScheduledPostFailure failure) {
  return switch (failure) {
    ScheduledPostFailure.SCHEDULED_POST_FAILURE_MEDIA_UNAVAILABLE =>
      'An image is no longer available.',
    ScheduledPostFailure.SCHEDULED_POST_FAILURE_QUOTA_EXCEEDED =>
      'You reached the daily post limit.',
    ScheduledPostFailure.SCHEDULED_POST_FAILURE_ACCOUNT_RESTRICTED =>
      'Your account could not post.',
    ScheduledPostFailure.SCHEDULED_POST_FAILURE_INVALID_CONTENT =>
      'The post no longer meets the rules.',
    ScheduledPostFailure.SCHEDULED_POST_FAILURE_EXPIRED =>
      'It could not be sent in time.',
    // INTERNAL, UNSUPPORTED, UNSPECIFIED and anything newer.
    _ => 'Something went wrong.',
  };
}

/// Snackbar text for a failed Cancel (or Dismiss, with [dismiss]) of a
/// scheduled post; the row has been put back.
String cancelScheduledErrorMessage(AppException error, {bool dismiss = false}) {
  final verb = dismiss ? 'dismiss' : 'cancel';
  return switch (error) {
    final RateLimitedException e => rateLimitedMessage(e),
    NetworkException() =>
      'No connection. Check your network and try $verb again.',
    DegradedModeException() =>
      'Dzeroth is in a limited mode right now. Please try again shortly.',
    _ => "Couldn't $verb that post. Please try again.",
  };
}

/// The banner over the Scheduled list when a refresh or page failed and the
/// rows already loaded stay.
String scheduledListNoticeMessage(AppException error) {
  return switch (error) {
    final RateLimitedException e => rateLimitedMessage(e),
    NetworkException() =>
      "You're offline. Showing the scheduled posts already loaded.",
    DegradedModeException() =>
      'Dzeroth is in a limited mode right now. Please try again shortly.',
    _ => "Couldn't refresh your scheduled posts.",
  };
}
