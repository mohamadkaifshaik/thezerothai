/// The only vocabulary [UsageAnalytics.log] accepts (ADR-0032 F4).
///
/// TEL-6 adds the three events (`PostCreated`, `FollowMade`, `SearchUsed`)
/// whose parameters are enums and bools, so free text cannot compile. TEL-4
/// only owns the type so the seam exists; nothing logs yet.
sealed class AnalyticsEvent {
  const AnalyticsEvent();
}
