import '../../../core/network/app_exception.dart';
import '../../../core/widgets/app_error_view.dart';

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
