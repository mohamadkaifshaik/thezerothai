/// Name of the notifications flag as exposed through
/// `GetMeResponse.enabled_features` (ADR-0017 D7, `FEATURE_NOTIFICATIONS`).
/// A missing name means off. It gates every NotificationService RPC, the
/// Notifications tab, the unread badge and the push permission flow; never
/// hardcode `'notifications'` anywhere else.
const kFeatureNotifications = 'notifications';
