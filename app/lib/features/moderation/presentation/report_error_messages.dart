import '../../../core/network/app_exception.dart';
import '../../../core/widgets/app_error_view.dart';

/// Friendly text for a failed ReportContent (shown inline in the report
/// sheet; never the raw server message). NOT_FOUND has ONE wording for a
/// missing, hidden, blocked or suspended target (ADR-0016: no oracle), and
/// reporting yourself is a validation error with its own text.
String reportErrorMessage(AppException error) {
  return switch (error) {
    NotFoundException() => "This isn't available to report any more.",
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
