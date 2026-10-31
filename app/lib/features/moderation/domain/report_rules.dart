import '../../../gen/dzeroth/moderation/v1/moderation.pbenum.dart';

/// Longest optional note, in code points (ADR-0016: <= 500).
const kMaxReportNoteCodePoints = 500;

/// The reasons offered, in display order (UNSPECIFIED is never offered).
const kReportReasons = <ReportReason>[
  ReportReason.REPORT_REASON_SPAM,
  ReportReason.REPORT_REASON_HARASSMENT,
  ReportReason.REPORT_REASON_HATE,
  ReportReason.REPORT_REASON_VIOLENCE,
  ReportReason.REPORT_REASON_SEXUAL,
  ReportReason.REPORT_REASON_SELF_HARM,
  ReportReason.REPORT_REASON_ILLEGAL,
  ReportReason.REPORT_REASON_IMPERSONATION,
  ReportReason.REPORT_REASON_OTHER,
];

/// Short user-facing label of [reason].
String reportReasonLabel(ReportReason reason) {
  if (reason == ReportReason.REPORT_REASON_SPAM) return "It's spam";
  if (reason == ReportReason.REPORT_REASON_HARASSMENT) {
    return "It's abusive or harassing";
  }
  if (reason == ReportReason.REPORT_REASON_HATE) return 'It is hateful';
  if (reason == ReportReason.REPORT_REASON_VIOLENCE) {
    return 'It threatens or promotes violence';
  }
  if (reason == ReportReason.REPORT_REASON_SEXUAL) {
    return 'It is sexual or explicit';
  }
  if (reason == ReportReason.REPORT_REASON_SELF_HARM) {
    return 'It involves self-harm';
  }
  if (reason == ReportReason.REPORT_REASON_ILLEGAL) return 'It is illegal';
  if (reason == ReportReason.REPORT_REASON_IMPERSONATION) {
    return "It's pretending to be someone";
  }
  return 'Something else';
}

/// Code points in [note] (what the server counts).
int reportNoteLength(String note) => note.runes.length;

/// Shown under "Something else" when reporting a post (W6-43): there is no
/// separate reason for a poll that asks for sensitive personal information
/// (health, religion, politics, sex life, ethnicity, union, genetic or
/// biometric data); "Something else" with this note is how it is reported.
const kReportOtherPostNote =
    'Use this for a poll that asks people for sensitive personal '
    'information, such as health, religion or beliefs, or political opinions.';
