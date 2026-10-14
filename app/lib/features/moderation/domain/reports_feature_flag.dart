/// Name of the reports flag as exposed through
/// `GetMeResponse.enabled_features` (ADR-0016, `FEATURE_REPORTS`). A missing
/// name means off. It gates ModerationService.ReportContent and every
/// "Report" entry (post menu, profile menu); never hardcode `'reports'`
/// anywhere else.
const kFeatureReports = 'reports';
