import '../../../core/network/app_exception.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../communities/domain/communities_feature_flag.dart';
import '../../communities/presentation/communities_error_messages.dart';

/// Friendly text for a failed ReportContent (shown inline in the report
/// sheet; never the raw server message). NOT_FOUND has ONE wording for a
/// missing, hidden, blocked or suspended target (no oracle), and
/// reporting yourself is a validation error with its own text.
///
/// [notFoundMessage] lets a target name itself in the one NOT_FOUND text (the
/// Community report). A FEATURE_DISABLED for `feature=communities`
/// (the COMMUNITY target needs both flags) reads as the Communities text.
String reportErrorMessage(AppException error, {String? notFoundMessage}) {
  return switch (error) {
    NotFoundException() =>
      notFoundMessage ?? "This isn't available to report any more.",
    FeatureDisabledException(feature: kFeatureCommunities) =>
      communitiesErrorMessage(error),
    QuotaExceededException() || LimitReachedException() =>
      "You've reached today's limit for reports. It resets tomorrow.",
    final RateLimitedException e => rateLimitedMessage(e),
    ValidationException(:final field) => switch (field) {
      'note' =>
        "Your details can't be sent. Shorten them or remove unusual "
            'characters.',
      'reason' => 'Choose a reason for your report.',
      'target_id' => "You can't report your own content.",
      _ => "Couldn't send your report. Please try again.",
    },
    EmailNotVerifiedException() =>
      'Please verify your email address to send a report.',
    FeatureDisabledException() => "Reporting isn't available right now.",
    DegradedModeException() =>
      'dZeroth is in a limited mode right now. Please try again shortly.',
    NetworkException() =>
      'No connection. Your report was not sent; check your network and try '
          'again.',
    AccountRestrictedException() => "This account can't send reports.",
    _ => "Couldn't send your report. Please try again.",
  };
}
